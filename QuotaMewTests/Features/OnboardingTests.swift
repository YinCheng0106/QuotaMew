import AppKit
import XCTest
@testable import QuotaMew

@MainActor
final class OnboardingTests: XCTestCase {
    func testStartupPolicyShowsOnlyEligibleExplicitNormalLaunch() {
        XCTAssertTrue(
            OnboardingStartupPolicy.shouldPresent(
                launchSource: .explicit,
                menuBarDisposition: .normal,
                onboardingState: .neverShown
            )
        )

        for launchSource in [ApplicationLaunchSource.explicit, .loginItem] {
            for disposition in [MenuBarLaunchDisposition.normal, .recovery, .quietExit] {
                for state in [OnboardingState.neverShown, .completed, .skipped] {
                    let isEligible = launchSource == .explicit
                        && disposition == .normal
                        && state == .neverShown
                    XCTAssertEqual(
                        OnboardingStartupPolicy.shouldPresent(
                            launchSource: launchSource,
                            menuBarDisposition: disposition,
                            onboardingState: state
                        ),
                        isEligible
                    )
                }
            }
        }

        XCTAssertTrue(
            OnboardingStartupPolicy.shouldPresentManualReplay(isRecoveryPresented: false)
        )
        XCTAssertFalse(
            OnboardingStartupPolicy.shouldPresentManualReplay(isRecoveryPresented: true)
        )
    }

    func testEligibleStartupCreatesOnePresenterAndRepeatedStartFocusesIt() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let presenter = TestOnboardingPresenter()
        let activation = TestApplicationActivationController(policy: .accessory)
        let creationCounts = TestOnboardingCreationCounts()
        let delegate = makeDelegate(
            fixture: fixture,
            presenter: presenter,
            activation: activation,
            creationCounts: creationCounts
        )

        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)
        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)

        XCTAssertEqual(creationCounts.controller, 1)
        XCTAssertEqual(creationCounts.presenter, 1)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.focusCount, 1)
        XCTAssertEqual(presenter.mode, .firstRun)
        XCTAssertEqual(activation.policyChanges, [.regular])
    }

    func testCompletedAndSkippedStartupDoNotCreateOnboardingPresenter() {
        for state in [OnboardingState.completed, .skipped] {
            let fixture = makeFixture(onboardingState: state)
            defer { fixture.cleanup() }
            var presenterCreationCount = 0
            let delegate = QuotaMewApplicationDelegate(
                controllerFactory: { _, _, _ in TestOnboardingStatusItemLifecycle() },
                onboardingPresenterFactory: {
                    presenterCreationCount += 1
                    return TestOnboardingPresenter()
                },
                activationController: TestApplicationActivationController(policy: .accessory),
                terminateApplication: {}
            )
            delegate.configure(appModel: fixture.appModel, settingsModel: fixture.settingsModel)

            delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)

            XCTAssertEqual(presenterCreationCount, 0)
        }
    }

    func testHiddenLoginItemLaunchQuietlyExitsWithoutStatusItemOrOnboarding() {
        let fixture = makeFixture(menuBarRequested: false)
        defer { fixture.cleanup() }
        var statusItemCreationCount = 0
        var presenterCreationCount = 0
        var terminationCount = 0
        let delegate = QuotaMewApplicationDelegate(
            controllerFactory: { _, _, _ in
                statusItemCreationCount += 1
                return TestOnboardingStatusItemLifecycle()
            },
            onboardingPresenterFactory: {
                presenterCreationCount += 1
                return TestOnboardingPresenter()
            },
            activationController: TestApplicationActivationController(policy: .accessory),
            terminateApplication: { terminationCount += 1 }
        )
        delegate.configure(appModel: fixture.appModel, settingsModel: fixture.settingsModel)

        delegate.start(launchSource: .loginItem, shouldCreateStatusItemController: true)

        XCTAssertEqual(statusItemCreationCount, 0)
        XCTAssertEqual(presenterCreationCount, 0)
        XCTAssertEqual(terminationCount, 1)
    }

    func testFirstRunCompletePersistsCompletionAndRestoresActivationPolicy() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let presenter = TestOnboardingPresenter()
        let activation = TestApplicationActivationController(policy: .accessory)
        let delegate = makeDelegate(fixture: fixture, presenter: presenter, activation: activation)

        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)
        presenter.dismiss(with: .complete)

        XCTAssertEqual(fixture.store.onboardingState, .completed)
        XCTAssertEqual(
            fixture.store.onboardingLastCompletedVersion,
            SettingsStore.currentOnboardingVersion
        )
        XCTAssertEqual(activation.policyChanges, [.regular, .accessory])
    }

    func testFirstRunSkipAndWindowCloseBothPersistSkippedWithoutOtherSideEffects() {
        for action in [OnboardingPresentationAction.skip, .close] {
            let notifications = TestOnboardingNotificationService(status: .notDetermined)
            let fixture = makeFixture(notifications: notifications)
            defer { fixture.cleanup() }
            fixture.settingsModel.setUsagePresentationMode(.used)
            fixture.settingsModel.setPinnedProvider(.claude)
            let presenter = TestOnboardingPresenter()
            let delegate = makeDelegate(
                fixture: fixture,
                presenter: presenter,
                activation: TestApplicationActivationController(policy: .accessory)
            )

            delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)
            presenter.dismiss(with: action)

            XCTAssertEqual(fixture.store.onboardingState, .skipped)
            XCTAssertEqual(fixture.store.usagePresentationMode, .used)
            XCTAssertEqual(fixture.store.pinnedProviderID, .claude)
            XCTAssertTrue(fixture.store.isMenuBarItemRequested)
            XCTAssertEqual(notifications.authorizationRequestCount, 0)
        }
    }

    func testManualReplayPreservesStateVersionAndCurrentSettings() {
        let fixture = makeFixture(onboardingState: .completed)
        defer { fixture.cleanup() }
        fixture.settingsModel.setUsagePresentationMode(.used)
        fixture.settingsModel.setPinnedProvider(.codex)
        let originalVersion = fixture.store.onboardingLastCompletedVersion
        let presenter = TestOnboardingPresenter()
        let delegate = makeDelegate(
            fixture: fixture,
            presenter: presenter,
            activation: TestApplicationActivationController(policy: .accessory)
        )

        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)
        XCTAssertEqual(presenter.showCount, 0)
        delegate.showOnboardingAgain()
        delegate.showOnboardingAgain()

        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.focusCount, 1)
        XCTAssertEqual(presenter.mode, .manualReplay)
        XCTAssertTrue(presenter.model === fixture.settingsModel)
        presenter.dismiss(with: .close)
        XCTAssertEqual(fixture.store.onboardingState, .completed)
        XCTAssertEqual(fixture.store.onboardingLastCompletedVersion, originalVersion)
        XCTAssertEqual(fixture.store.usagePresentationMode, .used)
        XCTAssertEqual(fixture.store.pinnedProviderID, .codex)
    }

    func testManualReplayClosePreservesSkippedState() {
        let fixture = makeFixture(onboardingState: .skipped)
        defer { fixture.cleanup() }
        let presenter = TestOnboardingPresenter()
        let delegate = makeDelegate(
            fixture: fixture,
            presenter: presenter,
            activation: TestApplicationActivationController(policy: .accessory)
        )

        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)
        delegate.showOnboardingAgain()
        presenter.dismiss(with: .close)

        XCTAssertEqual(fixture.store.onboardingState, .skipped)
        XCTAssertEqual(
            fixture.store.onboardingLastCompletedVersion,
            SettingsStore.currentOnboardingVersion
        )
    }

    func testApplicationTerminationTearsDownBoundedPresenterAndStatusItemOwner() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let presenter = TestOnboardingPresenter()
        let lifecycle = TestOnboardingStatusItemLifecycle()
        let delegate = QuotaMewApplicationDelegate(
            controllerFactory: { _, _, _ in lifecycle },
            onboardingPresenterFactory: { presenter },
            activationController: TestApplicationActivationController(policy: .accessory),
            terminateApplication: {}
        )
        delegate.configure(appModel: fixture.appModel, settingsModel: fixture.settingsModel)
        delegate.start(launchSource: .explicit, shouldCreateStatusItemController: true)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(presenter.teardownCount, 1)
        XCTAssertEqual(lifecycle.teardownCount, 1)
    }

    func testProviderStatusPresentationUsesConservativeDiagnostics() {
        XCTAssertEqual(
            OnboardingProviderStatus.codex(diagnostic(.codex, availability: .available)),
            .available
        )
        XCTAssertEqual(
            OnboardingProviderStatus.codex(
                diagnostic(.codex, availability: .loading, runtimeDetected: true)
            ),
            .detected
        )
        XCTAssertEqual(
            OnboardingProviderStatus.codex(
                diagnostic(.codex, availability: .notInstalled, runtimeDetected: false)
            ),
            .notDetected
        )
        XCTAssertEqual(
            OnboardingProviderStatus.codex(diagnostic(.codex, availability: .failed)),
            .unavailable
        )
        XCTAssertEqual(
            OnboardingProviderStatus.claude(diagnostic(.claude, availability: .stale)),
            .configured
        )
        XCTAssertEqual(
            OnboardingProviderStatus.claude(diagnostic(.claude, availability: .notConfigured)),
            .notConfigured
        )
        XCTAssertEqual(
            OnboardingProviderStatus.claude(diagnostic(.claude, availability: .failed)),
            .unavailable
        )
        XCTAssertEqual(
            OnboardingProviderStatus.claude(
                diagnostic(.claude, isEnabled: false, availability: .disabled)
            ),
            .disabled
        )
    }

    func testCompatibilityDiagnosticsReadsRuntimeSnapshotWithoutFetchingUsage() async {
        let provider = OnboardingCountingProvider()
        let appModel = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [provider])
            ),
            notificationService: TestOnboardingNotificationService(),
            observesLifecycle: false
        )
        let suiteName = "OnboardingDiagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsModel(
            store: SettingsStore(defaults: defaults),
            appModel: appModel,
            notificationService: TestOnboardingNotificationService(),
            launchAtLoginController: TestOnboardingLaunchAtLoginController()
        )

        await model.refreshDiagnostics()

        let counts = await provider.counts
        XCTAssertEqual(counts.fetch, 0)
        XCTAssertEqual(counts.diagnostic, 1)
        XCTAssertEqual(model.diagnostics?.providers.map(\.providerID), [.codex])
    }

    private func makeFixture(
        menuBarRequested: Bool = true,
        onboardingState: OnboardingState? = nil,
        notifications: TestOnboardingNotificationService = TestOnboardingNotificationService()
    ) -> OnboardingFixture {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        store.setMenuBarItemRequested(menuBarRequested)
        if let onboardingState {
            store.setOnboardingState(onboardingState)
        }
        let appModel = AppModel(
            providerIDs: [],
            refreshCoordinator: RefreshCoordinator(usageService: UsageService(providers: [])),
            notificationService: notifications,
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: TestOnboardingLaunchAtLoginController()
        )
        return OnboardingFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            appModel: appModel,
            settingsModel: settingsModel
        )
    }

    private func makeDelegate(
        fixture: OnboardingFixture,
        presenter: TestOnboardingPresenter,
        activation: TestApplicationActivationController,
        creationCounts: TestOnboardingCreationCounts? = nil
    ) -> QuotaMewApplicationDelegate {
        let delegate = QuotaMewApplicationDelegate(
            controllerFactory: { _, _, _ in
                creationCounts?.controller += 1
                return TestOnboardingStatusItemLifecycle()
            },
            onboardingPresenterFactory: {
                creationCounts?.presenter += 1
                return presenter
            },
            activationController: activation,
            terminateApplication: {}
        )
        delegate.configure(appModel: fixture.appModel, settingsModel: fixture.settingsModel)
        return delegate
    }

    private func diagnostic(
        _ providerID: ProviderID,
        isEnabled: Bool = true,
        availability: DiagnosticAvailability,
        runtimeDetected: Bool? = nil
    ) -> ProviderDiagnosticSnapshot {
        ProviderDiagnosticSnapshot(
            providerID: providerID,
            isEnabled: isEnabled,
            availability: availability,
            hostApplication: nil,
            runtimeSource: .unknown,
            runtimeDetected: runtimeDetected,
            compatibilityStatus: .unknown,
            appServerState: .unknown,
            refreshOutcome: .notAttempted,
            lastRefreshAttemptAt: nil,
            lastSuccessfulRefreshAt: nil,
            lastFailureCategory: nil,
            usageMetadataAvailable: false,
            resetMetadataAvailable: false
        )
    }
}

@MainActor
private final class TestOnboardingCreationCounts {
    var controller = 0
    var presenter = 0
}

@MainActor
private struct OnboardingFixture {
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
private final class TestOnboardingPresenter: OnboardingPresentationHandling {
    private(set) var isPresented = false
    private(set) var showCount = 0
    private(set) var focusCount = 0
    private(set) var teardownCount = 0
    private(set) var mode: OnboardingPresentationMode?
    private(set) weak var model: SettingsModel?
    private var action: (@MainActor (OnboardingPresentationMode, OnboardingPresentationAction) -> Void)?
    private var didClose: (@MainActor () -> Void)?

    func show(
        mode: OnboardingPresentationMode,
        model: SettingsModel,
        action: @escaping @MainActor (OnboardingPresentationMode, OnboardingPresentationAction) -> Void,
        didClose: @escaping @MainActor () -> Void
    ) {
        showCount += 1
        isPresented = true
        self.mode = mode
        self.model = model
        self.action = action
        self.didClose = didClose
    }

    func focus() {
        focusCount += 1
    }

    func teardown() {
        teardownCount += 1
        isPresented = false
    }

    func dismiss(with presentationAction: OnboardingPresentationAction) {
        guard let mode else { return }
        action?(mode, presentationAction)
        isPresented = false
        self.mode = nil
        action = nil
        let didClose = didClose
        self.didClose = nil
        didClose?()
    }
}

@MainActor
private final class TestApplicationActivationController: ApplicationActivationControlling {
    private(set) var activationPolicy: NSApplication.ActivationPolicy
    private(set) var policyChanges: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    init(policy: NSApplication.ActivationPolicy) {
        activationPolicy = policy
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        activationPolicy = policy
        policyChanges.append(policy)
    }

    func activate() {
        activationCount += 1
    }
}

@MainActor
private final class TestOnboardingStatusItemLifecycle: StatusItemControllerLifecycle {
    private(set) var teardownCount = 0
    func showMenuBarItem() {}
    func teardown() { teardownCount += 1 }
}

@MainActor
private final class TestOnboardingNotificationService: NotificationServicing {
    private(set) var authorizationRequestCount = 0
    private(set) var preferencesChangeCount = 0
    private var status: NotificationAuthorizationStatus

    init(status: NotificationAuthorizationStatus = .authorized) {
        self.status = status
    }

    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    func authorizationStatus() async -> NotificationAuthorizationStatus { status }
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        authorizationRequestCount += 1
        status = .authorized
        return status
    }
    func preferencesDidChange() async { preferencesChangeCount += 1 }
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

@MainActor
private final class TestOnboardingLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) throws { status = enabled ? .enabled : .disabled }
}

private actor OnboardingCountingProvider: UsageProvider {
    nonisolated let id = ProviderID.codex
    private var fetchCount = 0
    private var diagnosticCount = 0

    var counts: (fetch: Int, diagnostic: Int) {
        (fetchCount, diagnosticCount)
    }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        fetchCount += 1
        return ProviderUsageSnapshot(
            providerID: .codex,
            windows: [],
            capturedAt: .now,
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }

    func runtimeDiagnostic() async -> ProviderRuntimeDiagnostic {
        diagnosticCount += 1
        return .unknown
    }
}
