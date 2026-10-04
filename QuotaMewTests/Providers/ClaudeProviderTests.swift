import Foundation
import XCTest
@testable import QuotaMew

final class ClaudeProviderTests: XCTestCase {
    func testMapsDocumentedRateLimitWindows() async throws {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let document = ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: capturedAt,
            claudeCodeVersion: "2.1.80",
            rateLimits: ClaudeRateLimits(
                fiveHour: ClaudeRateLimitWindow(
                    usedPercentage: 23.5,
                    resetsAt: 2_000_003_600
                ),
                sevenDay: ClaudeRateLimitWindow(
                    usedPercentage: 41.2,
                    resetsAt: 2_000_604_800
                )
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document)),
            locale: Locale(identifier: "en")
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.providerID, .claude)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.source.kind, .claudeStatusLineSnapshot)
        XCTAssertEqual(snapshot.windows.map(\.id), [
            "claude.five-hour",
            "claude.seven-day"
        ])
        XCTAssertEqual(snapshot.windows[0].label, "5-hour window")
        XCTAssertEqual(snapshot.windows[0].usedPercentage, 23.5)
        XCTAssertEqual(snapshot.windows[0].duration, .seconds(18_000))
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_003_600))
        XCTAssertEqual(snapshot.windows[1].duration, .seconds(604_800))
    }

    func testDoesNotGuessAnIndependentlyMissingWindowOrResetTime() async throws {
        let document = ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            claudeCodeVersion: "2.1.246",
            rateLimits: ClaudeRateLimits(
                fiveHour: nil,
                sevenDay: ClaudeRateLimitWindow(
                    usedPercentage: 40,
                    resetsAt: nil
                )
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "claude.seven-day")
        XCTAssertEqual(snapshot.windows[0].usedPercentage, 40)
        XCTAssertEqual(snapshot.windows[0].displayUsedPercentage, 40)
        XCTAssertNil(snapshot.windows[0].resetAt)
    }

    func testParsesResetTimestampAsUnixSeconds() async throws {
        let resetTimestamp: TimeInterval = 2_000_003_600.5
        let document = makeDocument(
            fiveHour: ClaudeRateLimitWindow(
                usedPercentage: 10,
                resetsAt: resetTimestamp
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(
            snapshot.windows.first?.resetAt,
            Date(timeIntervalSince1970: resetTimestamp)
        )
    }

    func testPreservesResetOnlyWindowWithoutFabricatingUsage() async throws {
        let document = ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            claudeCodeVersion: "2.1.246",
            rateLimits: ClaudeRateLimits(
                fiveHour: ClaudeRateLimitWindow(
                    usedPercentage: nil,
                    resetsAt: 2_000_003_600
                ),
                sevenDay: nil
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].usedPercentage)
        XCTAssertEqual(
            snapshot.windows[0].resetAt,
            Date(timeIntervalSince1970: 2_000_003_600)
        )
    }

    func testRejectsSnapshotWithoutUsageOrResetData() async {
        let document = ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            claudeCodeVersion: "2.1.246",
            rateLimits: ClaudeRateLimits(
                fiveHour: ClaudeRateLimitWindow(
                    usedPercentage: nil,
                    resetsAt: nil
                ),
                sevenDay: nil
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document))
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected the provider to reject a snapshot without usage or reset data")
        } catch {
            XCTAssertEqual(error as? ClaudeProviderError, .noRateLimits)
        }
    }

    func testPreservesOldCaptureTimeWithoutClaimingTheSnapshotIsFresh() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_000_000_000)
        let document = ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: capturedAt,
            claudeCodeVersion: "2.1.246",
            rateLimits: ClaudeRateLimits(
                fiveHour: ClaudeRateLimitWindow(
                    usedPercentage: 10,
                    resetsAt: 1_000_001_000
                ),
                sevenDay: nil
            )
        )
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(result: .success(document))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.windows[0].usedPercentage, 10)
        XCTAssertEqual(snapshot.validity, .stale)
    }

    func testMissingSnapshotMapsToNotConfiguredState() async {
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(
                result: .failure(ClaudeSnapshotReaderError.snapshotNotFound)
            )
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(states.first?.status, .notConfigured)
        XCTAssertNil(states.first?.snapshot)
    }

    func testMalformedSnapshotMapsToSanitizedErrorState() async {
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(
                result: .failure(ClaudeSnapshotReaderError.invalidSnapshot)
            )
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(
            states.first?.status,
            .failed(.refreshFailed)
        )
        XCTAssertNil(states.first?.snapshot)
    }

    func testUnavailableUsageMapsToSanitizedErrorState() async {
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(
                result: .success(makeDocument(fiveHour: nil))
            )
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(
            states.first?.status,
            .failed(.usageUnavailable)
        )
        XCTAssertNil(states.first?.snapshot)
    }

    func testProviderFailureMapsToSanitizedErrorState() async {
        let provider = makeProvider(
            reader: StubClaudeUsageSnapshotReader(
                result: .failure(TestClaudeReaderError(message: "sensitive provider details"))
            )
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(
            states.first?.status,
            .failed(.refreshFailed)
        )
        XCTAssertNil(states.first?.snapshot)
    }

    func testKnownInstallationAndAuthenticationStatusesArePreserved() async {
        for status in [ProviderStatus.notInstalled, .unsupportedAuthentication] {
            let provider = makeProvider(
                reader: StubClaudeUsageSnapshotReader(
                    result: .failure(TestClaudeStatusError(providerStatus: status))
                )
            )
            let service = UsageService(providers: [provider])

            let states = await service.refresh()

            XCTAssertEqual(states.first?.status, status)
            XCTAssertNil(states.first?.snapshot)
        }
    }

    private func makeProvider(
        reader: any ClaudeUsageSnapshotReading, locale: Locale = .autoupdatingCurrent
    ) -> ClaudeProvider {
        ClaudeProvider(reader: reader, locale: locale, now: { Date(timeIntervalSince1970: 2_000_000_000) })
    }

    func testRejectsOutOfRangeInsteadOfClamping() async {
        for value in [-1.0, 140, .nan, .infinity] {
            let provider = makeProvider(reader: StubClaudeUsageSnapshotReader(result: .success(
                makeDocument(fiveHour: .init(usedPercentage: value, resetsAt: 2_000_003_600))
            )))
            do {
                _ = try await provider.fetchUsage()
                XCTFail("Invalid percentages cannot produce an available window")
            } catch {
                XCTAssertEqual(error as? ClaudeContractError, .invalidPercentage)
            }
        }
    }

    func testExpiredResetRemainsLastReportedSampleAndServiceIsStale() async {
        let provider = makeProvider(reader: StubClaudeUsageSnapshotReader(result: .success(
            makeDocument(fiveHour: .init(usedPercentage: 73, resetsAt: 1_999_999_999))
        )))
        let states = await UsageService(providers: [provider]).refresh()
        XCTAssertEqual(states.first?.status, .stale)
        XCTAssertEqual(states.first?.snapshot?.windows.first?.usedPercentage, 73)
        XCTAssertEqual(states.first?.snapshot?.windows.first?.resetAt, Date(timeIntervalSince1970: 1_999_999_999))
    }

    private func makeDocument(
        fiveHour: ClaudeRateLimitWindow?
    ) -> ClaudeUsageSnapshotDocument {
        ClaudeUsageSnapshotDocument(
            schemaVersion: 1,
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            claudeCodeVersion: "2.1.246",
            rateLimits: ClaudeRateLimits(
                fiveHour: fiveHour,
                sevenDay: nil
            )
        )
    }
}

private struct StubClaudeUsageSnapshotReader: ClaudeUsageSnapshotReading {
    let result: Result<ClaudeUsageSnapshotDocument, Error>

    func readSnapshot() async throws -> ClaudeUsageSnapshotDocument {
        try result.get()
    }
}

private struct TestClaudeReaderError: Error {
    let message: String
}

private struct TestClaudeStatusError: ProviderStatusProvidingError {
    let providerStatus: ProviderStatus
}
