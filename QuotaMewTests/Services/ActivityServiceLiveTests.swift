import Darwin
import Foundation
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityServiceLiveTests: XCTestCase {
    func testLiveProductionActivityServiceWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["QUOTAMEW_RUN_LIVE_ACTIVITY_SERVICE_TEST"] == "1" else {
            throw XCTSkip("Opt-in live activity service check disabled")
        }
        let name = "M2Live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let client = CodexAppServerClient(locator: CodexExecutableLocator())
        let runtime = AppDependencies.makeRuntime(settingsStore: settings, codexClient: client)
        let provider = CodexProvider(reader: client, runtimeDiagnosticReader: client)
        do {
            let idle = await client.runtimeDiagnostic()
            XCTAssertEqual(idle.appServerState, .notStarted)
            await runtime.activityService.setCodexAccountActivityEnabled(true)
            let enabledIdle = await client.runtimeDiagnostic()
            XCTAssertEqual(enabledIdle.appServerState, .notStarted)
            _ = try await provider.fetchUsage() // Normal quota establishes the only child.
            let before = RuntimeDiagnostics.shared.snapshot()
            let result = try await runtime.activityService.refresh(provider: .codex)
            guard case .snapshot(let snapshot) = result else {
                XCTFail("Live service did not return validated activity")
                await runtime.activityService.shutdown(); await client.shutdown(); return
            }
            XCTAssertTrue(snapshot.providerID == .codex)
            XCTAssertTrue(snapshot.buckets.map(\.sourceDate) == snapshot.buckets.map(\.sourceDate).sorted())
            let stored = await runtime.activityStore.snapshot(for: .codex)
            XCTAssertTrue(stored == snapshot, "Stored and returned snapshot must match; values suppressed")
            let quotaAfter = try await provider.fetchUsage()
            XCTAssertFalse(quotaAfter.windows.isEmpty)
            let after = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(before.codexProcessIDs == after.codexProcessIDs)
            XCTAssertEqual(after.codexProcessIDs.count, 1)
            XCTAssertEqual(after.codexStdoutReaderCount, 1)
            XCTAssertEqual(before.codexReconnectCount, after.codexReconnectCount)
            let queueBefore = await client.requestQueueCounts()
            await runtime.activityService.setCodexAccountActivityEnabled(false)
            let disabled = try await runtime.activityService.refresh(provider: .codex)
            XCTAssertTrue(disabled == .disabled)
            let cleared = await runtime.activityStore.snapshot(for: .codex)
            XCTAssertTrue(cleared == nil)
            let queueAfter = await client.requestQueueCounts()
            XCTAssertTrue(queueBefore == queueAfter)
            let persisted = defaults.persistentDomain(forName: name)!
            XCTAssertTrue(persisted.keys.filter { $0.hasPrefix("activity.") } == ["activity.codex.account.enabled"])
            XCTAssertTrue(persisted["activity.codex.account.enabled"] as? Bool == false)
            await runtime.activityService.shutdown()
            _ = try await provider.fetchUsage() // Service shutdown preserves shared quota transport.
            await client.shutdown()
            let closed = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(closed.codexProcessIDs.isEmpty)
            XCTAssertEqual(closed.codexStdoutReaderCount, 0)
            for pid in after.codexProcessIDs {
                errno = 0
                XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
            }
            print("Live M2 Activity Service: available=true, bucketCount=\(snapshot.buckets.count), storedMatches=true, sharedChild=1, reader=1, quotaAfter=true, disabledCleared=true, cleanup=true")
        } catch {
            await runtime.activityService.shutdown()
            await client.shutdown()
            XCTFail("Live M2 service/quota probe failed; provider details suppressed")
        }
    }
}
