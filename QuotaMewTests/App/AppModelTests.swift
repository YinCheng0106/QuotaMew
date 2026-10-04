import XCTest
@testable import QuotaMew

@MainActor
final class AppModelTests: XCTestCase {
    func testHostedUnitTestsDoNotCreateStatusItemController() {
        XCTAssertTrue(AppRuntimeEnvironment.isRunningTests)
        XCTAssertFalse(AppRuntimeEnvironment.shouldCreateStatusItemController)
    }

    func testLiveDependenciesUseBothSharedProviderAdapters() {
        let providers = AppDependencies.makeLiveProviders()

        XCTAssertEqual(providers.map(\.id), [.codex, .claude])
    }

    func testAppFactoryDoesNotStartProviderIOInsideXCTestHost() async {
        let counter = AppFactoryFetchCounter()
        let model = AppDependencies.makeAppModel(
            providers: [AppFactoryCountingProvider(counter: counter)]
        )

        await Task.yield()

        var fetchCount = await counter.value
        XCTAssertEqual(fetchCount, 0)

        await model.refresh()
        fetchCount = await counter.value
        XCTAssertEqual(fetchCount, 1)
    }

    func testDashboardStateContainsOnlyEnabledProviders() {
        let model = AppModel(
            providerIDs: [.codex, .claude],
            enabledProviderIDs: [.claude],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [])
            ),
            notificationService: TestNotificationService(),
            observesLifecycle: false
        )

        XCTAssertEqual(model.providerStates.map(\.providerID), [.codex, .claude])
        XCTAssertEqual(model.activeProviderStates.map(\.providerID), [.claude])
        XCTAssertEqual(model.providerStates.first?.status, .disabled)
        XCTAssertTrue(model.hasEnabledProviders)
    }

    func testDashboardStateReportsEmptyWhenAllProvidersAreDisabled() {
        let model = AppModel(
            providerIDs: [.codex, .claude],
            enabledProviderIDs: [],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [])
            ),
            notificationService: TestNotificationService(),
            observesLifecycle: false
        )

        XCTAssertTrue(model.activeProviderStates.isEmpty)
        XCTAssertFalse(model.hasEnabledProviders)
        XCTAssertEqual(model.providerStates.map(\.status), [.disabled, .disabled])
    }

    func testProviderEligibilityUpdatesDashboardStateImmediately() {
        let model = AppModel(
            providerIDs: [.codex, .claude],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [])
            ),
            notificationService: TestNotificationService(),
            observesLifecycle: false
        )

        model.applyProviderEligibilityChange(.codex, isEnabled: false)
        XCTAssertEqual(model.activeProviderStates.map(\.providerID), [.claude])

        model.applyProviderEligibilityChange(.codex, isEnabled: true)
        XCTAssertEqual(model.activeProviderStates.map(\.providerID), [.codex, .claude])
        XCTAssertEqual(model.providerStates.first?.status, .loading)
    }

    func testRefreshPublishesLoadingAndUsesSnapshotCaptureTime() async {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let gate = AppModelProviderGate()
        let provider = GatedAppModelProvider(capturedAt: capturedAt, gate: gate)
        let usageService = UsageService(providers: [provider])
        let model = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(usageService: usageService),
            notificationService: TestNotificationService()
        )

        let refresh = Task { await model.refresh() }
        await gate.waitForFetch()

        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.providerStates.map(\.status), [.loading])

        await gate.open()
        await refresh.value

        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.providerStates.map(\.status), [.available])
        XCTAssertEqual(model.lastUpdatedAt, capturedAt)
    }

    func testUnavailableProvidersDoNotClaimSuccessfulUpdateTime() async {
        let providers: [any UsageProvider] = [
            FailingAppModelProvider(id: .codex, status: .notInstalled),
            FailingAppModelProvider(id: .claude, status: .notConfigured),
        ]
        let usageService = UsageService(providers: providers)
        let model = AppModel(
            providerIDs: providers.map(\.id),
            refreshCoordinator: RefreshCoordinator(usageService: usageService),
            notificationService: TestNotificationService()
        )

        await model.refresh()

        XCTAssertEqual(model.providerStates.map(\.status), [.notInstalled, .notConfigured])
        XCTAssertNil(model.lastUpdatedAt)
    }

    func testRefreshFailureKeepsPreviouslySuccessfulSnapshotVisible() async {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let provider = SuccessfulThenFailingAppModelProvider(capturedAt: capturedAt)
        let usageService = UsageService(providers: [provider])
        let model = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(usageService: usageService),
            notificationService: TestNotificationService()
        )

        await model.refresh()
        let successfulSnapshot = model.providerStates[0].snapshot

        await model.refresh()

        XCTAssertEqual(model.providerStates[0].status, .failed(.refreshFailed))
        XCTAssertEqual(model.providerStates[0].snapshot, successfulSnapshot)
        XCTAssertEqual(model.lastUpdatedAt, capturedAt)
    }

    func testClaudeFailureClearsCachedSampleWithUnknownContinuity() async {
        let provider = SuccessfulThenFailingAppModelProvider(capturedAt: .now, id: .claude)
        let model = AppModel(providerIDs: [.claude],
            refreshCoordinator: RefreshCoordinator(usageService: UsageService(providers: [provider])),
            notificationService: TestNotificationService(), observesLifecycle: false)
        await model.refresh()
        XCTAssertNotNil(model.providerStates.first?.snapshot)
        await model.refresh()
        XCTAssertEqual(model.providerStates.first?.status, .failed(.refreshFailed))
        XCTAssertNil(model.providerStates.first?.snapshot)
    }

    func testClaudeDisableAndUnavailableSourceClearSample() async {
        for failure in [ProviderStatus.notConfigured, .failed(.refreshFailed)] {
            let provider = SuccessfulThenFailingAppModelProvider(capturedAt: .now, id: .claude, failureStatus: failure)
            let model = AppModel(providerIDs: [.claude],
                refreshCoordinator: RefreshCoordinator(usageService: UsageService(providers: [provider])),
                notificationService: TestNotificationService(), observesLifecycle: false)
            await model.refresh()
            await model.refresh()
            XCTAssertEqual(model.providerStates.first?.status, failure)
            XCTAssertNil(model.providerStates.first?.snapshot)
        }
        let provider = SuccessfulThenFailingAppModelProvider(capturedAt: .now, id: .claude)
        let model = AppModel(providerIDs: [.claude],
            refreshCoordinator: RefreshCoordinator(usageService: UsageService(providers: [provider])),
            notificationService: TestNotificationService(), observesLifecycle: false)
        await model.refresh()
        model.applyProviderEligibilityChange(.claude, isEnabled: false)
        XCTAssertEqual(model.providerStates.first?.status, .disabled)
        XCTAssertNil(model.providerStates.first?.snapshot)
    }

    #if DEBUG
    func testUserTriggeredNotificationUsesInjectedService() async {
        let notificationService = TestNotificationService()
        let usageService = UsageService(providers: [])
        let model = AppModel(
            providerIDs: [],
            refreshCoordinator: RefreshCoordinator(usageService: usageService),
            notificationService: notificationService
        )

        await model.sendTestNotification()

        XCTAssertEqual(notificationService.sendCount, 1)
        XCTAssertEqual(
            model.notificationFeedback,
            String(localized: "Test notification scheduled for about 5 seconds from now.")
        )
    }
    #endif
}

private actor AppModelProviderGate {
    private var didFetch = false
    private var isOpen = false
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func fetched() async {
        didFetch = true
        let pendingFetchWaiters = fetchWaiters
        fetchWaiters.removeAll()
        pendingFetchWaiters.forEach { $0.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitForFetch() async {
        guard !didFetch else { return }
        await withCheckedContinuation { continuation in
            fetchWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingOpenWaiters = openWaiters
        openWaiters.removeAll()
        pendingOpenWaiters.forEach { $0.resume() }
    }
}

private struct GatedAppModelProvider: UsageProvider {
    let id = ProviderID.codex
    let capturedAt: Date
    let gate: AppModelProviderGate

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        await gate.fetched()
        return ProviderUsageSnapshot(
            providerID: id,
            windows: [],
            capturedAt: capturedAt,
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }
}

private struct FailingAppModelProvider: UsageProvider {
    let id: ProviderID
    let status: ProviderStatus

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        throw AppModelProviderStatusError(providerStatus: status)
    }
}

private actor SuccessfulThenFailingAppModelProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let capturedAt: Date
    private var fetchCount = 0
    private let failureStatus: ProviderStatus

    init(capturedAt: Date, id: ProviderID = .codex, failureStatus: ProviderStatus = .failed(.refreshFailed)) {
        self.capturedAt = capturedAt
        self.id = id
        self.failureStatus = failureStatus
    }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        fetchCount += 1
        guard fetchCount == 1 else {
            throw AppModelProviderStatusError(providerStatus: failureStatus)
        }

        return ProviderUsageSnapshot(
            providerID: id,
            windows: [
                UsageWindow(
                    id: "codex.primary",
                    label: "Primary window",
                    usedPercentage: 42,
                    resetAt: capturedAt.addingTimeInterval(3_600),
                    duration: .seconds(18_000)
                )
            ],
            capturedAt: capturedAt,
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }
}

private struct AppModelProviderStatusError: ProviderStatusProvidingError {
    let providerStatus: ProviderStatus
}

private actor AppFactoryFetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct AppFactoryCountingProvider: UsageProvider {
    let id = ProviderID.codex
    let counter: AppFactoryFetchCounter

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        await counter.increment()
        return ProviderUsageSnapshot(
            providerID: id,
            windows: [],
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
        )
    }
}

@MainActor
private final class TestNotificationService: NotificationServicing {
    #if DEBUG
    private(set) var sendCount = 0
    #endif

    func evaluate(_ providerStates: [ProviderState], now: Date) async {}

    #if DEBUG
    func sendTestNotification() async throws {
        sendCount += 1
    }
    #endif
}
