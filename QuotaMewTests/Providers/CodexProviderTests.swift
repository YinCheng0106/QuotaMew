import Foundation
import XCTest
@testable import QuotaMew

final class CodexProviderTests: XCTestCase {
    func testObservedReserveBucketMappingKeepsProviderDataAndPresentsRegularQuotaFirst() async throws {
        // Sanitized metadata shape; all percentages/timestamps below are synthetic.
        let response = CodexRateLimitsResult(rateLimits: nil, rateLimitsByLimitId: [
            "base_model_inference": CodexRateLimitBucket(
                limitId: "base_model_inference", limitName: "gpt-reserve",
                primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMins: 10_080, resetsAt: 2_000_604_800),
                secondary: nil
            ),
            "codex": CodexRateLimitBucket(
                limitId: "codex", limitName: nil,
                primary: CodexRateLimitWindow(usedPercent: 39, windowDurationMins: 300, resetsAt: 2_000_018_000),
                secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: 2_000_604_800)
            ),
        ])
        let reader = CountingReserveReader(response: response)
        let provider = CodexProvider(reader: reader, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        let snapshot = try await provider.fetchUsage()
        let original = snapshot
        XCTAssertEqual(snapshot.windows.first?.id, "codex.base_model_inference.primary")
        XCTAssertTrue(snapshot.windows.first?.label.contains("gpt-reserve") == true)
        let state = ProviderState(providerID: .codex, status: .available, snapshot: snapshot)
        for _ in 0..<100 {
            let presentation = ProviderWindowsPresentation(state: state, now: snapshot.capturedAt)
            XCTAssertEqual(presentation.regularWindows.map(\.id), ["codex.codex.primary", "codex.codex.secondary"])
            XCTAssertEqual(presentation.reserveWindows.count, 1)
            XCTAssertFalse(presentation.showsReserveProminently)
            XCTAssertEqual(UsageWindowPresentation(providerID: .codex, window: snapshot.windows[0])
                .displayName(locale: Locale(identifier: "en")), "Luna Reserve")
        }
        let reads = await reader.readCount
        XCTAssertEqual(reads, 1, "Rendering must not trigger another provider read")
        XCTAssertEqual(snapshot, original, "Presentation retains no new snapshot/history and does not mutate domain data")
    }

    @MainActor
    func testDisabledCodexDoesNotReachAppServerReader() async {
        let suiteName = "dev.quotapulse.tests.codex-disabled-reader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setProvider(.codex, enabled: false)
        let reader = CountingCodexRateLimitsReader()
        let provider = CodexProvider(reader: reader)

        let states = await UsageService(
            providers: [provider],
            preferences: preferences
        ).refresh()

        let readCount = await reader.readCount
        XCTAssertEqual(states.map(\.status), [.disabled])
        XCTAssertEqual(readCount, 0)
    }

    func testValidUsageResponseIncludesNormalizedAvailabilityAndLastUpdatedTime() async throws {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 37.5,
                    windowDurationMins: 300,
                    resetsAt: 2_000_003_600
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response)),
            now: { capturedAt },
            locale: Locale(identifier: "en")
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()
        let state = try XCTUnwrap(states.first)
        let window = try XCTUnwrap(state.snapshot?.windows.first)

        XCTAssertEqual(state.status, .available)
        XCTAssertEqual(state.lastUpdatedAt, capturedAt)
        XCTAssertEqual(window.usedPercentage, 37.5)
        XCTAssertEqual(window.remainingPercentage, 62.5)
        XCTAssertEqual(window.resetAt, Date(timeIntervalSince1970: 2_000_003_600))
    }

    func testMapsMultiBucketResponseWithoutGuessingMissingWindows() async throws {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let response = CodexRateLimitsResult(
            rateLimits: nil,
            rateLimitsByLimitId: [
                "codex": CodexRateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: CodexRateLimitWindow(
                        usedPercent: 37.5,
                        windowDurationMins: 300,
                        resetsAt: 2_000_003_600
                    ),
                    secondary: nil
                ),
                "codex_other": CodexRateLimitBucket(
                    limitId: "codex_other",
                    limitName: "Other limit",
                    primary: CodexRateLimitWindow(
                        usedPercent: 8,
                        windowDurationMins: 60,
                        resetsAt: 2_000_007_200
                    ),
                    secondary: CodexRateLimitWindow(
                        usedPercent: 12,
                        windowDurationMins: 10_080,
                        resetsAt: 2_000_604_800
                    )
                )
            ]
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response)),
            now: { capturedAt },
            locale: Locale(identifier: "en")
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.source.kind, .codexAppServer)
        XCTAssertEqual(snapshot.windows.map(\.id), [
            "codex.codex.primary",
            "codex.codex_other.primary",
            "codex.codex_other.secondary"
        ])
        XCTAssertEqual(snapshot.windows[0].usedPercentage, 37.5)
        XCTAssertEqual(snapshot.windows[0].duration, .seconds(18_000))
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_003_600))
        XCTAssertEqual(snapshot.windows[2].label, "Other limit · Secondary window")
    }

    func testUsesMultiBucketDictionaryKeysForStableUniqueWindowIDs() async throws {
        let window = CodexRateLimitWindow(
            usedPercent: 10,
            windowDurationMins: 60,
            resetsAt: nil
        )
        let response = CodexRateLimitsResult(
            rateLimits: nil,
            rateLimitsByLimitId: [
                "codex": CodexRateLimitBucket(
                    limitId: "duplicated",
                    limitName: nil,
                    primary: window,
                    secondary: nil
                ),
                "codex_other": CodexRateLimitBucket(
                    limitId: "duplicated",
                    limitName: nil,
                    primary: window,
                    secondary: nil
                )
            ]
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.windows.map(\.id), [
            "codex.codex.primary",
            "codex.codex_other.primary"
        ])
    }

    func testFallsBackToBackwardCompatibleSingleBucket() async throws {
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 140,
                    windowDurationMins: 15,
                    resetsAt: nil
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercentage, 140)
        XCTAssertEqual(snapshot.windows[0].displayUsedPercentage, 100)
        XCTAssertNil(snapshot.windows[0].resetAt)
    }

    func testPreservesUnavailableOptionalFieldsWithoutGuessing() async throws {
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: nil,
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 20,
                    windowDurationMins: nil,
                    resetsAt: nil
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        let snapshot = try await provider.fetchUsage()
        let window = try XCTUnwrap(snapshot.windows.first)

        XCTAssertEqual(window.usedPercentage, 20)
        XCTAssertEqual(window.remainingPercentage, 80)
        XCTAssertNil(window.duration)
        XCTAssertNil(window.resetAt)
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testParsesResetTimestampAsUnixSeconds() async throws {
        let resetTimestamp: TimeInterval = 2_000_003_600.5
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 10,
                    windowDurationMins: 300,
                    resetsAt: resetTimestamp
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(
            snapshot.windows.first?.resetAt,
            Date(timeIntervalSince1970: resetTimestamp)
        )
    }

    func testUnavailableExecutableMapsToNotInstalledState() async {
        let provider = CodexProvider(
            locator: CodexExecutableLocator(candidateURLs: [
                URL(fileURLWithPath: "/path/that/does/not/exist/codex")
            ])
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(states.first?.status, .notInstalled)
        XCTAssertNil(states.first?.snapshot)
    }

    func testProviderFailureMapsToSanitizedErrorState() async {
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(
                result: .failure(CodexAppServerError.serverError(code: -32_603))
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

    func testAppServerLaunchFailureHasDistinctNormalizedState() async {
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(
                result: .failure(CodexAppServerError.launchFailed)
            )
        )
        let service = UsageService(providers: [provider])

        let states = await service.refresh()

        XCTAssertEqual(states.first?.status, .failed(.runtimeLaunchFailed))
        XCTAssertNil(states.first?.snapshot)
    }

    func testPreservesResetOnlyWindowWithoutFabricatingUsage() async throws {
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: nil,
                    windowDurationMins: 300,
                    resetsAt: 2_000_003_600
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].usedPercentage)
        XCTAssertEqual(
            snapshot.windows[0].resetAt,
            Date(timeIntervalSince1970: 2_000_003_600)
        )
    }

    func testRejectsResponseWithoutUsageOrResetData() async {
        let response = CodexRateLimitsResult(
            rateLimits: CodexRateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: nil,
                    windowDurationMins: 300,
                    resetsAt: nil
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let provider = CodexProvider(
            reader: StubCodexRateLimitsReader(result: .success(response))
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected the provider to reject a response without usage or reset data")
        } catch {
            XCTAssertEqual(error as? CodexProviderError, .noRateLimits)
        }
    }

    func testLiveCodexProviderWhenExplicitlyEnabled() async throws {
        let debugBundleIdentifier = "dev.quotapulse.development.app"
        let isEnabled = ProcessInfo.processInfo.environment["QUOTAPULSE_RUN_LIVE_CODEX_TEST"] == "1"
            || UserDefaults.standard.bool(forKey: "runLiveCodexProviderTest")
        guard isEnabled else {
            throw XCTSkip("Set QUOTAPULSE_RUN_LIVE_CODEX_TEST=1 for the opt-in live provider check.")
        }
        XCTAssertEqual(Bundle.main.bundleIdentifier, debugBundleIdentifier)

        let snapshot = try await CodexProvider().fetchUsage()

        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.source.kind, .codexAppServer)
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.windows.allSatisfy { window in
            !window.id.isEmpty && (window.usedPercentage != nil || window.resetAt != nil)
        })
    }
}

private struct StubCodexRateLimitsReader: CodexRateLimitsReading {
    let result: Result<CodexRateLimitsResult, Error>

    func readRateLimits() async throws -> CodexRateLimitsResult {
        try result.get()
    }
}

private actor CountingCodexRateLimitsReader: CodexRateLimitsReading {
    private(set) var readCount = 0

    func readRateLimits() async throws -> CodexRateLimitsResult {
        readCount += 1
        return CodexRateLimitsResult(rateLimits: nil, rateLimitsByLimitId: nil)
    }
}

private actor CountingReserveReader: CodexRateLimitsReading {
    let response: CodexRateLimitsResult
    private(set) var readCount = 0

    init(response: CodexRateLimitsResult) { self.response = response }

    func readRateLimits() async throws -> CodexRateLimitsResult {
        readCount += 1
        return response
    }
}
