import AppKit
import Foundation
import Observation
import ServiceManagement
import XCTest
@testable import QuotaMew

@MainActor
final class SettingsIntegrationTests: XCTestCase {
    func testCodexDisabledSkipsOnlyCodexWork() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codex = SettingsCountingProvider(id: .codex)
        let claude = SettingsCountingProvider(id: .claude)
        store.setProvider(.codex, enabled: false)
        let service = UsageService(providers: [codex, claude], preferences: store)

        let states = await service.refresh()

        XCTAssertEqual(states.map(\.status), [.disabled, .available])
        let codexFetchCount = await codex.fetchCount
        let claudeFetchCount = await claude.fetchCount
        XCTAssertEqual(codexFetchCount, 0)
        XCTAssertEqual(claudeFetchCount, 1)
    }

    func testDisabledProviderIsSkippedDuringStartupRefresh() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.setProvider(.codex, enabled: false)
        let codex = SettingsCountingProvider(id: .codex)
        let claude = SettingsCountingProvider(id: .claude)
        let providers: [any UsageProvider] = [codex, claude]
        let model = AppModel(
            providerIDs: providers.map(\.id),
            enabledProviderIDs: [.claude],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: providers, preferences: store)
            ),
            notificationService: SettingsNotificationService(),
            observesLifecycle: false
        )

        model.start()
        await waitUntilRefreshFinishes(model)

        let codexFetchCount = await codex.fetchCount
        let claudeFetchCount = await claude.fetchCount
        XCTAssertEqual(codexFetchCount, 0)
        XCTAssertEqual(claudeFetchCount, 1)
        XCTAssertEqual(model.activeProviderStates.map(\.providerID), [.claude])
    }

    func testManualRefreshFetchesEveryEnabledProviderAndSkipsDisabledProvider() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.setProvider(.claude, enabled: false)
        let codex = SettingsCountingProvider(id: .codex)
        let claude = SettingsCountingProvider(id: .claude)
        let service = UsageService(providers: [codex, claude], preferences: store)

        _ = await service.refresh()
        _ = await service.refresh()

        let codexFetchCount = await codex.fetchCount
        let claudeFetchCount = await claude.fetchCount
        XCTAssertEqual(codexFetchCount, 2)
        XCTAssertEqual(claudeFetchCount, 0)
    }

    func testReenablingCodexRestoresWorkWithoutAffectingClaude() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codex = SettingsCountingProvider(id: .codex)
        let claude = SettingsCountingProvider(id: .claude)
        let service = UsageService(providers: [codex, claude], preferences: store)
        store.setProvider(.codex, enabled: false)
        _ = await service.refresh()

        store.setProvider(.codex, enabled: true)
        let states = await service.refresh()

        XCTAssertEqual(states.map(\.status), [.available, .available])
        let codexFetchCount = await codex.fetchCount
        let claudeFetchCount = await claude.fetchCount
        XCTAssertEqual(codexFetchCount, 1)
        XCTAssertEqual(claudeFetchCount, 2)
    }

    func testSettingsReenableRefreshesProviderWithoutRestart() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.setProvider(.codex, enabled: false)
        let codex = SettingsCountingProvider(id: .codex)
        let providers: [any UsageProvider] = [codex]
        let notifications = SettingsNotificationService()
        let appModel = AppModel(
            providerIDs: [.codex],
            enabledProviderIDs: [],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: providers, preferences: store)
            ),
            notificationService: notifications,
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        let transitionResult: Void = settingsModel.setProvider(.codex, enabled: true)
        XCTAssertTrue(store.isCodexEnabled)
        XCTAssertEqual(appModel.activeProviderStates.map(\.providerID), [.codex])
        _ = transitionResult
        await appModel.refresh()

        let codexFetchCount = await codex.fetchCount
        XCTAssertEqual(codexFetchCount, 1)
        XCTAssertEqual(appModel.activeProviderStates.map(\.providerID), [.codex])
        XCTAssertEqual(appModel.activeProviderStates.first?.status, .available)
    }

    func testProviderTransitionAPIRequiresNoTaskFromSettingsView() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = SettingsNotificationService()
        let model = SettingsModel(
            store: store,
            appModel: AppModel(
                providerIDs: [.codex],
                refreshCoordinator: RefreshCoordinator(
                    usageService: UsageService(providers: [])
                ),
                notificationService: notifications,
                observesLifecycle: false
            ),
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        let result: Void = model.setProvider(.codex, enabled: false)

        _ = result
        XCTAssertFalse(store.isCodexEnabled)
        XCTAssertEqual(notifications.providerTransitions, [.codex: false])
    }

    func testRuntimePresentationChangesDoNotEnterRefreshNotificationResetOrRecoveryPipelines() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let claude = SettingsCountingProvider(id: .claude, usedPercentage: 24)
        let codex = SettingsCountingProvider(id: .codex, usedPercentage: 39)
        let providers: [any UsageProvider] = [claude, codex]
        let notifications = SettingsNotificationService()
        let appModel = AppModel(
            providerIDs: providers.map(\.id),
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: providers, preferences: store)
            ),
            notificationService: notifications,
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )
        await appModel.refresh()
        let baselineNotificationEvaluations = notifications.evaluationCount
        let baselineMenuBarRequested = store.isMenuBarItemRequested
        let baselineMenuBarVisible = settingsModel.isMenuBarItemVisible

        XCTAssertNil(settingsModel.pinnedProviderID)
        XCTAssertEqual(settingsModel.menuBarPresentation.currentlyRenderedProvider, .claude)
        settingsModel.setPinnedProvider(.codex)

        XCTAssertEqual(store.pinnedProviderRawValue, ProviderID.codex.rawValue)
        XCTAssertEqual(settingsModel.menuBarPresentation.currentlyRenderedProvider, .codex)
        XCTAssertEqual(settingsModel.menuBarPresentation.usage?.percentage, 61)

        settingsModel.setUsagePresentationMode(.used)

        let claudeFetchCount = await claude.fetchCount
        let codexFetchCount = await codex.fetchCount
        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertEqual(settingsModel.menuBarPresentation.currentlyRenderedProvider, .codex)
        XCTAssertEqual(settingsModel.menuBarPresentation.usage?.percentage, 39)
        XCTAssertEqual(claudeFetchCount, 1)
        XCTAssertEqual(codexFetchCount, 1)
        // NotificationService.evaluate runs reset detection, while provider enablement
        // invalidates its baseline; presentation changes must enter neither path.
        XCTAssertEqual(notifications.evaluationCount, baselineNotificationEvaluations)
        XCTAssertEqual(notifications.preferencesChangeCount, 0)
        XCTAssertTrue(notifications.providerTransitions.isEmpty)
        XCTAssertEqual(store.isMenuBarItemRequested, baselineMenuBarRequested)
        XCTAssertEqual(settingsModel.isMenuBarItemVisible, baselineMenuBarVisible)
    }

    func testPinnedDisabledProviderDoesNotFallbackAndReenableRestoresIt() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codex = SettingsCountingProvider(id: .codex, usedPercentage: 39)
        let claude = SettingsCountingProvider(id: .claude, usedPercentage: 24)
        let providers: [any UsageProvider] = [codex, claude]
        let notifications = SettingsNotificationService()
        let appModel = AppModel(
            providerIDs: providers.map(\.id),
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: providers, preferences: store)
            ),
            notificationService: notifications,
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )
        await appModel.refresh()
        settingsModel.setPinnedProvider(.claude)

        settingsModel.setProvider(.claude, enabled: false)

        XCTAssertEqual(store.pinnedProviderRawValue, ProviderID.claude.rawValue)
        XCTAssertEqual(settingsModel.pinnedProviderID, .claude)
        XCTAssertEqual(settingsModel.menuBarPresentation.selectedProvider, .claude)
        XCTAssertNil(settingsModel.menuBarPresentation.currentlyRenderedProvider)
        XCTAssertEqual(settingsModel.menuBarPresentation.availability, .disabled)

        settingsModel.setProvider(.claude, enabled: true)

        XCTAssertEqual(settingsModel.menuBarPresentation.selectedProvider, .claude)
        XCTAssertNil(settingsModel.menuBarPresentation.currentlyRenderedProvider)
        XCTAssertEqual(settingsModel.menuBarPresentation.availability, .unavailable)
        await appModel.refresh()

        XCTAssertEqual(store.pinnedProviderRawValue, ProviderID.claude.rawValue)
        XCTAssertEqual(settingsModel.menuBarPresentation.currentlyRenderedProvider, .claude)
        XCTAssertEqual(settingsModel.menuBarPresentation.availability, .renderable)
        XCTAssertEqual(settingsModel.menuBarPresentation.usage?.percentage, 76)
    }

    func testAllProvidersDisabledHasExplicitSafeMenuBarState() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = SettingsNotificationService()
        let appModel = AppModel(
            providerIDs: [.codex, .claude],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [], preferences: store)
            ),
            notificationService: notifications,
            observesLifecycle: false
        )
        let settingsModel = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        settingsModel.setProvider(.codex, enabled: false)
        settingsModel.setProvider(.claude, enabled: false)

        XCTAssertNil(settingsModel.pinnedProviderRawValue)
        XCTAssertNil(settingsModel.menuBarPresentation.selectedProvider)
        XCTAssertNil(settingsModel.menuBarPresentation.currentlyRenderedProvider)
        XCTAssertEqual(settingsModel.menuBarPresentation.availability, .empty)
    }

    func testMenuBarPresentationObservationInvalidatesForPinAndUsageModeChanges() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )
        let pinInvalidated = expectation(description: "Menu bar pin presentation invalidated")
        withObservationTracking {
            _ = model.menuBarPresentation
        } onChange: {
            pinInvalidated.fulfill()
        }

        model.setPinnedProvider(.codex)

        XCTAssertEqual(XCTWaiter.wait(for: [pinInvalidated], timeout: 0), .completed)

        let modeInvalidated = expectation(description: "Menu bar usage mode invalidated")
        withObservationTracking {
            _ = model.menuBarPresentation
        } onChange: {
            modeInvalidated.fulfill()
        }

        model.setUsagePresentationMode(.used)

        XCTAssertEqual(XCTWaiter.wait(for: [modeInvalidated], timeout: 0), .completed)
    }

    func testLaunchAtLoginUsesControllerStateAfterSuccessAndFailure() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appModel = makeAppModel()
        let notifications = SettingsNotificationService()
        let launchController = SettingsLaunchAtLoginController(status: .disabled)
        let model = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: launchController
        )

        model.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)
        XCTAssertFalse(model.launchAtLoginUpdateFailed)

        launchController.shouldFail = true
        model.setLaunchAtLoginEnabled(false)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)
        XCTAssertTrue(model.launchAtLoginUpdateFailed)
    }

    func testRefreshingOnboardingSystemStateDoesNotRequestNotificationAuthorization() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = SettingsNotificationService(status: .notDetermined)
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        await model.refreshSystemState()

        XCTAssertEqual(model.notificationAuthorizationStatus, .notDetermined)
        XCTAssertEqual(notifications.authorizationRequestCount, 0)
    }

    func testExplicitEnableNotificationsUsesSharedPermissionPath() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.setNotificationsEnabled(false)
        let notifications = SettingsNotificationService(status: .notDetermined)
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        await model.enableNotifications()

        XCTAssertTrue(store.areNotificationsEnabled)
        XCTAssertEqual(notifications.preferencesChangeCount, 1)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertEqual(model.notificationAuthorizationStatus, .authorized)
    }

    func testOnboardingCompletionActionsDoNotRequestPermissionOrChangeSettings() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = SettingsNotificationService(status: .notDetermined)
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )
        model.setUsagePresentationMode(.used)
        model.setPinnedProvider(.claude)

        model.skipOnboarding()
        model.completeOnboarding()

        XCTAssertEqual(store.onboardingState, .completed)
        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertEqual(store.pinnedProviderID, .claude)
        XCTAssertEqual(notifications.authorizationRequestCount, 0)
        XCTAssertEqual(notifications.preferencesChangeCount, 0)
    }

    func testMenuBarRecoveryActionRequestsInsertion() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.setMenuBarItemRequested(false)
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        model.setMenuBarItemRequested(true)

        XCTAssertTrue(store.isMenuBarItemRequested)
        XCTAssertFalse(model.isMenuBarItemVisible)
    }

    func testRuntimeMenuBarRemovalDoesNotRewritePersistedUserIntent() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        model.menuBarItemVisibilityDidChange(false)

        XCTAssertFalse(model.isMenuBarItemVisible)
        XCTAssertTrue(store.isMenuBarItemRequested)
    }

    func testExplicitMenuBarHidePersistsUserIntentAndRuntimeState() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )

        model.setMenuBarItemRequested(false)

        XCTAssertFalse(model.isMenuBarItemVisible)
        XCTAssertFalse(store.isMenuBarItemRequested)
    }

    func testExplicitMenuBarHideDoesNotDisableProvidersOrPresentation() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codex = SettingsCountingProvider(id: .codex, usedPercentage: 39)
        let notifications = SettingsNotificationService()
        let appModel = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [codex], preferences: store)
            ),
            notificationService: notifications,
            observesLifecycle: false
        )
        let model = SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: notifications,
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
        )
        await appModel.refresh()
        let baselineNotificationEvaluations = notifications.evaluationCount

        model.setMenuBarItemRequested(false)

        let fetchCount = await codex.fetchCount
        XCTAssertFalse(store.isMenuBarItemRequested)
        XCTAssertFalse(model.isMenuBarItemVisible)
        XCTAssertEqual(appModel.activeProviderStates.map(\.providerID), [.codex])
        XCTAssertEqual(model.menuBarPresentation.currentlyRenderedProvider, .codex)
        XCTAssertEqual(model.menuBarPresentation.usage?.percentage, 61)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(notifications.evaluationCount, baselineNotificationEvaluations)
    }

    func testNormalApplicationTerminationDoesNotMutateMenuBarIntent() {
        for requested in [false, true] {
            let (store, defaults, suiteName) = makeStore()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            store.setMenuBarItemRequested(requested)
            _ = SettingsModel(
                store: store,
                appModel: makeAppModel(),
                notificationService: SettingsNotificationService(),
                launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled)
            )

            NotificationCenter.default.post(
                name: NSApplication.willTerminateNotification,
                object: nil
            )

            XCTAssertEqual(store.isMenuBarItemRequested, requested)
        }
    }

    func testLaunchAtLoginMapsEveryKnownSystemStatus() {
        XCTAssertEqual(LaunchAtLoginController.map(.enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginController.map(.notRegistered), .disabled)
        XCTAssertEqual(LaunchAtLoginController.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginController.map(.notFound), .unavailable)
    }

    func testLaunchAtLoginCanRegisterWhenServiceIsNotFound() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchController = SettingsLaunchAtLoginController(status: .unavailable)
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: launchController
        )

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(model.launchAtLoginStatus, .enabled)
        XCTAssertFalse(model.launchAtLoginUpdateFailed)
    }

    func testCopyDiagnosticsWritesEnglishPrivacySafeReport() async {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clipboard = SettingsDiagnosticClipboard()
        let model = SettingsModel(
            store: store,
            appModel: makeAppModel(),
            notificationService: SettingsNotificationService(),
            launchAtLoginController: SettingsLaunchAtLoginController(status: .disabled),
            diagnosticClipboard: clipboard
        )

        await model.copyDiagnostics()

        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertTrue(clipboard.text?.contains("QuotaMew Diagnostics") == true)
        XCTAssertTrue(clipboard.text?.contains("Privacy:") == true)
        XCTAssertEqual(
            model.diagnosticsCopyFeedback,
            AppLocalization.string("Diagnostics copied.")
        )
    }

    private func makeStore() -> (SettingsStore, UserDefaults, String) {
        let suiteName = "dev.quotapulse.tests.settings.integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (SettingsStore(defaults: defaults), defaults, suiteName)
    }

    private func makeAppModel() -> AppModel {
        AppModel(
            providerIDs: [],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [])
            ),
            notificationService: SettingsNotificationService(),
            observesLifecycle: false
        )
    }

    private func waitUntilRefreshFinishes(_ model: AppModel) async {
        while model.isRefreshing {
            await Task.yield()
        }
    }
}

@MainActor
private final class SettingsDiagnosticClipboard: DiagnosticClipboardWriting {
    private(set) var writeCount = 0
    private(set) var text: String?

    func write(_ text: String) -> Bool {
        writeCount += 1
        self.text = text
        return true
    }
}

private actor SettingsCountingProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let usedPercentage: Double?
    private(set) var fetchCount = 0

    init(id: ProviderID, usedPercentage: Double? = nil) {
        self.id = id
        self.usedPercentage = usedPercentage
    }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        fetchCount += 1
        return ProviderUsageSnapshot(
            providerID: id,
            windows: usedPercentage.map {
                [
                    UsageWindow(
                        id: "primary",
                        label: "Primary window",
                        usedPercentage: $0,
                        resetAt: Date(timeIntervalSince1970: 2_000_003_600),
                        duration: .seconds(18_000)
                    ),
                ]
            } ?? [],
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }
}

@MainActor
private final class SettingsNotificationService: NotificationServicing {
    private(set) var providerTransitions: [ProviderID: Bool] = [:]
    private(set) var evaluationCount = 0
    private(set) var preferencesChangeCount = 0
    private(set) var authorizationRequestCount = 0
    private var status: NotificationAuthorizationStatus

    init(status: NotificationAuthorizationStatus = .authorized) {
        self.status = status
    }

    func evaluate(_ providerStates: [ProviderState], now: Date) async {
        evaluationCount += 1
    }
    func authorizationStatus() async -> NotificationAuthorizationStatus { status }
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        authorizationRequestCount += 1
        status = .authorized
        return status
    }
    func preferencesDidChange() async {
        preferencesChangeCount += 1
    }
    func providerEnablementDidChange(_ providerID: ProviderID, isEnabled: Bool) {
        providerTransitions[providerID] = isEnabled
    }
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

private enum SettingsLaunchAtLoginError: Error {
    case failed
}

@MainActor
private final class SettingsLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus
    var shouldFail = false

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func refreshStatus() {}

    func setEnabled(_ enabled: Bool) throws {
        guard !shouldFail else { throw SettingsLaunchAtLoginError.failed }
        status = enabled ? .enabled : .disabled
    }
}
