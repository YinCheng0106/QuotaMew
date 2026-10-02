import Foundation
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityServiceTests: XCTestCase {
    private func settings() -> (SettingsStore, UserDefaults, String) {
        let name = "ActivityM2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: defaults), defaults, name)
    }

    func testDefaultDisabledAndEnableDoesNotFetch() async throws {
        let (settings, defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, settings: settings)
        let initial = try await service.refresh(provider: .codex)
        XCTAssertEqual(initial, .disabled)
        await service.setCodexAccountActivityEnabled(true)
        let calls = await source.callCount
        XCTAssertEqual(calls, 0, "Construction and enablement never start I/O")
        await service.shutdown()
    }

    func testSuccessfulReplacementEmptySnapshotAndNoDailyBuckets() async throws {
        let store = ActivitySnapshotStore()
        let source = BlockingActivitySource()
        let service = ActivityService(sources: [source], store: store, consent: { _ in true })
        let first = try activitySnapshot(date: "2026-10-01")
        let second = try activitySnapshot(date: "2026-10-02")
        let empty = try ProviderActivitySnapshot(providerID: .codex, buckets: [], capturedAt: Date(), source: .synthetic)
        for (index, snapshot) in [first, second, empty].enumerated() {
            let task = Task { try await service.refresh(provider: .codex) }
            await source.waitForCalls(index + 1)
            let cleared = await store.snapshot(for: .codex)
            XCTAssertNil(cleared, "Refresh start clears previous account data")
            await source.complete(index, with: .success(.snapshot(snapshot)))
            let result = try await task.value
            let stored = await store.snapshot(for: .codex)
            XCTAssertEqual(result, .snapshot(snapshot))
            XCTAssertEqual(stored, snapshot)
        }
        for (offset, reason) in [NoDailyBucketsReason.emptyCollection, .missingCollection, .nullCollection].enumerated() {
            await store.replace(snapshot: first)
            let expected = ActivityFetchResult.noDailyBuckets(source: .synthetic, capturedAt: Date(), reason: reason)
            let task = Task { try await service.refresh(provider: .codex) }
            await source.waitForCalls(4 + offset)
            await source.complete(3 + offset, with: .success(expected))
            let result = try await task.value
            XCTAssertEqual(result, expected)
            let stored = await store.snapshot(for: .codex)
            XCTAssertNil(stored)
        }
        await service.shutdown()
    }

    func testEveryFailureClearsAndNormalizesWithoutRawErrors() async throws {
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, consent: { _ in true })
        let outcomes: [(Result<ActivityFetchResult, Error>, ActivityFetchResult)] = [
            (.success(.unsupported), .unsupported),
            (.failure(ActivityFetchError.providerUnavailable), .unavailable(.providerUnavailable)),
            (.failure(ActivityFetchError.invalidData), .failed(.invalidData)),
            (.failure(ActivityFetchError.fetchFailed), .failed(.fetchFailed)),
            (.failure(ActivityFetchError.timedOut), .failed(.timedOut)),
            (.failure(ActivityFetchError.limitExceeded), .failed(.limitExceeded)),
            (.failure(NSError(domain: "private-provider-body", code: 1)), .failed(.fetchFailed)),
            (.success(.snapshot(try activitySnapshot(provider: .claude))), .failed(.invalidData)),
        ]
        for (index, pair) in outcomes.enumerated() {
            await store.replace(snapshot: try activitySnapshot())
            let task = Task { try await service.refresh(provider: .codex) }
            await source.waitForCalls(index + 1)
            await source.complete(index, with: pair.0)
            let result = try await task.value
            XCTAssertEqual(result, pair.1)
            let stored = await store.snapshot(for: .codex)
            XCTAssertNil(stored)
        }
        await service.shutdown()
    }

    func testDisableLateSuccessCannotResurrectAndNewGenerationSucceeds() async throws {
        let (settings, defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, settings: settings)
        await service.setCodexAccountActivityEnabled(true)
        let old = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(1)
        await service.setCodexAccountActivityEnabled(false)
        var stored = await store.snapshot(for: .codex)
        XCTAssertNil(stored)
        await source.complete(0, with: .success(.snapshot(try activitySnapshot())))
        let disabled = try await old.value
        XCTAssertEqual(disabled, .disabled)
        stored = await store.snapshot(for: .codex)
        XCTAssertNil(stored)
        await service.setCodexAccountActivityEnabled(true)
        let calls = await source.callCount
        XCTAssertEqual(calls, 1)
        let current = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(2)
        let replacement = try activitySnapshot(date: "2026-10-02")
        await source.complete(1, with: .success(.snapshot(replacement)))
        _ = try await current.value
        stored = await store.snapshot(for: .codex)
        XCTAssertEqual(stored, replacement)
        await service.shutdown()
    }

    func testInvalidationLateCompletionCannotReplaceNewGeneration() async throws {
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, consent: { _ in true })
        let old = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(1)
        await service.invalidate(provider: .codex)
        let new = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(2)
        let replacement = try activitySnapshot(date: "2026-10-02")
        await source.complete(1, with: .success(.snapshot(replacement)))
        _ = try await new.value
        await source.complete(0, with: .success(.snapshot(try activitySnapshot())))
        let oldResult = try await old.value
        XCTAssertEqual(oldResult, .unavailable(.providerUnavailable))
        let stored = await store.snapshot(for: .codex)
        XCTAssertEqual(stored, replacement)
        await service.shutdown()
    }

    func testFinalConsentBoundaryAndPublicationRecheck() async throws {
        let gate = ConsentGate()
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, consent: { _ in await gate.read() })
        let queued = Task { try await service.refresh(provider: .codex) }
        await gate.waitForRead()
        await gate.release(enabled: false)
        let result = try await queued.value
        XCTAssertEqual(result, .disabled)
        let calls = await source.callCount
        XCTAssertEqual(calls, 0, "Consent revoked during admission must prevent source I/O")
        await service.shutdown()

        let (settings, defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.setCodexAccountActivityEnabled(true)
        let second = ActivityService(sources: [source], store: store, settings: settings)
        let active = Task { try await second.refresh(provider: .codex) }
        await source.waitForCalls(1)
        settings.setCodexAccountActivityEnabled(false)
        await source.complete(0, with: .success(.snapshot(try activitySnapshot())))
        let revoked = try await active.value
        XCTAssertEqual(revoked, .disabled)
        let stored = await store.snapshot(for: .codex)
        XCTAssertNil(stored)
        await second.shutdown()
    }

    func testOverlappingCallersCoalesceAndCallerCancellationPreservesSharedWork() async throws {
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, consent: { _ in true })
        let callers = (0..<20).map { _ in Task { try await service.refresh(provider: .codex) } }
        await source.waitForCalls(1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await service.refreshCallerCount() != 20, ContinuousClock.now < deadline { await Task.yield() }
        let count = await service.refreshCallerCount()
        XCTAssertEqual(count, 20)
        callers[0].cancel()
        let snapshot = try activitySnapshot()
        await source.complete(0, with: .success(.snapshot(snapshot)))
        do { _ = try await callers[0].value; XCTFail("Expected caller cancellation") }
        catch is CancellationError {}
        for caller in callers.dropFirst() {
            let result = try await caller.value
            XCTAssertEqual(result, .snapshot(snapshot))
        }
        let calls = await source.callCount
        let stored = await store.snapshot(for: .codex)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(stored, snapshot)
        await service.shutdown()
    }

    func testSourceCancellationClearsAndLaterRefreshWorks() async throws {
        let source = BlockingActivitySource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, consent: { _ in true })
        await store.replace(snapshot: try activitySnapshot())
        let cancelled = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(1)
        await source.complete(0, with: .failure(CancellationError()))
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let stored = await store.snapshot(for: .codex)
        XCTAssertNil(stored)
        let next = Task { try await service.refresh(provider: .codex) }
        await source.waitForCalls(2)
        await source.complete(1, with: .success(.snapshot(try activitySnapshot())))
        _ = try await next.value
        await service.shutdown()
    }

    func testProviderFailureIsIndependentAndShutdownInvalidatesInFlight() async throws {
        let codex = BlockingActivitySource()
        let claude = BlockingActivitySource(id: .claude)
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [codex, claude], store: store, consent: { _ in true })
        let other = try activitySnapshot(provider: .claude)
        await store.replace(snapshot: other)
        let task = Task { try await service.refresh(provider: .codex) }
        await codex.waitForCalls(1)
        await codex.complete(0, with: .failure(ActivityFetchError.timedOut))
        _ = try await task.value
        let retained = await store.snapshot(for: .claude)
        XCTAssertEqual(retained, other)
        let active = Task { try await service.refresh(provider: .codex) }
        await codex.waitForCalls(2)
        let shutdown = Task { await service.shutdown() }
        // shutdown clears before draining a cancellation-insensitive synthetic source.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await store.snapshot(for: .claude) != nil, ContinuousClock.now < deadline { await Task.yield() }
        await codex.complete(1, with: .success(.snapshot(try activitySnapshot())))
        _ = try await active.value
        await shutdown.value
        let cleared = await store.snapshot(for: .codex)
        XCTAssertNil(cleared)
        let stopped = try await service.refresh(provider: .codex)
        XCTAssertEqual(stopped, .unavailable(.providerUnavailable))
    }

    func testUnsupportedMissingSourceAndQuotaProviderDisabledDoNotFetch() async throws {
        let store = ActivitySnapshotStore()
        await store.replace(snapshot: try activitySnapshot())
        let missing = ActivityService(sources: [], store: store, consent: { _ in true })
        let result = try await missing.refresh(provider: .codex)
        XCTAssertEqual(result, .unsupported)
        let cleared = await store.snapshot(for: .codex)
        XCTAssertNil(cleared)
        await missing.shutdown()
        let (settings, defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.setCodexAccountActivityEnabled(true)
        settings.setProvider(.codex, enabled: false)
        let source = BlockingActivitySource()
        let disabled = ActivityService(sources: [source], store: store, settings: settings)
        let state = try await disabled.refresh(provider: .codex)
        XCTAssertEqual(state, .disabled)
        let calls = await source.callCount
        XCTAssertEqual(calls, 0)
        await disabled.shutdown()
    }
}

func activitySnapshot(provider: ProviderID = .codex, date: String = "2026-10-01") throws -> ProviderActivitySnapshot {
    try ProviderActivitySnapshot(providerID: provider,
        buckets: [ActivityBucket(sourceDate: ProviderCalendarDate(date), reportedTokens: 41)],
        capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
}

private actor BlockingActivitySource: TokenActivitySource {
    nonisolated let id: ProviderID
    private(set) var callCount = 0
    private var completions: [Int: CheckedContinuation<ActivityFetchResult, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(id: ProviderID = .codex) { self.id = id }

    func fetchActivity() async throws -> ActivityFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            completions[callCount] = continuation
            callCount += 1
            let ready = observers.filter { $0.0 <= callCount }
            observers.removeAll { $0.0 <= callCount }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func complete(_ index: Int, with result: Result<ActivityFetchResult, Error>) {
        completions.removeValue(forKey: index)?.resume(with: result)
    }
}

private actor ConsentGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func read() async -> Bool {
        await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release(enabled: Bool) { pending?.resume(returning: enabled); pending = nil }
}
