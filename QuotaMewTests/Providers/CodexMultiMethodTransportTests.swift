import Darwin
import Foundation
import XCTest
@testable import QuotaMew

final class CodexMultiMethodTransportTests: XCTestCase {
    @MainActor
    func testM2ProductionAssemblyIsIdleSharesClientAndServiceShutdownPreservesQuota() async throws {
        let server = try ScriptedCodexServer()
        let name = "M2Assembly-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setCodexAccountActivityEnabled(true)
        let runtime = AppDependencies.makeRuntime(settingsStore: settings, codexClient: server.client)
        do {
            let queues = await server.client.requestQueueCounts()
            XCTAssertTrue(queues == (0, 0, 0), "Production assembly never requests activity or quota in tests")
            let notStarted = await server.client.runtimeDiagnostic()
            XCTAssertEqual(notStarted.appServerState, .notStarted)
            XCTAssertEqual(runtime.activityModel.state, .idle)
            await runtime.activityModel.setEnabled(false)
            XCTAssertEqual(runtime.activityModel.state, .disabled)
            await runtime.activityModel.setEnabled(true)
            XCTAssertEqual(runtime.activityModel.state, .idle)
            let afterEnable = await server.client.runtimeDiagnostic()
            XCTAssertEqual(afterEnable.appServerState, .notStarted)
            let quota = Task { await runtime.appModel.refresh() }
            let first = try await server.nextRequest()
            XCTAssertEqual(first.method, "account/rateLimits/read")
            try server.reply()
            await quota.value
            let diagnostic = await server.client.runtimeDiagnostic()
            for _ in 0..<2 {
                let activity = Task { try await runtime.activityService.refresh(provider: .codex) }
                let event = try await server.nextRequest()
                XCTAssertEqual(event.method, "account/usage/read")
                XCTAssertEqual(event.pid, first.pid)
                XCTAssertEqual(event.initialized, 1)
                XCTAssertFalse(event.overlap)
                try server.reply(fixture: "valid-usage")
                guard case .snapshot(let snapshot) = try await activity.value else {
                    XCTFail("Expected service snapshot"); await server.close(); return
                }
                let stored = await runtime.activityStore.snapshot(for: .codex)
                XCTAssertEqual(stored, snapshot)
                let after = await server.client.runtimeDiagnostic()
                XCTAssertEqual(after, diagnostic, "Activity does not update quota diagnostics")
                let next = try await server.quota()
                XCTAssertEqual(next.pid, first.pid)
            }
            let modelRefresh = Task { try await runtime.activityModel.refresh() }
            let modelEvent = try await server.nextRequest()
            XCTAssertEqual(modelEvent.method, "account/usage/read")
            XCTAssertEqual(modelEvent.pid, first.pid)
            try server.reply(fixture: "valid-usage")
            try await modelRefresh.value
            guard case .available = runtime.activityModel.state else {
                XCTFail("Production model must consume shared service result"); await server.close(); return
            }
            await runtime.activityModel.invalidate()
            XCTAssertEqual(runtime.activityModel.state, .idle)
            await runtime.activityService.shutdown()
            let cleared = await runtime.activityStore.snapshot(for: .codex)
            XCTAssertNil(cleared)
            let quotaAfterShutdown = try await server.quota()
            XCTAssertEqual(quotaAfterShutdown.pid, first.pid, "Service must not shut down the shared client")
            await server.close()
            XCTAssertTrue(isReaped(first.pid))
        } catch { await runtime.activityService.shutdown(); await server.close(); throw error }
    }

    @MainActor
    func testM2DisableCancelsQueuedActivityWithoutTouchingActiveQuota() async throws {
        let server = try ScriptedCodexServer()
        let name = "M2Queued-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [CodexTokenActivitySource(reader: server.client)], store: store, settings: settings)
        await service.setCodexAccountActivityEnabled(true)
        do {
            let quota = Task { try await server.client.readRateLimits() }
            let first = try await server.nextRequest()
            let activity = Task { try await service.refresh(provider: .codex) }
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 1)
            await service.setCodexAccountActivityEnabled(false)
            do { _ = try await activity.value; XCTFail("Expected cancelled activity waiter") }
            catch is CancellationError {}
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 0)
            XCTAssertFalse(isReaped(first.pid))
            try server.reply()
            _ = try await quota.value
            let next = try await server.quota()
            XCTAssertEqual(next.pid, first.pid)
            XCTAssertEqual(next.id, first.id + 1, "Disabled queued activity writes no RPC")
            await service.shutdown()
            await server.close()
        } catch { await service.shutdown(); await server.close(); throw error }
    }

    func testM1AdapterUsesSharedTransportAndPreservesQuotaAfterInvalidDataAndUnsupported() async throws {
        let server = try ScriptedCodexServer()
        do {
            let first = try await server.quota()
            let diagnostic = await server.client.runtimeDiagnostic()
            let source = CodexTokenActivitySource(reader: server.client, now: { .distantPast })
            let valid = Task { try await source.fetchActivity() }
            _ = try await server.nextRequest()
            try server.reply(fixture: "valid-usage")
            guard case .snapshot(let snapshot) = try await valid.value else {
                XCTFail("Expected validated activity snapshot")
                await server.close()
                return
            }
            XCTAssertEqual(snapshot.buckets.map(\.reportedTokens), [2100, 0])
            for invalid in [false, true] {
                let activity = Task { try await source.fetchActivity() }
                let event = try await server.nextRequest()
                XCTAssertEqual(event.pid, first.pid)
                if invalid {
                    try server.reply(fixture: "malformed-usage")
                    do { _ = try await activity.value; XCTFail("Expected invalid core rejection") }
                    catch { XCTAssertEqual(error as? ActivityFetchError, .invalidData) }
                } else {
                    try server.sendLines(["{\"id\":\(event.id),\"error\":{\"code\":-32601," +
                        "\"message\":\"private@example.com acct-secret thread-secret /private/repo SECRET_PROMPT SECRET_RAW_JSON\"}}"])
                    let result = try await activity.value
                    XCTAssertEqual(result, .unsupported)
                    XCTAssertFalse(String(reflecting: result).contains("SECRET"))
                }
                let after = await server.client.runtimeDiagnostic()
                XCTAssertEqual(diagnostic, after)
                let quota = try await server.quota()
                XCTAssertEqual(quota.pid, first.pid)
            }
            await server.close()
            XCTAssertTrue(isReaped(first.pid))
        } catch { await server.close(); throw error }
    }

    func testAlternatingMethodsInitializeOnceAndReuseOneChild() async throws {
        let server = try ScriptedCodexServer()
        do {
            let first = try await server.quota()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            let second = try await server.nextRequest()
            XCTAssertEqual(second.method, "account/usage/read")
            try server.reply(fixture: "valid-usage")
            let result = try await usage.value
            XCTAssertEqual(result.dailyUsageBuckets?.map(\.tokens), [2100, 0])
            let third = try await server.quota()
            XCTAssertEqual([first.pid, second.pid, third.pid], [first.pid, first.pid, first.pid])
            XCTAssertEqual([first.id, second.id, third.id], [2, 3, 4])
            XCTAssertEqual([first.initialized, second.initialized, third.initialized], [1, 1, 1])
            XCTAssertFalse(first.overlap || second.overlap || third.overlap)
            await server.close()
            XCTAssertTrue(isReaped(first.pid))
        } catch { await server.close(); throw error }
    }

    func testUsageOptionalAndFutureFieldsAreTransportOnly() async throws {
        let server = try ScriptedCodexServer()
        do {
            let first = try await server.quota()
            for fixture in ["null-buckets", "missing-buckets", "future-fields"] {
                let usage = Task { try await server.client.readAccountUsageTransport() }
                let event = try await server.nextRequest()
                try server.reply(fixture: fixture)
                let result = try await usage.value
                XCTAssertEqual(event.pid, first.pid)
                if fixture == "future-fields" {
                    XCTAssertEqual(result.dailyUsageBuckets?.first?.tokens, 123)
                    XCTAssertFalse(String(reflecting: result).contains("synthetic-private-sentinel"))
                } else {
                    XCTAssertNil(result.dailyUsageBuckets)
                }
                _ = try await server.quota()
            }
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testActivityCannotLaunchOrReconnectAChild() async throws {
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/no/runtime"))
        do {
            _ = try await client.readAccountUsageTransport()
            XCTFail("Activity requires an existing healthy quota connection")
        } catch { XCTAssertEqual(error as? CodexAppServerError, .noResponse) }
        let diagnostic = await client.runtimeDiagnostic()
        XCTAssertEqual(diagnostic.appServerState, .notStarted)
        await client.shutdown()
    }

    func testMixedStressCoalescesAndSelectsWaitingQuotaBeforeActivity() async throws {
        let server = try ScriptedCodexServer()
        do {
            let first = try await server.quota()
            for _ in 0..<5 {
                let active = Task { try await server.client.readAccountUsageTransport() }
                let activityEvent = try await server.nextRequest()
                let joined = (0..<24).map { _ in Task { try await server.client.readAccountUsageTransport() } }
                try await waitForQueue(server.client, active: 25, quota: 0, activity: 0)
                let quotas = (0..<32).map { _ in Task { try await server.client.readRateLimits() } }
                try await waitForQueue(server.client, active: 25, quota: 32, activity: 0)
                let queued = (0..<32).map { _ in Task { try await server.client.readAccountUsageTransport() } }
                try await waitForQueue(server.client, active: 25, quota: 32, activity: 32)
                // Remove queued interests before releasing the active wire request.
                for request in queued.prefix(16) { request.cancel() }
                for request in queued.prefix(16) { await assertCancelled(request) }
                try await waitForQueue(server.client, active: 25, quota: 32, activity: 16)
                try server.reply(fixture: "valid-usage")
                _ = try await active.value
                for request in joined { _ = try await request.value }
                let quotaEvent = try await server.nextRequest()
                XCTAssertEqual(quotaEvent.method, "account/rateLimits/read")
                try server.reply()
                for request in quotas { _ = try await request.value }
                let queuedActivityEvent = try await server.nextRequest()
                XCTAssertEqual(queuedActivityEvent.method, "account/usage/read")
                try server.reply(fixture: "valid-usage")
                for request in queued.dropFirst(16) { _ = try await request.value }
                try await waitForQueue(server.client, active: 0, quota: 0, activity: 0)
                for event in [activityEvent, quotaEvent, queuedActivityEvent] {
                    XCTAssertEqual(event.pid, first.pid)
                    XCTAssertEqual(event.initialized, 1)
                    XCTAssertFalse(event.overlap, "Maximum active RPC must remain one")
                }
            }
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testManyQuotaCallersShareOneWireRequest() async throws {
        let server = try ScriptedCodexServer()
        do {
            let requests = (0..<96).map { _ in Task { try await server.client.readRateLimits() } }
            try await waitForQueue(server.client, active: 96, quota: 0, activity: 0)
            let first = try await server.nextRequest()
            try server.reply()
            for request in requests {
                let result = try await request.value
                XCTAssertEqual(result.rateLimits?.primary?.usedPercent, 25)
            }
            let next = try await server.quota()
            XCTAssertEqual(next.id, first.id + 1)
            XCTAssertEqual(next.pid, first.pid)
            XCTAssertFalse(next.overlap)
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testCapacityIsBoundedAndQuotaOverflowIsExplicit() async throws {
        let server = try ScriptedCodexServer()
        do {
            let active = Task { try await server.client.readRateLimits() }
            _ = try await server.nextRequest()
            let queued = (1..<CodexAppServerClient.maximumRequestWaiters).map { _ in
                Task { try await server.client.readAccountUsageTransport() }
            }
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 127)
            do {
                _ = try await server.client.readRateLimits()
                XCTFail("Excess quota interest must fail explicitly, never silently drop")
            } catch { XCTAssertEqual(error as? CodexAppServerError, .requestCapacityExceeded) }
            do {
                _ = try await server.client.readAccountUsageTransport()
                XCTFail("Excess activity interest must be bounded too")
            } catch { XCTAssertEqual(error as? CodexAppServerError, .requestCapacityExceeded) }
            for request in queued { request.cancel() }
            for request in queued { await assertCancelled(request) }
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 0)
            try server.reply()
            _ = try await active.value
            _ = try await server.quota()
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testCancellingQueuedActivityDoesNotCancelActiveQuota() async throws {
        let server = try ScriptedCodexServer()
        do {
            let quota = Task { try await server.client.readRateLimits() }
            let event = try await server.nextRequest()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 1)
            usage.cancel()
            await assertCancelled(usage)
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 0)
            XCTAssertFalse(isReaped(event.pid))
            try server.reply()
            _ = try await quota.value
            let next = try await server.quota()
            XCTAssertEqual(event.pid, next.pid)
            XCTAssertEqual(next.id, event.id + 1, "Cancelled queued activity writes no RPC")
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testCancellingQueuedQuotaDoesNotCancelActiveActivity() async throws {
        let server = try ScriptedCodexServer()
        do {
            _ = try await server.quota()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            let event = try await server.nextRequest()
            let quota = Task { try await server.client.readRateLimits() }
            try await waitForQueue(server.client, active: 1, quota: 1, activity: 0)
            quota.cancel()
            await assertCancelled(quota)
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 0)
            try server.reply(fixture: "valid-usage")
            _ = try await usage.value
            let next = try await server.quota()
            XCTAssertEqual(next.pid, event.pid)
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testCancellingOneCoalescedCallerPreservesOtherInterest() async throws {
        for activity in [false, true] {
            let server = try ScriptedCodexServer()
            do {
                _ = try await server.quota()
                let first = Task { try await readTransport(server.client, activity: activity) }
                let event = try await server.nextRequest()
                let second = Task { try await readTransport(server.client, activity: activity) }
                try await waitForQueue(server.client, active: 2, quota: 0, activity: 0)
                first.cancel()
                await assertCancelled(first)
                try await waitForQueue(server.client, active: 1, quota: 0, activity: 0)
                if activity { try server.reply(fixture: "valid-usage") } else { try server.reply() }
                try await second.value
                let next = try await server.quota()
                XCTAssertEqual(event.pid, next.pid)
                await server.close()
            } catch { await server.close(); throw error }
        }
    }

    func testActiveCancellationReapsBeforeWaitingQuotaReplacement() async throws {
        for activity in [true, false] {
            let server = try ScriptedCodexServer()
            do {
                _ = try await server.quota()
                let active = Task { try await readTransport(server.client, activity: activity) }
                let old = try await server.nextRequest()
                let waitingQuota: Task<CodexRateLimitsResult, Error>?
                let queuedActivity: Task<CodexAccountUsageTransportResult, Error>?
                if activity {
                    waitingQuota = Task { try await server.client.readRateLimits() }
                    try await waitForQueue(server.client, active: 1, quota: 1, activity: 0)
                    queuedActivity = Task { try await server.client.readAccountUsageTransport() }
                    try await waitForQueue(server.client, active: 1, quota: 1, activity: 1)
                } else {
                    waitingQuota = nil
                    queuedActivity = nil
                }
                active.cancel()
                await assertCancelled(active)
                // This demand arrives before cleanup necessarily completes.
                let quota = waitingQuota ?? Task { try await server.client.readRateLimits() }
                let replacement = try await server.nextRequest()
                XCTAssertEqual(replacement.method, "account/rateLimits/read")
                XCTAssertNotEqual(replacement.pid, old.pid)
                XCTAssertTrue(isReaped(old.pid), "Replacement must wait for old process/reader cleanup")
                XCTAssertFalse(replacement.overlap)
                // Late old ID and wrong-method payload must not reach the replacement quota.
                try server.sendLines([
                    "{\"id\":\(old.id),\"result\":{\"dailyUsageBuckets\":\"stale\"}}",
                    "{\"id\":\(replacement.id),\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":25}}}}"
                ])
                _ = try await quota.value
                if let queuedActivity {
                    _ = try await server.nextRequest()
                    try server.reply(fixture: "valid-usage")
                    _ = try await queuedActivity.value
                }
                await server.close()
            } catch { await server.close(); throw error }
        }
    }

    func testUsageServerAndPayloadFailuresPreserveChildAndQuotaDiagnostics() async throws {
        let server = try ScriptedCodexServer()
        do {
            let first = try await server.quota()
            let diagnostic = await server.client.runtimeDiagnostic()
            for _ in 0..<3 {
                for action in ["error", "malformed"] {
                    let usage = Task { try await server.client.readAccountUsageTransport() }
                    _ = try await server.nextRequest()
                    if action == "error" { try server.send(action: "error") }
                    else { try server.reply(fixture: "malformed-usage") }
                    do {
                        _ = try await usage.value
                        XCTFail("Synthetic usage failure must be rejected")
                    } catch {
                        XCTAssertEqual(error as? CodexAppServerError,
                                       action == "error" ? .serverError(code: -32601) : .invalidResponse)
                        XCTAssertFalse(String(reflecting: error).contains("synthetic-private-sentinel"))
                    }
                    let afterFailure = await server.client.runtimeDiagnostic()
                    XCTAssertEqual(afterFailure, diagnostic, "Activity must not overwrite quota health")
                    let quota = try await server.quota()
                    XCTAssertEqual(quota.pid, first.pid)
                    XCTAssertFalse(quota.overlap)
                }
            }
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testUsageTimeoutIsIndependentAndWaitingQuotaRecovers() async throws {
        // Large quota timeout, short injected activity timeout; no response to active usage.
        let server = try ScriptedCodexServer(activityTimeout: .milliseconds(150))
        do {
            _ = try await server.quota()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            let old = try await server.nextRequest()
            let quota = Task { try await server.client.readRateLimits() }
            try await waitForQueue(server.client, active: 1, quota: 1, activity: 0)
            do { _ = try await usage.value; XCTFail("Expected activity timeout") }
            catch { XCTAssertEqual(error as? CodexAppServerError, .timeout) }
            let replacement = try await server.nextRequest()
            XCTAssertTrue(isReaped(old.pid))
            XCTAssertNotEqual(replacement.pid, old.pid)
            XCTAssertEqual(replacement.method, "account/rateLimits/read")
            // Prove activity cannot reopen a disconnected connection on its own in a separate case.
            try server.reply()
            _ = try await quota.value
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testUsageFramingOversizeAndEOFRecoverWithoutAutomaticActivityReconnect() async throws {
        let server = try ScriptedCodexServer()
        do {
            for (action, expected) in [("framing", CodexAppServerError.invalidResponse),
                                       ("oversized", .responseTooLarge), ("eof", .noResponse)] {
                _ = try await server.quota()
                let usage = Task { try await server.client.readAccountUsageTransport() }
                let old = try await server.nextRequest()
                try server.send(action: action)
                do { _ = try await usage.value; XCTFail("Expected stream failure") }
                catch { XCTAssertEqual(error as? CodexAppServerError, expected) }
                XCTAssertTrue(isReaped(old.pid))
                do { _ = try await server.client.readAccountUsageTransport(); XCTFail("No activity restart") }
                catch { XCTAssertEqual(error as? CodexAppServerError, .noResponse) }
                let quota = try await server.quota()
                XCTAssertNotEqual(quota.pid, old.pid)
                XCTAssertEqual(quota.initialized, 1)
            }
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testCorrelationDiscardsWrongIDsNotificationsAndMalformedUnrelatedPayloads() async throws {
        let server = try ScriptedCodexServer()
        do {
            let prior = try await server.quota()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            let event = try await server.nextRequest()
            try server.sendLines([
                "{\"id\":1,\"result\":{}}",
                "{\"id\":\(prior.id),\"result\":{\"dailyUsageBuckets\":\"stale\"}}",
                "{\"id\":9999,\"result\":{\"rateLimits\":\"wrong-id-malformed-payload\"}}",
                "{\"method\":\"future/event\",\"params\":{\"private\":\"synthetic-private-sentinel\"}}",
                "{\"id\":\(event.id),\"result\":\(try server.fixtureString("valid-usage"))}",
                // Duplicate expected ID must not evict the original valid response.
                "{\"id\":\(event.id),\"result\":{\"dailyUsageBuckets\":\"duplicate\"}}"
            ])
            let result = try await usage.value
            XCTAssertEqual(result.dailyUsageBuckets?.first?.tokens, 2100)
            let next = try await server.quota()
            XCTAssertEqual(event.pid, next.pid)
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testQuotaServerFailureKeepsExistingDisconnectPolicy() async throws {
        let server = try ScriptedCodexServer()
        do {
            let request = Task { try await server.client.readRateLimits() }
            let old = try await server.nextRequest()
            try server.send(action: "error")
            do { _ = try await request.value; XCTFail("Expected quota failure") }
            catch { XCTAssertEqual(error as? CodexAppServerError, .serverError(code: -32601)) }
            XCTAssertTrue(isReaped(old.pid))
            let next = try await server.quota()
            XCTAssertNotEqual(next.pid, old.pid)
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testShutdownDrainsQueuedAndActiveRequestsAndReaps() async throws {
        let server = try ScriptedCodexServer()
        do {
            let quota = Task { try await server.client.readRateLimits() }
            let event = try await server.nextRequest()
            let usage = Task { try await server.client.readAccountUsageTransport() }
            try await waitForQueue(server.client, active: 1, quota: 0, activity: 1)
            await server.close()
            await assertCancelled(quota)
            await assertCancelled(usage)
            XCTAssertTrue(isReaped(event.pid))
            try await waitForQueue(server.client, active: 0, quota: 0, activity: 0)
        } catch { await server.close(); throw error }
    }
}

private func readTransport(_ client: CodexAppServerClient, activity: Bool) async throws {
    if activity { _ = try await client.readAccountUsageTransport() }
    else { _ = try await client.readRateLimits() }
}

private func assertCancelled<Value: Sendable>(_ task: Task<Value, Error>,
                                             file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await task.value; XCTFail("Expected CancellationError", file: file, line: line) }
    catch is CancellationError {}
    catch { XCTFail("Expected cancellation, received sanitized type \(type(of: error))", file: file, line: line) }
}

private enum FixtureError: Error { case deadline, pipe, noRequest }

private func waitForQueue(_ client: CodexAppServerClient, active: Int, quota: Int, activity: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        let counts = await client.requestQueueCounts()
        if counts == (active, quota, activity) { return }
        await Task.yield()
    }
    throw FixtureError.deadline
}

private func isReaped(_ pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == -1 && errno == ESRCH
}

private final class ScriptedCodexServer: @unchecked Sendable {
    struct Request: Decodable, Sendable {
        let method: String
        let id: Int
        let pid: pid_t
        let overlap: Bool
        let initialized: Int
    }

    let client: CodexAppServerClient
    private let directory: URL
    private let control: FileHandle
    private let requests: AsyncThrowingStream<Request, Error>
    private let reader: FixtureEventReader
    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/CodexTransport")
    }

    init(activityTimeout: Duration = .seconds(2)) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "CodexM0-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controlURL = directory.appending(path: "control")
        let eventsURL = directory.appending(path: "events")
        guard mkfifo(controlURL.path, 0o600) == 0, mkfifo(eventsURL.path, 0o600) == 0 else {
            throw FixtureError.pipe
        }
        control = FileHandle(fileDescriptor: open(controlURL.path, O_RDWR), closeOnDealloc: true)
        let channel = AsyncThrowingStream<Request, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        requests = channel.stream
        reader = FixtureEventReader(
            descriptor: open(eventsURL.path, O_RDWR | O_NONBLOCK), continuation: channel.continuation
        )
        client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", Self.fixtures.appending(path: "server.py").path, controlURL.path, eventsURL.path],
            timeout: .seconds(5), activityTimeout: activityTimeout, maximumResponseBytes: 4096
        )
    }

    func nextRequest() async throws -> Request {
        try await withThrowingTaskGroup(of: Request.self) { group in
            defer { group.cancelAll() }
            group.addTask { [requests] in
                for try await request in requests { return request }
                throw FixtureError.noRequest
            }
            group.addTask { try await Task.sleep(for: .seconds(6)); throw FixtureError.deadline }
            return try await group.next()!
        }
    }

    func fixtureString(_ name: String) throws -> String {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "\(name).json"))
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func reply(fixture: String? = nil) throws {
        var object: [String: Any] = ["action": "reply"]
        if let fixture { object["result"] = try JSONSerialization.jsonObject(with: Data(fixtureString(fixture).utf8)) }
        try send(object)
    }

    func send(action: String) throws { try send(["action": action]) }
    func sendLines(_ lines: [String]) throws { try send(["action": "lines", "lines": lines]) }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try control.write(contentsOf: data)
    }

    @discardableResult
    func quota() async throws -> Request {
        let request = Task { try await client.readRateLimits() }
        let event = try await nextRequest()
        XCTAssertEqual(event.method, "account/rateLimits/read")
        XCTAssertFalse(event.overlap)
        try reply()
        _ = try await request.value
        return event
    }

    func close() async {
        await client.shutdown()
        try? control.close()
        await reader.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

// The dispatch source serial queue exclusively owns the framing buffer. Cancellation
// closes the FIFO in its cancel handler, so tests never block on FileHandle.bytes EOF.
private final class FixtureEventReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let continuation: AsyncThrowingStream<ScriptedCodexServer.Request, Error>.Continuation
    private let stopped: AsyncStream<Void>
    private var line = Data()

    init(descriptor: Int32,
         continuation: AsyncThrowingStream<ScriptedCodexServer.Request, Error>.Continuation) {
        self.descriptor = descriptor
        self.continuation = continuation
        let completion = AsyncStream<Void>.makeStream()
        stopped = completion.stream
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                              queue: DispatchQueue(label: "CodexM0.fixture.events"))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler {
            Darwin.close(descriptor)
            continuation.finish()
            completion.continuation.finish()
        }
        source.resume()
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return }
        do {
            for byte in bytes.prefix(count) {
                if byte == 0x0A {
                    continuation.yield(try JSONDecoder().decode(ScriptedCodexServer.Request.self, from: line))
                    line.removeAll()
                } else {
                    guard line.count < 4096 else { throw FixtureError.pipe }
                    line.append(byte)
                }
            }
        } catch { continuation.finish(throwing: error) }
    }

    func stop() async {
        source.cancel()
        for await _ in stopped {}
    }
}
