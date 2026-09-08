import AppKit
import Observation
import SwiftUI

struct StatusItemButtonPresentation: Equatable {
    let title: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

enum StatusItemButtonStyle {
    static let symbolName = "gauge.with.dots.needle.50percent"
    static let imagePosition: NSControl.ImagePosition = .imageLeading
    static let imageHugsTitle = true
    static let imageScaling: NSImageScaling = .scaleProportionallyDown

    static func attributedTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize(for: .small),
                    weight: .regular
                )
            ]
        )
    }

    static func statusItemLength(
        intrinsicContentWidth: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        guard intrinsicContentWidth.isFinite,
              intrinsicContentWidth > 0,
              statusBarThickness.isFinite,
              statusBarThickness > 0 else {
            return NSStatusItem.variableLength
        }
        return max(intrinsicContentWidth, statusBarThickness)
    }
}

@MainActor
protocol StatusItemVisibilityObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: StatusItemVisibilityObservation {}

@MainActor
protocol StatusItemHandling: AnyObject {
    var isVisible: Bool { get set }
    var anchorView: NSView? { get }
    var onActivate: (@MainActor () -> Void)? { get set }
    var onSecondaryActivate: (@MainActor () -> Void)? { get set }

    func showContextMenu(_ menu: NSMenu)
    func setAutosaveName(_ name: String)
    func setButtonPresentation(_ presentation: StatusItemButtonPresentation)
    func observeVisibility(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) -> any StatusItemVisibilityObservation
    func teardown()
}

@MainActor
protocol StatusItemPopoverPresenting: AnyObject {
    var isShown: Bool { get }

    func show(relativeTo positioningView: NSView)
    func close()
    func teardown()
}

@MainActor
protocol StatusItemControllerLifecycle: AnyObject {
    func showMenuBarItem()
    func teardown()
}

@MainActor
final class StatusItemController: StatusItemControllerLifecycle {
    private struct ObservationSnapshot {
        let isMenuBarItemRequested: Bool
        let presentation: MenuBarPresentation
    }

    private let appModel: AppModel
    private let settingsModel: SettingsModel
    private let statusItem: any StatusItemHandling
    private let popoverPresenter: any StatusItemPopoverPresenting
    private let contextMenu: StatusItemContextMenu
    private var visibilityObservation: (any StatusItemVisibilityObservation)?
    private var observationReregistrationTask: Task<Void, Never>?
    private var lastAppliedRequestedIntent: Bool?
    private var isTornDown = false

    init(
        appModel: AppModel,
        settingsModel: SettingsModel,
        statusItemFactory: @MainActor () -> any StatusItemHandling = {
            SystemStatusItemHandle()
        },
        popoverFactory: @MainActor (
            AppModel,
            SettingsModel
        ) -> any StatusItemPopoverPresenting = { appModel, settingsModel in
            DashboardPopoverPresenter(
                appModel: appModel,
                settingsModel: settingsModel
            )
        },
        openSettings: @escaping @MainActor () -> Void = {},
        terminateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.appModel = appModel
        self.settingsModel = settingsModel

        let statusItem = statusItemFactory()
        self.statusItem = statusItem
        popoverPresenter = popoverFactory(appModel, settingsModel)
        contextMenu = StatusItemContextMenu(
            refresh: { appModel.refreshManually() },
            openSettings: openSettings,
            quit: terminateApplication
        )

        let autosaveName = Self.autosaveName(bundleIdentifier: Bundle.main.bundleIdentifier)
        statusItem.setAutosaveName(autosaveName)
        statusItem.onActivate = { [weak self] in
            self?.toggleDashboard()
        }
        statusItem.onSecondaryActivate = { [weak self] in
            self?.showContextMenu()
        }
        visibilityObservation = statusItem.observeVisibility { [weak self] isVisible in
            self?.settingsModel.menuBarItemVisibilityDidChange(isVisible)
        }
        registerObservation()
    }

    static func autosaveName(bundleIdentifier: String?) -> String {
        "\(bundleIdentifier ?? "dev.quotapulse.app").primary-status-item"
    }

    static func buttonPresentation(
        for presentation: MenuBarPresentation,
        locale: Locale
    ) -> StatusItemButtonPresentation {
        let title = presentation.compactText(locale: locale) ?? "—"
        let providerName = presentation.selectedProvider?.displayName ?? "QuotaMew"

        if presentation.availability == .renderable,
           let accessibilityValue = presentation.accessibilityValue(locale: locale) {
            return StatusItemButtonPresentation(
                title: title,
                accessibilityLabel: providerName,
                accessibilityValue: accessibilityValue
            )
        }

        let accessibilityLabel: String
        let accessibilityValue: String
        switch presentation.availability {
        case .renderable:
            accessibilityLabel = providerName
            accessibilityValue = presentation.accessibilityValue(locale: locale)
                ?? AppLocalization.string("Menu bar usage unavailable", locale: locale)
        case .disabled:
            accessibilityLabel = AppLocalization.menuBarDisabledLabel(
                providerName: providerName,
                locale: locale
            )
            accessibilityValue = presentation.accessibilityValue(locale: locale)
                ?? AppLocalization.string("Unavailable", locale: locale)
        case .unavailable:
            accessibilityLabel = AppLocalization.menuBarUnavailableLabel(
                providerName: providerName,
                locale: locale
            )
            accessibilityValue = presentation.accessibilityValue(locale: locale)
                ?? AppLocalization.string("Unavailable", locale: locale)
        case .empty:
            accessibilityLabel = AppLocalization.string(
                "QuotaMew, No providers enabled",
                locale: locale
            )
            accessibilityValue = AppLocalization.string(
                "No providers enabled",
                locale: locale
            )
        }

        return StatusItemButtonPresentation(
            title: title,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue
        )
    }

    func showMenuBarItem() {
        guard !isTornDown else { return }
        settingsModel.setMenuBarItemRequested(true)
        applyRequestedVisibility(true, force: true)
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        observationReregistrationTask?.cancel()
        observationReregistrationTask = nil
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        statusItem.onActivate = nil
        statusItem.onSecondaryActivate = nil
        contextMenu.teardown()
        popoverPresenter.teardown()
        statusItem.teardown()
    }

    func usesSharedRuntimeModels(
        appModel: AppModel,
        settingsModel: SettingsModel
    ) -> Bool {
        self.appModel === appModel && self.settingsModel === settingsModel
    }

    private func registerObservation() {
        guard !isTornDown else { return }
        let snapshot = withObservationTracking {
            ObservationSnapshot(
                isMenuBarItemRequested: settingsModel.store.isMenuBarItemRequested,
                presentation: settingsModel.menuBarPresentation
            )
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleObservationReregistration()
            }
        }

        statusItem.setButtonPresentation(
            Self.buttonPresentation(
                for: snapshot.presentation,
                locale: .autoupdatingCurrent
            )
        )
        applyRequestedVisibility(snapshot.isMenuBarItemRequested, force: false)
    }

    private func scheduleObservationReregistration() {
        guard !isTornDown, observationReregistrationTask == nil else { return }
        observationReregistrationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.observationReregistrationTask = nil
            self.registerObservation()
        }
    }

    private func applyRequestedVisibility(_ requested: Bool, force: Bool) {
        guard force || lastAppliedRequestedIntent != requested else { return }
        lastAppliedRequestedIntent = requested
        statusItem.isVisible = requested
        settingsModel.menuBarItemVisibilityDidChange(statusItem.isVisible)
    }

    private func toggleDashboard() {
        guard !isTornDown else { return }
        if popoverPresenter.isShown {
            popoverPresenter.close()
            return
        }
        guard let anchorView = statusItem.anchorView else { return }
        appModel.menuDidOpen()
        popoverPresenter.show(relativeTo: anchorView)
    }

    private func showContextMenu() {
        guard !isTornDown else { return }
        if popoverPresenter.isShown { popoverPresenter.close() }
        statusItem.showContextMenu(contextMenu.menu)
    }
}

@MainActor
private final class SystemStatusItemHandle: StatusItemHandling {
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let actionTarget = StatusItemActionTarget()
    private var isTornDown = false

    init(statusBar: NSStatusBar = .system) {
        self.statusBar = statusBar
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = [.removalAllowed]

        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: StatusItemButtonStyle.symbolName,
            accessibilityDescription: nil
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = StatusItemButtonStyle.imagePosition
        button.imageScaling = StatusItemButtonStyle.imageScaling
        button.imageHugsTitle = StatusItemButtonStyle.imageHugsTitle
        button.target = actionTarget
        button.action = #selector(StatusItemActionTarget.activate)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        actionTarget.action = { [weak self] in
            if NSApplication.shared.currentEvent?.type == .rightMouseUp {
                self?.onSecondaryActivate?()
            } else {
                self?.onActivate?()
            }
        }
    }

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    var anchorView: NSView? { statusItem.button }

    var onActivate: (@MainActor () -> Void)?
    var onSecondaryActivate: (@MainActor () -> Void)?

    func showContextMenu(_ menu: NSMenu) {
        guard !isTornDown, let button = statusItem.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }

    func setAutosaveName(_ name: String) {
        statusItem.autosaveName = name
    }

    func setButtonPresentation(_ presentation: StatusItemButtonPresentation) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = StatusItemButtonStyle.attributedTitle(presentation.title)
        button.layoutSubtreeIfNeeded()
        statusItem.length = StatusItemButtonStyle.statusItemLength(
            intrinsicContentWidth: button.intrinsicContentSize.width,
            statusBarThickness: statusBar.thickness
        )
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.setAccessibilityValue(presentation.accessibilityValue)
    }

    func observeVisibility(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) -> any StatusItemVisibilityObservation {
        statusItem.observe(\.isVisible, options: [.initial, .new]) { statusItem, change in
            let isVisible = change.newValue ?? statusItem.isVisible
            MainActor.assumeIsolated {
                handler(isVisible)
            }
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        actionTarget.action = nil
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusBar.removeStatusItem(statusItem)
    }
}

@MainActor
private final class StatusItemActionTarget: NSObject {
    var action: (@MainActor () -> Void)?

    @objc func activate() {
        action?()
    }
}

@MainActor
private final class DashboardPopoverPresenter: StatusItemPopoverPresenting {
    private let popover: NSPopover
    private let hostingController: NSHostingController<StatusItemDashboardContent>
    private var isTornDown = false

    init(appModel: AppModel, settingsModel: SettingsModel) {
        hostingController = NSHostingController(
            rootView: StatusItemDashboardContent(
                appModel: appModel,
                settingsModel: settingsModel
            )
        )
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 348, height: 500)
        popover.contentViewController = hostingController
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo positioningView: NSView) {
        guard !isTornDown else { return }
        popover.show(
            relativeTo: positioningView.bounds,
            of: positioningView,
            preferredEdge: .minY
        )
        hostingController.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        popover.close()
        popover.contentViewController = nil
    }
}

private struct StatusItemDashboardContent: View {
    let appModel: AppModel
    let settingsModel: SettingsModel

    var body: some View {
        DashboardView(
            model: appModel,
            usagePresentationMode: settingsModel.usagePresentationMode
        )
    }
}
