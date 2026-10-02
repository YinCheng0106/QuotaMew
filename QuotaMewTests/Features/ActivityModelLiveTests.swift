import Darwin
import Foundation
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityModelLiveTests: XCTestCase {
    func testLiveProductionActivityModelWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["QUOTAMEW_RUN_LIVE_ACTIVITY_MODEL_TEST"] == "1" else {
            throw XCTSkip("Opt-in live activity model check disabled")
        }
        let name = "M3Live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let client = CodexAppServerClient(locator: CodexExecutableLocator())
        let runtime = AppDependencies.makeRuntime(settingsStore: settings, codexClient: client)
        let model = runtime.activityModel
        let provider = CodexProvider(reader: client, runtimeDiagnosticReader: client)
        do {
            XCTAssertTrue(model.state == .disabled)
            await model.setEnabled(true)
            XCTAssertTrue(model.state == .idle)
            let idle = await client.runtimeDiagnostic()
            XCTAssertEqual(idle.appServerState, .notStarted)
            _ = try await provider.fetchUsage() // Existing quota demand establishes healthy shared transport.
            let before = RuntimeDiagnostics.shared.snapshot()
            let persistenceBefore = defaults.persistentDomain(forName: name)! as NSDictionary
            try await model.refresh()
            let stored = await runtime.activityStore.snapshot(for: .codex)
            var bucketCount = 0, sevenReported = 0, thirtyReported = 0
            switch model.state {
            case .available(let projection):
                guard let stored else {
                    XCTFail("Available model requires current snapshot; values suppressed")
                    await runtime.activityService.shutdown(); await client.shutdown(); return
                }
                bucketCount = stored.buckets.count
                XCTAssertTrue(bucketCount > 0)
                XCTAssertTrue(projection.latestReported == stored.buckets.last)
                XCTAssertTrue(try ActivityProjection.query(stored) == projection, "Deterministic projection; values suppressed")
                for window in [projection.sevenDays, projection.thirtyDays] {
                    let coverage = window.coverage
                    XCTAssertEqual(coverage.reportedDays + coverage.missingDays, coverage.expectedDays)
                    XCTAssertEqual(window.points.count, coverage.expectedDays)
                    XCTAssertEqual(window.startSourceDate.distance(to: window.endSourceDate), coverage.expectedDays - 1)
                    XCTAssertEqual(coverage.isComplete, coverage.missingDays == 0)
                    XCTAssertEqual(window.points.filter { if case .reported = $0 { return true }; return false }.count,
                                   coverage.reportedDays)
                }
                sevenReported = projection.sevenDays.coverage.reportedDays
                thirtyReported = projection.thirtyDays.coverage.reportedDays
            case .noReportedBuckets(_, _, let reason):
                // Missing/null source collections are unavailable daily data, not valid empty reports.
                XCTAssertTrue(reason == .emptyCollection)
                XCTAssertTrue(stored == nil || stored?.buckets.isEmpty == true)
            default:
                XCTFail("Live model requires available or valid empty report; provider details suppressed")
                await runtime.activityService.shutdown(); await client.shutdown(); return
            }
            XCTAssertTrue(persistenceBefore == defaults.persistentDomain(forName: name)! as NSDictionary)
            let after = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(before.codexProcessIDs == after.codexProcessIDs)
            XCTAssertEqual(after.codexProcessIDs.count, 1)
            XCTAssertEqual(after.codexStdoutReaderCount, 1)
            let queueBefore = await client.requestQueueCounts()
            await model.setEnabled(false)
            XCTAssertTrue(model.state == .disabled)
            let cleared = await runtime.activityStore.snapshot(for: .codex)
            XCTAssertTrue(cleared == nil)
            let queueAfter = await client.requestQueueCounts()
            XCTAssertTrue(queueBefore == queueAfter)
            let quota = try await provider.fetchUsage()
            XCTAssertFalse(quota.windows.isEmpty)
            await runtime.activityService.shutdown()
            await client.shutdown()
            let closed = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(closed.codexProcessIDs.isEmpty)
            XCTAssertEqual(closed.codexStdoutReaderCount, 0)
            for pid in after.codexProcessIDs {
                errno = 0
                XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
            }
            print("Live M3 ActivityModel: buckets=\(bucketCount), 7D=\(sevenReported)/7, 30D=\(thirtyReported)/30, enableNoIO=true, disabledCleared=true, quotaAfter=PASS, childReaped=true, readers=0")
        } catch {
            await runtime.activityService.shutdown()
            await client.shutdown()
            XCTFail("Live M3 model/quota probe failed; provider details suppressed")
        }
    }
}
