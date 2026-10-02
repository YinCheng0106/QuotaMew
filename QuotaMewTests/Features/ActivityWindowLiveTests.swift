import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityWindowLiveTests: XCTestCase {
    func testLiveProductionWindowWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["QUOTAMEW_RUN_LIVE_ACTIVITY_WINDOW_TEST"] == "1" else {
            throw XCTSkip("Opt-in live activity window check disabled")
        }
        let name = "M4Live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let client = CodexAppServerClient(locator: CodexExecutableLocator())
        let runtime = AppDependencies.makeRuntime(settingsStore: settings, codexClient: client)
        let model = runtime.activityModel
        let controller = ActivityWindowController(model: model, openSettings: {}, activate: {})
        defer { controller.teardown() }
        let provider = CodexProvider(reader: client, runtimeDiagnosticReader: client)
        do {
            controller.show()
            await controller.waitForOpenRefresh()
            XCTAssertTrue(model.state == .disabled)
            XCTAssertFalse(ActivityStatePresentation(state: model.state, locale: Locale(identifier: "en")).canRefresh)
            var diagnostic = await client.runtimeDiagnostic()
            XCTAssertEqual(diagnostic.appServerState, .notStarted)
            await model.setEnabled(true)
            XCTAssertTrue(model.state == .idle)
            diagnostic = await client.runtimeDiagnostic()
            XCTAssertEqual(diagnostic.appServerState, .notStarted)
            _ = try await provider.fetchUsage() // Normal quota establishes the production shared child.
            let before = RuntimeDiagnostics.shared.snapshot()
            let persistence = defaults.persistentDomain(forName: name)! as NSDictionary
            controller.show() // Explicit open of enabled/idle performs the first demand.
            await controller.waitForOpenRefresh()
            let snapshot = await runtime.activityStore.snapshot(for: .codex)
            var bucketCount = 0, seven = 0, thirty = 0
            switch model.state {
            case .available(let projection):
                guard let snapshot else {
                    XCTFail("Available window requires memory snapshot; values suppressed")
                    await runtime.activityService.shutdown(); await client.shutdown(); return
                }
                bucketCount = snapshot.buckets.count
                XCTAssertTrue(projection.latestReported == snapshot.buckets.last)
                seven = projection.sevenDays.coverage.reportedDays
                thirty = projection.thirtyDays.coverage.reportedDays
                let window = try XCTUnwrap(controller.window)
                let host = try XCTUnwrap(window.contentViewController as? NSHostingController<ActivityWindowView>)
                for period in ActivityPeriod.allCases {
                    let presentation = ActivityPresentation(projection: projection, period: period, locale: Locale(identifier: "en"))
                    let days = period == .sevenDays ? 7 : period == .thirtyDays ? 30 : 0
                    XCTAssertEqual(presentation.points.count, days)
                    host.rootView = ActivityWindowView(model: model, openSettings: {}, initialPeriod: period)
                    host.view.layoutSubtreeIfNeeded()
                    if days > 0 {
                        let windowProjection = period == .sevenDays ? projection.sevenDays : projection.thirtyDays
                        XCTAssertEqual(windowProjection.points.count, windowProjection.coverage.expectedDays)
                        XCTAssertEqual(windowProjection.coverage.reportedDays + windowProjection.coverage.missingDays, days)
                        XCTAssertEqual(presentation.points.filter { $0.reportedTokens != nil }.count,
                                       windowProjection.coverage.reportedDays)
                    }
                }
            case .noReportedBuckets(_, _, let reason):
                XCTAssertTrue(reason == .emptyCollection)
                XCTAssertTrue(snapshot == nil || snapshot?.buckets.isEmpty == true)
            default:
                XCTFail("Live window requires available or valid empty report; details suppressed")
                await runtime.activityService.shutdown(); await client.shutdown(); return
            }
            let after = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(before.codexProcessIDs == after.codexProcessIDs)
            XCTAssertEqual(after.codexProcessIDs.count, 1)
            XCTAssertEqual(after.codexStdoutReaderCount, 1)
            XCTAssertTrue(persistence == defaults.persistentDomain(forName: name)! as NSDictionary)
            controller.window?.close()
            XCTAssertNil(controller.window)
            let available = model.state
            controller.show()
            await controller.waitForOpenRefresh()
            XCTAssertTrue(model.state == available, "Reopen preserves memory projection; values suppressed")
            try await controller.model.refresh()
            switch model.state {
            case .available, .noReportedBuckets: break
            default: XCTFail("Manual refresh must succeed; details suppressed")
            }
            await model.setEnabled(false)
            XCTAssertTrue(model.state == .disabled)
            let cleared = await runtime.activityStore.snapshot(for: .codex)
            XCTAssertTrue(cleared == nil)
            let queueBefore = await client.requestQueueCounts()
            try await controller.model.refresh()
            controller.show()
            await controller.waitForOpenRefresh()
            let queueAfter = await client.requestQueueCounts()
            XCTAssertTrue(queueBefore == queueAfter)
            let quota = try await provider.fetchUsage()
            XCTAssertFalse(quota.windows.isEmpty)
            controller.teardown()
            await runtime.activityService.shutdown()
            await client.shutdown()
            let closed = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(closed.codexProcessIDs.isEmpty)
            XCTAssertEqual(closed.codexStdoutReaderCount, 0)
            for pid in after.codexProcessIDs {
                errno = 0
                XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
            }
            print("Live M4 Activity window: buckets=\(bucketCount), 7D=\(seven)/7, 30D=\(thirty)/30, disabledNoIO=true, enableNoIO=true, manualRefresh=PASS, disabledCleared=true, quotaAfter=PASS, childReaped=true, readers=0")
        } catch {
            controller.teardown()
            await runtime.activityService.shutdown()
            await client.shutdown()
            XCTFail("Live M4 activity window/quota probe failed; provider details suppressed")
        }
    }
}
