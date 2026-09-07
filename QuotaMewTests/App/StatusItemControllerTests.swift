import AppKit
import XCTest
@testable import QuotaMew

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testRightClickReusesNativeMenuAndKeepsLeftClickAndPresentationWorking() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let item = TestStatusItemHandle()
        let popover = TestStatusItemPopover()
        var creations = 0
        var settingsCount = 0
        var quitCount = 0
        let controller = StatusItemController(
            appModel: fixture.appModel, settingsModel: fixture.settingsModel,
            statusItemFactory: { creations += 1; return item },
            popoverFactory: { _, _ in popover },
            openSettings: { settingsCount += 1 },
            terminateApplication: { quitCount += 1 }
        )
        defer { controller.teardown() }
        item.activate()
        XCTAssertTrue(popover.isShown)
        item.onSecondaryActivate?()
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(item.shownMenus.count, 1)
        let menu = try XCTUnwrap(item.shownMenus.first)
        for _ in 0..<100 { item.onSecondaryActivate?() }
        XCTAssertEqual(item.shownMenus.count, 101)
        XCTAssertTrue(item.shownMenus.allSatisfy { $0 === menu })
        XCTAssertEqual(menu.items.count, 4)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(item.visibilityObservationCount, 1)
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 3)
        XCTAssertEqual(settingsCount, 1)
        XCTAssertEqual(quitCount, 1)
        XCTAssertTrue(fixture.store.isMenuBarItemRequested)
        XCTAssertEqual(fixture.store.onboardingState, .neverShown)
        XCTAssertTrue(fixture.store.isCodexEnabled)

        item.activate()
        XCTAssertTrue(popover.isShown)
        item.activate()
        XCTAssertFalse(popover.isShown)
        let updated = expectation(description: "Presentation still updates after context menu")
        item.onPresentation = { _ in updated.fulfill() }
        fixture.settingsModel.setUsagePresentationMode(.used)
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(creations, 1)

        controller.teardown()
        XCTAssertNil(item.onSecondaryActivate)
        XCTAssertTrue(menu.items.allSatisfy { $0.target == nil && $0.action == nil })
        XCTAssertEqual(item.teardownCount, 1)
        XCTAssertEqual(item.observationInvalidationCount, 1)
    }

    func testNativeMenuTitlesShortcutsAndActionsInBothLanguages() {
        for (locale, titles) in [
            (Locale(identifier: "en"), ["Refresh Now", "Settings…", "", "Quit QuotaMew"]),
            (Locale(identifier: "zh-Hant-TW"), ["立即重新整理", "設定…", "", "退出 QuotaMew"]),
        ] {
            var calls = [0, 0, 0]
            let context = StatusItemContextMenu(
                refresh: { calls[0] += 1 }, openSettings: { calls[1] += 1 },
                quit: { calls[2] += 1 }, locale: locale
            )
            XCTAssertEqual(context.menu.items.map(\.title), titles)
            XCTAssertTrue(context.menu.items[2].isSeparatorItem)
            XCTAssertEqual(context.menu.items.map(\.keyEquivalent), ["", "", "", "q"])
            XCTAssertEqual(context.menu.items[3].keyEquivalentModifierMask, .command)
            for index in [0, 1, 3] { context.menu.performActionForItem(at: index) }
            XCTAssertEqual(calls, [1, 1, 1])
            context.teardown()
        }
    }

    func testContextRefreshUsesExistingAppModelCoalescing() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let readStarted = expectation(description: "Manual refresh enters provider once")
        let provider = ContextMenuTestProvider { readStarted.fulfill() }
        let appModel = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(usageService: UsageService(providers: [provider])),
            notificationService: StatusItemTestNotificationService(), observesLifecycle: false
        )
        let item = TestStatusItemHandle()
        let controller = StatusItemController(
            appModel: appModel, settingsModel: fixture.settingsModel,
            statusItemFactory: { item }, popoverFactory: { _, _ in TestStatusItemPopover() }
        )
        defer { controller.teardown() }
        item.onSecondaryActivate?()
        let menu = try XCTUnwrap(item.shownMenus.first)
        XCTAssertFalse(appModel.isRefreshing, "Opening the menu alone must not refresh")
        menu.performActionForItem(at: 0)
        await fulfillment(of: [readStarted], timeout: 1)
        XCTAssertTrue(appModel.isRefreshing)
        for _ in 0..<20 { menu.performActionForItem(at: 0) }
        let reads = await provider.readCount
        XCTAssertEqual(reads, 1)
        await provider.finish()
    }

    func testControllerCreatesOneStatusItemAndUsesIdentityScopedAutosaveName() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        var creationCount = 0

        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: {
                creationCount += 1
                return statusItem
            },
            popoverFactory: { _, _ in TestStatusItemPopover() }
        )

        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(statusItem.visibilityObservationCount, 1)
        XCTAssertEqual(
            statusItem.autosaveName,
            "dev.quotapulse.development.app.primary-status-item"
        )
        XCTAssertEqual(
            StatusItemController.autosaveName(
                bundleIdentifier: "dev.quotapulse.development.app"
            ),
            "dev.quotapulse.development.app.primary-status-item"
        )
        XCTAssertEqual(
            StatusItemController.autosaveName(bundleIdentifier: "dev.quotapulse.app"),
            "dev.quotapulse.app.primary-status-item"
        )
        XCTAssertTrue(
            controller.usesSharedRuntimeModels(
                appModel: fixture.appModel,
                settingsModel: fixture.settingsModel
            )
        )
    }

    func testPersistedIntentControlsLogicalVisibilityWithoutRecreatingItem() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        var creationCount = 0
        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: {
                creationCount += 1
                return statusItem
            },
            popoverFactory: { _, _ in TestStatusItemPopover() }
        )
        let autosaveName = statusItem.autosaveName

        XCTAssertTrue(statusItem.isVisible)
        XCTAssertTrue(fixture.settingsModel.isMenuBarItemVisible)

        let hidden = expectation(description: "Controller applies hidden intent")
        statusItem.onVisibilitySet = { isVisible in
            if !isVisible { hidden.fulfill() }
        }
        fixture.settingsModel.setMenuBarItemRequested(false)
        await fulfillment(of: [hidden], timeout: 1)

        XCTAssertFalse(statusItem.isVisible)
        XCTAssertFalse(fixture.settingsModel.isMenuBarItemVisible)
        XCTAssertFalse(fixture.store.isMenuBarItemRequested)

        let visible = expectation(description: "Controller restores visible intent")
        statusItem.onVisibilitySet = { isVisible in
            if isVisible { visible.fulfill() }
        }
        fixture.settingsModel.setMenuBarItemRequested(true)
        await fulfillment(of: [visible], timeout: 1)

        XCTAssertTrue(statusItem.isVisible)
        XCTAssertTrue(fixture.settingsModel.isMenuBarItemVisible)
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(statusItem.autosaveName, autosaveName)

        for cycle in 0..<100 {
            let hidden = expectation(description: "Cycle \(cycle) hides item")
            statusItem.onVisibilitySet = { isVisible in
                if !isVisible { hidden.fulfill() }
            }
            fixture.settingsModel.setMenuBarItemRequested(false)
            await fulfillment(of: [hidden], timeout: 1)

            let visible = expectation(description: "Cycle \(cycle) shows item")
            statusItem.onVisibilitySet = { isVisible in
                if isVisible { visible.fulfill() }
            }
            fixture.settingsModel.setMenuBarItemRequested(true)
            await fulfillment(of: [visible], timeout: 1)
        }

        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(statusItem.visibilityObservationCount, 1)
        XCTAssertEqual(statusItem.autosaveName, autosaveName)
        withExtendedLifetime(controller) {}
    }

    func testPresentationChangeDoesNotRecreateStatusItem() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        var creationCount = 0
        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: {
                creationCount += 1
                return statusItem
            },
            popoverFactory: { _, _ in TestStatusItemPopover() }
        )
        let initialPresentationCount = statusItem.presentations.count

        let presentationUpdated = expectation(description: "Display mode is reapplied")
        statusItem.onPresentation = { _ in presentationUpdated.fulfill() }
        fixture.settingsModel.setUsagePresentationMode(.used)
        await fulfillment(of: [presentationUpdated], timeout: 1)

        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(statusItem.presentations.count, initialPresentationCount + 1)
        withExtendedLifetime(controller) {}
    }

    func testSystemVisibilityChangeDoesNotCorruptIntentOrTriggerReinsertion() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: { statusItem },
            popoverFactory: { _, _ in TestStatusItemPopover() }
        )

        statusItem.simulateSystemVisibility(false)

        XCTAssertFalse(fixture.settingsModel.isMenuBarItemVisible)
        XCTAssertTrue(fixture.store.isMenuBarItemRequested)

        let presentationUpdated = expectation(description: "Presentation updates")
        statusItem.onPresentation = { _ in presentationUpdated.fulfill() }
        fixture.settingsModel.setUsagePresentationMode(.used)
        await fulfillment(of: [presentationUpdated], timeout: 1)

        XCTAssertFalse(statusItem.isVisible)
        XCTAssertTrue(fixture.store.isMenuBarItemRequested)
        withExtendedLifetime(controller) {}
    }

    func testRecoveryShowForcesVisibilityAfterExternalRemoval() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: { statusItem },
            popoverFactory: { _, _ in TestStatusItemPopover() }
        )
        statusItem.simulateSystemVisibility(false)

        controller.showMenuBarItem()

        XCTAssertTrue(fixture.store.isMenuBarItemRequested)
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertTrue(fixture.settingsModel.isMenuBarItemVisible)
    }

    func testActivationReusesOnePopoverAndControllerTeardownIsBounded() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let statusItem = TestStatusItemHandle()
        let popover = TestStatusItemPopover()
        let controller = StatusItemController(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel,
            statusItemFactory: { statusItem },
            popoverFactory: { _, _ in popover }
        )

        statusItem.activate()
        statusItem.activate()

        XCTAssertEqual(popover.showCount, 1)
        XCTAssertEqual(popover.closeCount, 1)

        for _ in 0..<100 {
            statusItem.activate()
            statusItem.activate()
        }

        XCTAssertEqual(popover.showCount, 101)
        XCTAssertEqual(popover.closeCount, 101)

        controller.teardown()
        controller.teardown()

        XCTAssertEqual(statusItem.teardownCount, 1)
        XCTAssertEqual(statusItem.observationInvalidationCount, 1)
        XCTAssertEqual(popover.teardownCount, 1)
    }

    func testAccessibilityAndCompactLabelUseExistingPresentationSemantics() {
        let presentations = [
            (used: 100.0, title: "0%"),
            (used: 39.0, title: "61%"),
            (used: 0.0, title: "100%")
        ].map { value in
            StatusItemController.buttonPresentation(
                for: MenuBarPresentation(
                    providerStates: [makeState(status: .available, used: value.used)],
                    persistedPinnedProviderRawValue: ProviderID.codex.rawValue,
                    mode: .remaining
                ),
                locale: Locale(identifier: "en")
            )
        }
        let disabled = MenuBarPresentation(
            providerStates: [makeState(status: .disabled, used: 39)],
            persistedPinnedProviderRawValue: ProviderID.codex.rawValue,
            mode: .remaining
        )

        XCTAssertEqual(presentations.map(\.title), ["0%", "61%", "100%"])
        XCTAssertEqual(
            presentations[1],
            StatusItemButtonPresentation(
                title: "61%",
                accessibilityLabel: "Codex",
                accessibilityValue: "61% remaining"
            )
        )
        XCTAssertEqual(
            StatusItemController.buttonPresentation(
                for: disabled,
                locale: Locale(identifier: "en")
            ),
            StatusItemButtonPresentation(
                title: "—",
                accessibilityLabel: "Codex, Disabled",
                accessibilityValue: "Unavailable"
            )
        )
    }

    func testButtonTitleHasNoManualPaddingAndSupportsAllCompactMetrics() {
        for title in ["—", "0%", "61%", "100%"] {
            let attributedTitle = StatusItemButtonStyle.attributedTitle(title)

            XCTAssertEqual(attributedTitle.string, title)
            XCTAssertEqual(
                attributedTitle.string,
                attributedTitle.string.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            XCTAssertFalse(attributedTitle.string.contains("\u{00a0}"))
        }
    }

    func testNativeButtonImageAndTitleConfigurationIsStable() {
        XCTAssertEqual(
            StatusItemButtonStyle.symbolName,
            "gauge.with.dots.needle.50percent"
        )
        XCTAssertEqual(StatusItemButtonStyle.imagePosition, .imageLeading)
        XCTAssertTrue(StatusItemButtonStyle.imageHugsTitle)
        XCTAssertEqual(StatusItemButtonStyle.imageScaling, .scaleProportionallyDown)
    }

    func testStatusItemLengthUsesIntrinsicWidthAndNativeMinimum() {
        XCTAssertEqual(
            StatusItemButtonStyle.statusItemLength(
                intrinsicContentWidth: 46.5,
                statusBarThickness: 22
            ),
            46.5
        )
        XCTAssertEqual(
            StatusItemButtonStyle.statusItemLength(
                intrinsicContentWidth: 15,
                statusBarThickness: 22
            ),
            22
        )
        XCTAssertEqual(
            StatusItemButtonStyle.statusItemLength(
                intrinsicContentWidth: .nan,
                statusBarThickness: 22
            ),
            NSStatusItem.variableLength
        )
    }

    func testApplicationDelegateCreatesOneControllerOnlyOutsideXCTestBoundary() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        var controllerCreationCount = 0
        let lifecycle = TestStatusItemControllerLifecycle()
        let delegate = QuotaMewApplicationDelegate(
            controllerFactory: { appModel, settingsModel, _ in
                XCTAssertTrue(appModel === fixture.appModel)
                XCTAssertTrue(settingsModel === fixture.settingsModel)
                controllerCreationCount += 1
                return lifecycle
            },
            terminateApplication: {}
        )
        delegate.configure(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel
        )

        delegate.start(
            launchSource: .explicit,
            shouldCreateStatusItemController: false
        )
        XCTAssertEqual(controllerCreationCount, 0)

        delegate.start(
            launchSource: .explicit,
            shouldCreateStatusItemController: true
        )
        delegate.start(
            launchSource: .explicit,
            shouldCreateStatusItemController: true
        )

        XCTAssertEqual(controllerCreationCount, 1)
    }

    func testHiddenLoginItemLaunchExitsBeforeControllerCreation() {
        let fixture = makeFixture(requested: false)
        defer { fixture.cleanup() }
        var controllerCreationCount = 0
        var terminationCount = 0
        let delegate = QuotaMewApplicationDelegate(
            controllerFactory: { _, _, _ in
                controllerCreationCount += 1
                return TestStatusItemControllerLifecycle()
            },
            terminateApplication: { terminationCount += 1 }
        )
        delegate.configure(
            appModel: fixture.appModel,
            settingsModel: fixture.settingsModel
        )

        delegate.start(
            launchSource: .loginItem,
            shouldCreateStatusItemController: true
        )

        XCTAssertEqual(controllerCreationCount, 0)
        XCTAssertEqual(terminationCount, 1)
    }

    private func makeFixture(requested: Bool = true) -> StatusItemFixture {
        let suiteName = "StatusItemControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        store.setMenuBarItemRequested(requested)
        let appModel = AppModel(
            providerIDs: [],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [])
            ),
            notificationService: StatusItemTestNotificationService(),
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: StatusItemTestNotificationService(),
            launchAtLoginController: StatusItemTestLaunchAtLoginController()
        )
        return StatusItemFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            appModel: appModel,
            settingsModel: settingsModel
        )
    }

    private func makeState(status: ProviderStatus, used: Double) -> ProviderState {
        let window = UsageWindow(
            id: "primary",
            label: "Primary window",
            usedPercentage: used,
            resetAt: Date(timeIntervalSince1970: 2_000_003_600),
            duration: .seconds(18_000)
        )
        return ProviderState(
            providerID: .codex,
            status: status,
            snapshot: ProviderUsageSnapshot(
                providerID: .codex,
                windows: [window],
                capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
                source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
            )
        )
    }
}

@MainActor
private struct StatusItemFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: SettingsStore
    let appModel: AppModel
    let settingsModel: SettingsModel

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class TestStatusItemHandle: StatusItemHandling {
    var isVisible = true {
        didSet {
            onVisibilitySet?(isVisible)
            visibilityHandler?(isVisible)
        }
    }
    let anchorView: NSView? = NSView()
    var onActivate: (@MainActor () -> Void)?
    var onSecondaryActivate: (@MainActor () -> Void)?
    private(set) var shownMenus: [NSMenu] = []

    func showContextMenu(_ menu: NSMenu) {
        shownMenus.append(menu)
    }
    var onVisibilitySet: ((Bool) -> Void)?
    var onPresentation: ((StatusItemButtonPresentation) -> Void)?
    private(set) var autosaveName: String?
    private(set) var presentations: [StatusItemButtonPresentation] = []
    private(set) var visibilityObservationCount = 0
    private(set) var observationInvalidationCount = 0
    private(set) var teardownCount = 0
    private var visibilityHandler: ((Bool) -> Void)?

    func setAutosaveName(_ name: String) {
        autosaveName = name
    }

    func setButtonPresentation(_ presentation: StatusItemButtonPresentation) {
        presentations.append(presentation)
        onPresentation?(presentation)
    }

    func observeVisibility(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) -> any StatusItemVisibilityObservation {
        visibilityObservationCount += 1
        visibilityHandler = handler
        handler(isVisible)
        return TestStatusItemVisibilityObservation { [weak self] in
            self?.observationInvalidationCount += 1
            self?.visibilityHandler = nil
        }
    }

    func activate() {
        onActivate?()
    }

    func simulateSystemVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
    }

    func teardown() {
        teardownCount += 1
    }
}

@MainActor
private final class TestStatusItemVisibilityObservation: StatusItemVisibilityObservation {
    private var invalidateAction: (() -> Void)?

    init(invalidateAction: @escaping () -> Void) {
        self.invalidateAction = invalidateAction
    }

    func invalidate() {
        invalidateAction?()
        invalidateAction = nil
    }
}

@MainActor
private final class TestStatusItemPopover: StatusItemPopoverPresenting {
    private(set) var isShown = false
    private(set) var showCount = 0
    private(set) var closeCount = 0
    private(set) var teardownCount = 0

    func show(relativeTo positioningView: NSView) {
        isShown = true
        showCount += 1
    }

    func close() {
        isShown = false
        closeCount += 1
    }

    func teardown() {
        isShown = false
        teardownCount += 1
    }
}

@MainActor
private final class TestStatusItemControllerLifecycle: StatusItemControllerLifecycle {
    func showMenuBarItem() {}
    func teardown() {}
}

@MainActor
private final class StatusItemTestNotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

@MainActor
private final class StatusItemTestLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) throws {
        status = enabled ? .enabled : .disabled
    }
}

private actor ContextMenuTestProvider: UsageProvider {
    nonisolated let id = ProviderID.codex
    private let onRead: @Sendable () -> Void
    private(set) var readCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(onRead: @escaping @Sendable () -> Void) { self.onRead = onRead }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        readCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onRead()
        }
        return ProviderUsageSnapshot(
            providerID: .codex, windows: [], capturedAt: .now,
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
