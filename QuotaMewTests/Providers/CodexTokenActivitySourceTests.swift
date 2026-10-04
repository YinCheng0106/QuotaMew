import Darwin
import Foundation
import XCTest
@testable import QuotaMew

final class CodexTokenActivitySourceTests: XCTestCase {
    private let capture = Date(timeIntervalSince1970: 123)
    private let sentinels = ["private@example.com", "acct-secret", "thread-secret", "session-secret",
        "/private/repo", "repo-secret", "model-secret", "reasoning-secret", "SECRET_PROMPT",
        "response-secret", "tool-secret", "SECRET_RAW_JSON"]

    func testValidMultiDayExplicitZeroGapShuffledAndFutureFields() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/CodexActivity/privacy.json")
        let json = String(decoding: try Data(contentsOf: fixture), as: UTF8.self)
        let result = try await fetch(json)
        guard case .snapshot(let snapshot) = result else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.source, .codexAccountUsage)
        XCTAssertEqual(snapshot.capturedAt, capture)
        XCTAssertEqual(snapshot.buckets.map(\.sourceDate.rawValue), ["2026-10-01", "2026-10-03"])
        XCTAssertEqual(snapshot.buckets.map(\.reportedTokens), [0, 42])
        assertPrivateDataAbsent(result)
        assertPrivateDataAbsent(snapshot.buckets)
        assertPrivateDataAbsent(ActivityInsights.query(snapshot, period: .sevenDays))
        assertPrivateDataAbsent(ActivityInsights.query(snapshot, period: .thirtyDays))
        assertPrivateDataAbsent(try JSONDecoder().decode(CodexAccountUsageTransportResult.self, from: Data(json.utf8)))
        XCTAssertEqual(snapshot.source.scope, .accountAggregate)
        XCTAssertEqual(snapshot.source.basis, .providerReportedTotal)
        XCTAssertEqual(snapshot.source.confidence, .providerReported)
    }

    func testMissingCollectionIsUnavailable() async throws {
        let result = try await fetch("{}")
        XCTAssertEqual(result,
            .noDailyBuckets(source: .codexAccountUsage, capturedAt: capture, reason: .missingCollection))
    }

    func testNullCollectionIsUnavailable() async throws {
        let result = try await fetch("{\"dailyUsageBuckets\":null}")
        XCTAssertEqual(result,
            .noDailyBuckets(source: .codexAccountUsage, capturedAt: capture, reason: .nullCollection))
    }

    func testEmptyCollectionIsValidNoReportedBuckets() async throws {
        let result = try await fetch("{\"dailyUsageBuckets\":[]}")
        XCTAssertEqual(result,
            .noDailyBuckets(source: .codexAccountUsage, capturedAt: capture, reason: .emptyCollection))
    }

    func testMalformedDatesRejectWholeCandidate() async {
        for date in ["2026-02-29", "2026-13-01", "2026-1-01", "../../etc", "2026-10-01Z"] {
            await assertInvalid("{\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\",\"tokens\":1}," +
                "{\"startDate\":\"\(date)\",\"tokens\":1}]}")
        }
    }

    func testNegativeOverflowFractionStringBoolNullAndMissingTokensReject() async {
        for token in ["-1", "9223372036854775808", "1.5", "\"1\"", "true", "null", "1e100"] {
            await assertInvalid("{\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\",\"tokens\":\(token)}]}")
        }
        await assertInvalid("{\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\"}]}")
    }

    func testMalformedRequiredFieldsAndCollectionReject() async {
        for json in ["{\"dailyUsageBuckets\":{}}", "{\"dailyUsageBuckets\":false}",
                     "{\"dailyUsageBuckets\":[null]}", "{\"dailyUsageBuckets\":[{\"tokens\":1}]}",
                     "{\"dailyUsageBuckets\":[{\"startDate\":null,\"tokens\":1}]}",
                     "{\"dailyUsageBuckets\":[{\"startDate\":42,\"tokens\":1}]}"] {
            await assertInvalid(json)
        }
    }

    func testInt64MaximumRemainsExact() async throws {
        guard case .snapshot(let snapshot) = try await fetch(
            "{\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\",\"tokens\":9223372036854775807}]}")
        else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.buckets.first?.reportedTokens, Int64.max)
    }

    func testSameDateSameValueDeduplicatesWithoutSumming() async throws {
        let row = "{\"startDate\":\"2026-10-01\",\"tokens\":7}"
        guard case .snapshot(let snapshot) = try await fetch("{\"dailyUsageBuckets\":[\(row),\(row)]}")
        else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets.first?.reportedTokens, 7)
    }

    func testConflictingDuplicateRejectsCandidate() async {
        await assertInvalid("{\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\",\"tokens\":0}," +
            "{\"startDate\":\"2026-10-01\",\"tokens\":1}]}")
    }

    func testBucketCapacityBeforeDeduplication() async throws {
        let row = "{\"startDate\":\"2026-10-01\",\"tokens\":0}"
        let bounded = Array(repeating: row, count: 366).joined(separator: ",")
        guard case .snapshot(let snapshot) = try await fetch("{\"dailyUsageBuckets\":[\(bounded)]}")
        else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.buckets.count, 1)
        await assertInvalid("{\"dailyUsageBuckets\":[\(bounded),\(row)]}")
    }

    func testMethodNotFoundIsIndependentUnsupportedCapability() async throws {
        let source = CodexTokenActivitySource(reader: FailingActivityReader(error: CodexAppServerError.serverError(code: -32601)))
        let result = try await source.fetchActivity()
        XCTAssertEqual(result, .unsupported)
    }

    func testTransportFailuresNormalizeWithoutRawErrors() async {
        let cases: [(CodexAppServerError, ActivityFetchError)] = [
            (.timeout, .timedOut), (.invalidResponse, .invalidData), (.noResponse, .fetchFailed),
            (.launchFailed, .fetchFailed), (.executableNotFound, .providerUnavailable),
            (.responseTooLarge, .limitExceeded), (.requestCapacityExceeded, .limitExceeded),
            (.serverError(code: -32000), .fetchFailed)]
        for (transport, expected) in cases {
            await assertFailure(reader: FailingActivityReader(error: transport), expected: expected)
        }
        let raw = NSError(domain: sentinels.joined(separator: " "), code: 1,
                          userInfo: [NSLocalizedDescriptionKey: sentinels.joined(separator: " ")])
        await assertFailure(reader: FailingActivityReader(error: raw), expected: .fetchFailed)
    }

    func testPrivateMalformedCoreNeverEscapesError() async {
        await assertInvalid("{\"dailyUsageBuckets\":[{\"startDate\":\"SECRET_PROMPT\",\"tokens\":0}]," +
                            "\"raw\":\"SECRET_RAW_JSON\"}")
    }

    func testCancellationRemainsCancellation() async {
        do {
            _ = try await CodexTokenActivitySource(reader: FailingActivityReader(error: CancellationError())).fetchActivity()
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation only") }
    }

    func testLiveCodexActivityAdapterWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["QUOTAMEW_RUN_LIVE_ACTIVITY_TEST"] == "1"
            || UserDefaults.standard.bool(forKey: "runLiveCodexActivityTest") else {
            throw XCTSkip("Opt-in live activity check disabled")
        }
        let locator = CodexExecutableLocator()
        _ = try XCTUnwrap(locator.locate(), "Installed runtime required")
        let client = CodexAppServerClient(locator: locator)
        let provider = CodexProvider(reader: client, runtimeDiagnosticReader: client)
        do {
            _ = try await provider.fetchUsage() // Establish the sole healthy quota connection.
            let before = RuntimeDiagnostics.shared.snapshot()
            let start = Date()
            let result = try await CodexTokenActivitySource(reader: client).fetchActivity()
            guard case .snapshot(let snapshot) = result else {
                XCTFail("Live activity did not return a snapshot under the approved contract")
                await client.shutdown()
                return
            }
            XCTAssertEqual(snapshot.providerID, .codex)
            XCTAssertEqual(snapshot.source, .codexAccountUsage)
            XCTAssertTrue(snapshot.capturedAt >= start && snapshot.capturedAt <= Date())
            XCTAssertLessThanOrEqual(snapshot.buckets.count, 366)
            XCTAssertEqual(snapshot.buckets.map(\.sourceDate), snapshot.buckets.map(\.sourceDate).sorted())
            XCTAssertEqual(Set(snapshot.buckets.map(\.sourceDate)).count, snapshot.buckets.count)
            for bucket in snapshot.buckets {
                XCTAssertTrue((try? ProviderCalendarDate(bucket.sourceDate.rawValue)) != nil)
                XCTAssertTrue(bucket.reportedTokens >= 0)
            }
            // Inspect field names only; never render a live snapshot or token value.
            XCTAssertEqual(Set(Mirror(reflecting: snapshot).children.compactMap(\.label)),
                           ["providerID", "buckets", "capturedAt", "source"])
            for bucket in snapshot.buckets {
                XCTAssertEqual(Set(Mirror(reflecting: bucket).children.compactMap(\.label)),
                               ["sourceDate", "reportedTokens"])
            }
            let quotaAfter = try await provider.fetchUsage()
            XCTAssertFalse(quotaAfter.windows.isEmpty)
            let after = RuntimeDiagnostics.shared.snapshot()
            XCTAssertEqual(before.codexProcessIDs, after.codexProcessIDs)
            XCTAssertEqual(after.codexProcessIDs.count, 1)
            XCTAssertEqual(after.codexStdoutReaderCount, 1)
            XCTAssertEqual(before.codexReconnectCount, after.codexReconnectCount)
            await client.shutdown()
            let closed = RuntimeDiagnostics.shared.snapshot()
            XCTAssertTrue(closed.codexProcessIDs.isEmpty)
            XCTAssertEqual(closed.codexStdoutReaderCount, 0)
            for pid in after.codexProcessIDs {
                errno = 0
                XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
            }
            print("Live Account Activity: supported=true, bucketCount=\(snapshot.buckets.count), validated=true, sharedQuotaAfter=true, cleanup=true")
        } catch {
            await client.shutdown()
            // Do not allow XCTest to render any provider error body.
            XCTFail("Live activity/quota probe failed; sanitized failure category only")
        }
    }

    private func fetch(_ json: String) async throws -> ActivityFetchResult {
        let date = capture
        return try await CodexTokenActivitySource(reader: JSONActivityReader(json: json), now: { date }).fetchActivity()
    }

    private func assertInvalid(_ json: String) async {
        await assertFailure(reader: JSONActivityReader(json: json), expected: .invalidData)
    }

    private func assertFailure(reader: any CodexAccountUsageReading, expected: ActivityFetchError) async {
        do {
            _ = try await CodexTokenActivitySource(reader: reader).fetchActivity()
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? ActivityFetchError, expected)
            assertPrivateDataAbsent(error)
            assertPrivateDataAbsent((error as NSError).localizedDescription)
        }
    }

    private func assertPrivateDataAbsent(_ value: Any) {
        let descriptions = [String(describing: value), String(reflecting: value)]
        for sentinel in sentinels {
            XCTAssertTrue(descriptions.allSatisfy { !$0.contains(sentinel) }, "Private sentinel escaped")
        }
    }
}

private struct JSONActivityReader: CodexAccountUsageReading {
    let json: String
    func readAccountUsageTransport() async throws -> CodexAccountUsageTransportResult {
        try JSONDecoder().decode(CodexAccountUsageTransportResult.self, from: Data(json.utf8))
    }
}

private struct FailingActivityReader: CodexAccountUsageReading {
    let error: any Error
    func readAccountUsageTransport() async throws -> CodexAccountUsageTransportResult { throw error }
}
