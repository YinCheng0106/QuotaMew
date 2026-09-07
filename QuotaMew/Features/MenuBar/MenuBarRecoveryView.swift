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
protocol ApplicationActivationControlling: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

@MainActor
private final class SystemApplicationActivationController: ApplicationActivationControlling {
    var activationPolicy: NSApplication.ActivationPolicy {
        NSApplication.shared.activationPolicy()
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApplication.shared.setActivationPolicy(policy)
    }

    func activate() {
        NSApplication.shared.activate()
    }
}

@MainActor
final class QuotaMewApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    typealias ControllerFactory = @MainActor (
        AppModel,
        SettingsModel,
        SettingsSceneRoute
    ) -> any StatusItemControllerLifecycle
    typealias OnboardingPresenterFactory = @MainActor () -> any OnboardingPresentationHandling

    private enum WindowPresentation: Hashable {
        case recovery
        case onboarding
    }

    private let controllerFactory: ControllerFactory
    private let onboardingPresenterFactory: OnboardingPresenterFactory
    private let activationController: any ApplicationActivationControlling
    private let terminateApplication: @MainActor () -> Void
    let settingsSceneRoute = SettingsSceneRoute()
    private var appModel: AppModel?
    private var settingsModel: SettingsModel?
    private(set) var statusItemController: (any StatusItemControllerLifecycle)?
    private var recoveryWindowController: NSWindowController?
    private var onboardingPresenter: (any OnboardingPresentationHandling)?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var activeWindowPresentations: Set<WindowPresentation> = []

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
            onboardingPresenterFactory: { OnboardingWindowController() },
            activationController: SystemApplicationActivationController(),
            terminateApplication: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    init(
        controllerFactory: @escaping ControllerFactory,
        onboardingPresenterFactory: @escaping OnboardingPresenterFactory = {
            OnboardingWindowController()
        },
        activationController: any ApplicationActivationControlling = SystemApplicationActivationController(),
        terminateApplication: @escaping @MainActor () -> Void
    ) {
        self.controllerFactory = controllerFactory
        self.onboardingPresenterFactory = onboardingPresenterFactory
        self.activationController = activationController
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
        onboardingPresenter?.teardown()
        onboardingPresenter = nil
        recoveryWindowController?.window?.delegate = nil
        recoveryWindowController?.close()
        recoveryWindowController = nil
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
            if OnboardingStartupPolicy.shouldPresent(
                launchSource: launchSource,
                menuBarDisposition: disposition,
                onboardingState: settingsModel.store.onboardingState
            ) {
                showOnboarding(mode: .firstRun, settingsModel: settingsModel)
            }
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
        if onboardingPresenter?.isPresented == true {
            onboardingPresenter?.focus()
            activationController.activate()
            return false
        }
        guard let settingsModel else { return false }
        guard MenuBarRecoveryPolicy.shouldPresentRecoveryOnReopen(
            isMenuBarItemVisible: settingsModel.isMenuBarItemVisible
        ) else {
            return false
        }
        showRecoveryWindow(settingsModel: settingsModel)
        return false
    }

    func showOnboardingAgain() {
        guard let settingsModel else { return }
        guard OnboardingStartupPolicy.shouldPresentManualReplay(
            isRecoveryPresented: recoveryWindowController?.window?.isVisible == true
        ) else {
            recoveryWindowController?.window?.makeKeyAndOrderFront(nil)
            activationController.activate()
            return
        }
        showOnboarding(mode: .manualReplay, settingsModel: settingsModel)
    }

    func windowWillClose(_ notification: Notification) {
        endWindowPresentation(.recovery)
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
            activationController.activate()
            return
        }
        beginWindowPresentation(.recovery)
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
        activationController.activate()
    }

    private func showOnboarding(
        mode: OnboardingPresentationMode,
        settingsModel: SettingsModel
    ) {
        let presenter: any OnboardingPresentationHandling
        if let onboardingPresenter {
            presenter = onboardingPresenter
        } else {
            let newPresenter = onboardingPresenterFactory()
            onboardingPresenter = newPresenter
            presenter = newPresenter
        }

        guard !presenter.isPresented else {
            presenter.focus()
            activationController.activate()
            return
        }

        beginWindowPresentation(.onboarding)
        presenter.show(
            mode: mode,
            model: settingsModel,
            action: { [weak self] mode, action in
                self?.handleOnboardingAction(mode: mode, action: action)
            },
            didClose: { [weak self] in
                self?.endWindowPresentation(.onboarding)
            }
        )
        activationController.activate()
    }

    private func handleOnboardingAction(
        mode: OnboardingPresentationMode,
        action: OnboardingPresentationAction
    ) {
        guard mode == .firstRun else { return }
        switch action {
        case .complete:
            settingsModel?.completeOnboarding()
        case .skip, .close:
            settingsModel?.skipOnboarding()
        }
    }

    private func beginWindowPresentation(_ presentation: WindowPresentation) {
        guard activeWindowPresentations.insert(presentation).inserted else { return }
        if previousActivationPolicy == nil {
            previousActivationPolicy = activationController.activationPolicy
        }
        if activationController.activationPolicy != .regular {
            activationController.setActivationPolicy(.regular)
        }
    }

    private func endWindowPresentation(_ presentation: WindowPresentation) {
        activeWindowPresentations.remove(presentation)
        guard activeWindowPresentations.isEmpty, let previousActivationPolicy else { return }
        if activationController.activationPolicy != previousActivationPolicy {
            activationController.setActivationPolicy(previousActivationPolicy)
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
