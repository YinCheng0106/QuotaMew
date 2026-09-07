import AppKit
import SwiftUI

struct MenuBarRecoveryView: View {
    let model: SettingsModel
    let showInMenuBar: @MainActor () -> Void
    let insertionRestored: @MainActor () -> Void
    let quit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text("QuotaMew is hidden")
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "menubar.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }

            Text("QuotaMew is currently hidden from the menu bar.")

            Text(
                "If it does not appear after you show it, allow QuotaMew in System Settings > Menu Bar."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Quit QuotaMew") {
                    quit()
                }

                Spacer()

                SettingsLink {
                    Text("Open Settings")
                }

                Button("Show Menu Bar Item") {
                    showInMenuBar()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .onChange(of: model.isMenuBarItemVisible) { _, isVisible in
            if isVisible {
                insertionRestored()
            }
        }
    }
}

@MainActor
final class QuotaMewApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    typealias ControllerFactory = @MainActor (
        AppModel,
        SettingsModel,
        SettingsSceneRoute
    ) -> any StatusItemControllerLifecycle

    private let controllerFactory: ControllerFactory
    private let terminateApplication: @MainActor () -> Void
    let settingsSceneRoute = SettingsSceneRoute()
    private var appModel: AppModel?
    private var settingsModel: SettingsModel?
    private(set) var statusItemController: (any StatusItemControllerLifecycle)?
    private var recoveryWindowController: NSWindowController?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    override convenience init() {
        self.init(
            controllerFactory: { appModel, settingsModel, settingsSceneRoute in
                StatusItemController(
                    appModel: appModel,
                    settingsModel: settingsModel,
                    openSettings: {
                        NSApplication.shared.activate()
                        settingsSceneRoute.open?()
                    }
                )
            },
            terminateApplication: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    init(
        controllerFactory: @escaping ControllerFactory,
        terminateApplication: @escaping @MainActor () -> Void
    ) {
        self.controllerFactory = controllerFactory
        self.terminateApplication = terminateApplication
        super.init()
    }

    func configure(appModel: AppModel, settingsModel: SettingsModel) {
        self.appModel = appModel
        self.settingsModel = settingsModel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start(
            launchSource: ApplicationLaunchSourceDetector.current(),
            shouldCreateStatusItemController: AppRuntimeEnvironment.shouldCreateStatusItemController
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.teardown()
        statusItemController = nil
    }

    func start(
        launchSource: ApplicationLaunchSource,
        shouldCreateStatusItemController: Bool
    ) {
        guard let appModel, let settingsModel else { return }
        guard shouldCreateStatusItemController else { return }
        let disposition = MenuBarRecoveryPolicy.disposition(
            isMenuBarItemRequested: settingsModel.store.isMenuBarItemRequested,
            launchSource: launchSource
        )

        switch disposition {
        case .normal:
            installStatusItemControllerIfNeeded(
                appModel: appModel,
                settingsModel: settingsModel
            )
        case .recovery:
            installStatusItemControllerIfNeeded(
                appModel: appModel,
                settingsModel: settingsModel
            )
            showRecoveryWindow(settingsModel: settingsModel)
        case .quietExit:
            terminateApplication()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard let settingsModel else { return false }
        guard MenuBarRecoveryPolicy.shouldPresentRecoveryOnReopen(
            isMenuBarItemVisible: settingsModel.isMenuBarItemVisible
        ) else {
            return false
        }
        showRecoveryWindow(settingsModel: settingsModel)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        endRecoveryPresentation()
        recoveryWindowController = nil
        guard settingsModel?.isMenuBarItemVisible == false else { return }
        DispatchQueue.main.async {
            self.terminateApplication()
        }
    }

    private func installStatusItemControllerIfNeeded(
        appModel: AppModel,
        settingsModel: SettingsModel
    ) {
        guard statusItemController == nil else { return }
        statusItemController = controllerFactory(appModel, settingsModel, settingsSceneRoute)
    }

    private func showRecoveryWindow(settingsModel: SettingsModel) {
        guard recoveryWindowController == nil else {
            recoveryWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return
        }
        beginRecoveryPresentation()
        let rootView = MenuBarRecoveryView(
            model: settingsModel,
            showInMenuBar: { [weak self] in
                self?.statusItemController?.showMenuBarItem()
            },
            insertionRestored: { [weak self] in
                self?.recoveryWindowController?.close()
            },
            quit: { [weak self] in
                self?.terminateApplication()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "QuotaMew is hidden")
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        recoveryWindowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate()
    }

    private func beginRecoveryPresentation() {
        guard previousActivationPolicy == nil else { return }
        let application = NSApplication.shared
        previousActivationPolicy = application.activationPolicy()
        if application.activationPolicy() != .regular {
            application.setActivationPolicy(.regular)
        }
    }

    private func endRecoveryPresentation() {
        guard let previousActivationPolicy else { return }
        let application = NSApplication.shared
        if application.activationPolicy() != previousActivationPolicy {
            application.setActivationPolicy(previousActivationPolicy)
        }
        self.previousActivationPolicy = nil
    }
}

#Preview("Menu Bar Recovery") {
    let appModel = AppDependencies.makePreviewModel()
    let store = SettingsStore(defaults: UserDefaults(suiteName: "RecoveryPreview")!)
    MenuBarRecoveryView(
        model: SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: PreviewMenuBarRecoveryNotificationService(),
            launchAtLoginController: PreviewMenuBarRecoveryLaunchAtLoginController()
        ),
        showInMenuBar: {},
        insertionRestored: {},
        quit: {}
    )
}

@MainActor
private final class PreviewMenuBarRecoveryNotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

@MainActor
private final class PreviewMenuBarRecoveryLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) throws {
        status = enabled ? .enabled : .disabled
    }
}
