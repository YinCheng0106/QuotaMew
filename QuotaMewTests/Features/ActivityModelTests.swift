import Foundation
import Observation
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityModelTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let name = "M3Model-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: SettingsStore
        let source = ModelActivitySource()
        let store = ActivitySnapshotStore()
        let service: ActivityService
        let model: ActivityModel

        init(enabled: Bool = false) {
            defaults = UserDefaults(suiteName: name)!
            settings = SettingsStore(defaults: defaults)
            settings.setCodexAccountActivityEnabled(enabled)
            service = ActivityService(sources: [source], store: store, settings: settings)
            model = ActivityModel(service: service, providerID: .codex, initiallyEnabled: enabled)
        }

        func cleanUp() async {
            await service.shutdown()
            defaults.removePersistentDomain(forName: name)
        }
    }

    func testDisabledAndEnabledConstructionPerformNoIO() async throws {
        let disabled = Fixture()
        XCTAssertEqual(disabled.model.state, .disabled)
        try await disabled.model.refresh()
        let disabledCalls = await disabled.source.calls
        XCTAssertEqual(disabledCalls, 0)
        await disabled.cleanUp()
        let enabled = Fixture(enabled: true)
        XCTAssertEqual(enabled.model.state, .idle)
        let enabledCalls = await enabled.source.calls
        XCTAssertEqual(enabledCalls, 0)
        await enabled.cleanUp()
    }

    func testLoadingObservableAndSuccessfulProjectionsWithoutPersistence() async throws {
        let f = Fixture(enabled: true)
        let before = f.defaults.persistentDomain(forName: f.name)! as NSDictionary
        let changed = expectation(description: "Observable state changed")
        withObservationTracking { _ = f.model.state } onChange: { changed.fulfill() }
        let task = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        XCTAssertEqual(f.model.state, .loading)
        await fulfillment(of: [changed], timeout: 2)
        let snapshot = try activitySnapshot()
        await f.source.complete(0, .success(.snapshot(snapshot)))
        try await task.value
        XCTAssertEqual(f.model.state, .available(try XCTUnwrap(ActivityProjection.query(snapshot))))
        XCTAssertEqual(before, f.defaults.persistentDomain(forName: f.name)! as NSDictionary)
        await f.cleanUp()
    }

    func testEmptySnapshotAndAllNoBucketReasonsRemainDistinct() async throws {
        let f = Fixture(enabled: true)
        let empty = try ProviderActivitySnapshot(providerID: .codex, buckets: [],
                                                 capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
        let outcomes: [ActivityFetchResult] = [.snapshot(empty)] +
            [NoDailyBucketsReason.emptyCollection, .missingCollection, .nullCollection].map {
                .noDailyBuckets(source: .synthetic, capturedAt: empty.capturedAt, reason: $0)
            }
        for (index, outcome) in outcomes.enumerated() {
            let task = Task { try await f.model.refresh() }
            await f.source.waitForCalls(index + 1)
            await f.source.complete(index, .success(outcome))
            try await task.value
            let reason: NoDailyBucketsReason = index < 2 ? .emptyCollection : index == 2 ? .missingCollection : .nullCollection
            XCTAssertEqual(f.model.state, .noReportedBuckets(source: .synthetic, capturedAt: empty.capturedAt, reason: reason))
        }
        await f.cleanUp()
    }

    func testAllFailuresRemovePreviousNumbersAndRawErrors() async throws {
        let f = Fixture(enabled: true)
        let cases: [(Result<ActivityFetchResult, Error>, ActivityModelState)] = [
            (.success(.unsupported), .unsupported),
            (.success(.unavailable(.providerUnavailable)), .unavailable(.providerUnavailable)),
            (.failure(ActivityFetchError.timedOut), .failed(.timedOut)),
            (.failure(ActivityFetchError.invalidData), .failed(.invalidData)),
            (.failure(NSError(domain: "sentinel-private-account-path-body", code: 1)), .failed(.fetchFailed)),
        ]
        for (index, pair) in cases.enumerated() {
            let success = Task { try await f.model.refresh() }
            await f.source.waitForCalls(index * 2 + 1)
            await f.source.complete(index * 2, .success(.snapshot(try activitySnapshot())))
            try await success.value
            guard case .available = f.model.state else { return XCTFail("Expected available") }
            let failure = Task { try await f.model.refresh() }
            await f.source.waitForCalls(index * 2 + 2)
            XCTAssertEqual(f.model.state, .loading)
            await f.source.complete(index * 2 + 1, pair.0)
            try await failure.value
            XCTAssertEqual(f.model.state, pair.1)
            XCTAssertFalse(String(describing: f.model.state).contains("sentinel-private"))
        }
        await f.cleanUp()
    }

    func testProjectionOverflowFailsWithoutNumbers() async throws {
        let f = Fixture(enabled: true)
        let snapshot = try ProviderActivitySnapshot(providerID: .codex, buckets: [
            ActivityBucket(sourceDate: ProviderCalendarDate("2026-10-01"), reportedTokens: Int64.max),
            ActivityBucket(sourceDate: ProviderCalendarDate("2026-10-02"), reportedTokens: 1)
        ], capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
        let task = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        await f.source.complete(0, .success(.snapshot(snapshot)))
        try await task.value
        XCTAssertEqual(f.model.state, .failed(.invalidData))
        await f.cleanUp()
    }

    func testDisableImmediatelyClearsAndReenableWaitsForExplicitRefresh() async throws {
        let f = Fixture(enabled: true)
        let first = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        try await first.value
        let disable = Task { await f.model.setEnabled(false) }
        // Main actor executes clearing before the first suspension.
        await disable.value
        XCTAssertEqual(f.model.state, .disabled)
        let cleared = await f.store.snapshot(for: .codex)
        XCTAssertNil(cleared)
        await f.model.setEnabled(true)
        XCTAssertEqual(f.model.state, .idle)
        let calls = await f.source.calls
        XCTAssertEqual(calls, 1)
        let second = Task { try await f.model.refresh() }
        await f.source.waitForCalls(2)
        await f.source.complete(1, .success(.snapshot(try activitySnapshot(date: "2026-10-02"))))
        try await second.value
        guard case .available(let projection) = f.model.state else { return XCTFail("Expected available") }
        XCTAssertEqual(projection.latestReported.sourceDate.rawValue, "2026-10-02")
        await f.cleanUp()
    }

    func testLateCompletionCannotRestoreDisabledState() async throws {
        let f = Fixture(enabled: true)
        let old = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        await f.model.setEnabled(false)
        XCTAssertEqual(f.model.state, .disabled)
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        _ = try? await old.value
        XCTAssertEqual(f.model.state, .disabled)
        await f.cleanUp()
    }

    func testInvalidatedOldCompletionCannotOverwriteNewerCycle() async throws {
        let f = Fixture(enabled: true)
        let old = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        await f.model.invalidate()
        XCTAssertEqual(f.model.state, .idle)
        let newer = Task { try await f.model.refresh() }
        await f.source.waitForCalls(2)
        let snapshot = try activitySnapshot(date: "2026-10-02")
        await f.source.complete(1, .success(.snapshot(snapshot)))
        try await newer.value
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        _ = try? await old.value
        XCTAssertEqual(f.model.state, .available(try XCTUnwrap(ActivityProjection.query(snapshot))))
        await f.cleanUp()
    }

    func testOverlappingRefreshAndOneCanceledCallerShareCycle() async throws {
        let f = Fixture(enabled: true)
        let callers = (0..<20).map { _ in Task { try await f.model.refresh() } }
        await f.source.waitForCalls(1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while f.model.refreshCallerCount < 20, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(f.model.refreshCallerCount, 20)
        callers[0].cancel()
        let count = await f.source.calls
        XCTAssertEqual(count, 1)
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        do { try await callers[0].value; XCTFail("Expected canceled waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        for caller in callers.dropFirst() { try await caller.value }
        guard case .available = f.model.state else { return XCTFail("Shared cycle must publish") }
        await f.cleanUp()
    }

    func testHundredRapidManualRefreshCallersSettleAfterOneAcquisition() async throws {
        let f = Fixture(enabled: true)
        let callers = (0..<100).map { _ in Task { try await f.model.refresh() } }
        await f.source.waitForCalls(1)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while f.model.refreshCallerCount != 100 && clock.now < deadline { await Task.yield() }
        XCTAssertEqual(f.model.refreshCallerCount, 100)
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        for caller in callers { try await caller.value }
        XCTAssertEqual(f.model.refreshCallerCount, 0)
        let calls = await f.source.calls
        XCTAssertEqual(calls, 1)
        guard case .available = f.model.state else { return XCTFail("Expected one published projection") }
        await f.cleanUp()
    }

    func testRapidDisableReenableAndRepeatedEnableFenceOldWork() async throws {
        let f = Fixture(enabled: true)
        let old = Task { try await f.model.refresh() }
        await f.source.waitForCalls(1)
        let disabled = Task { await f.model.setEnabled(false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while f.model.state != .disabled, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(f.model.state, .disabled)
        let enabled = Task { await f.model.setEnabled(true) }
        await disabled.value
        await enabled.value
        XCTAssertTrue(f.settings.isActivityEnabled(.codex))
        XCTAssertEqual(f.model.state, .idle)
        let newer = Task { try await f.model.refresh() }
        await f.source.waitForCalls(2)
        await f.source.complete(1, .success(.snapshot(try activitySnapshot(date: "2026-10-02"))))
        try await newer.value
        await f.source.complete(0, .success(.snapshot(try activitySnapshot())))
        _ = try? await old.value
        guard case .available(let projection) = f.model.state else { return XCTFail("Expected new cycle") }
        XCTAssertEqual(projection.latestReported.sourceDate.rawValue, "2026-10-02")
        await f.cleanUp()
    }

    func testProviderNeutralConsumptionAndCurrentEligibilityRecheck() async throws {
        let source = ModelActivitySource(id: .claude)
        let service = ActivityService(sources: [source], store: ActivitySnapshotStore(), consent: { _ in true })
        let model = ActivityModel(service: service, providerID: .claude, initiallyEnabled: true)
        let task = Task { try await model.refresh() }
        await source.waitForCalls(1)
        let snapshot = try activitySnapshot(provider: .claude)
        await source.complete(0, .success(.snapshot(snapshot)))
        try await task.value
        XCTAssertEqual(model.state, .available(try XCTUnwrap(ActivityProjection.query(snapshot))))
        await service.shutdown()
        let f = Fixture(enabled: true)
        f.settings.setProvider(.codex, enabled: false)
        try await f.model.refresh()
        XCTAssertEqual(f.model.state, .disabled)
        let count = await f.source.calls
        XCTAssertEqual(count, 0)
        await f.cleanUp()
    }

    func testRefreshDuringEnableWaitsForTransitionPublication() async throws {
        let gate = ModelConsentGate()
        let source = ModelActivitySource()
        let service = ActivityService(sources: [source], store: ActivitySnapshotStore(),
                                      consent: { _ in await gate.read() })
        let model = ActivityModel(service: service, providerID: .codex, initiallyEnabled: false)
        let enable = Task { await model.setEnabled(true) }
        await gate.waitForRead()
        let refresh = Task { try await model.refresh() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.refreshCallerCount < 1, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.refreshCallerCount, 1)
        let before = await source.calls
        XCTAssertEqual(before, 0, "Source must wait for consent transition")
        await gate.release()
        await source.waitForCalls(1)
        await enable.value
        XCTAssertEqual(model.state, .loading, "Transition caller must not overwrite refresh state")
        await source.complete(0, .success(.snapshot(try activitySnapshot())))
        try await refresh.value
        guard case .available = model.state else { return XCTFail("Expected shared result") }
        await service.shutdown()
    }
}

private actor ModelConsentGate {
    private var didRead = false
    private var pending: CheckedContinuation<Bool, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func read() async -> Bool {
        if didRead { return true }
        didRead = true
        return await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(returning: true); pending = nil }
}

private actor ModelActivitySource: TokenActivitySource {
    nonisolated let id: ProviderID
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<ActivityFetchResult, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    init(id: ProviderID = .codex) { self.id = id }
    func fetchActivity() async throws -> ActivityFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            pending[calls] = continuation
            calls += 1
            let ready = observers.filter { $0.0 <= calls }
            observers.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func complete(_ index: Int, _ result: Result<ActivityFetchResult, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}
