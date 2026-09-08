import Foundation
import XCTest
@testable import QuotaMew

final class UsageWindowPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let en = Locale(identifier: "en")
    private let zh = Locale(identifier: "zh-Hant-TW")

    func testDurationDefinesNameEvenWhenRolesAndOrderAreReversed() {
        let weekly = window("codex.codex.primary", duration: .seconds(604_800))
        let fiveHour = window("codex.codex.secondary", duration: .seconds(18_000))
        for (locale, expected) in [(en, ["Weekly", "5-hour"]), (zh, ["每週", "5 小時"])] {
            XCTAssertEqual([weekly, fiveHour].map {
                UsageWindowPresentation(providerID: .codex, window: $0).displayName(locale: locale)
            }, expected)
        }
    }

    func testUnknownDurationNeverExposesRawLabelsOrGuessesFromPosition() {
        let durations: [Duration?] = [nil, .zero, .seconds(-1), .seconds(18_001),
                                      .seconds(604_799), .nanoseconds(18_000_000_000_001)]
        for duration in durations {
            let value = window("codex.codex.primary", duration: duration)
            let presentation = UsageWindowPresentation(providerID: .codex, window: value)
            XCTAssertEqual(presentation.displayName(locale: en), "quota window")
            XCTAssertEqual(presentation.displayName(locale: zh), "配額週期")
        }
    }

    @MainActor
    func testDashboardRowAndVoiceOverUseSharedNameWithoutChangingDomainData() {
        for duration in [Duration.seconds(18_000), .seconds(604_800)] {
            let value = window("codex.codex.secondary", duration: duration)
            let original = value
            let row = UsageWindowRow(window: value, mode: .remaining, providerID: .codex)
            for locale in [en, zh] {
                let name = row.windowPresentation.displayName(locale: locale)
                XCTAssertEqual(row.windowPresentation.accessibilityLabel(locale: locale), "Codex, \(name)")
                XCTAssertFalse(name.contains("gpt-reserve"))
                XCTAssertFalse(name.contains("Primary"))
                XCTAssertEqual(UsagePresentation(window: value, mode: .remaining).percentage, 61)
            }
            XCTAssertEqual(value, original)
            XCTAssertEqual(value.label, "gpt-reserve · raw provider label")
        }
    }

    func testReserveNamesUseExactNormalizedIdentityAndOverrideWeeklyDuration() {
        for bucket in ["base_model_inference", "gpt-reserve"] {
            for role in ["primary", "secondary"] {
                let value = window("codex.\(bucket).\(role)", duration: .seconds(604_800))
                let presentation = UsageWindowPresentation(providerID: .codex, window: value)
                XCTAssertTrue(presentation.isReserve)
                XCTAssertEqual(presentation.displayName(locale: en), "Luna Reserve")
                XCTAssertEqual(presentation.displayName(locale: zh), "Luna Reserve")
                XCTAssertFalse(UsageWindowPresentation(providerID: .claude, window: value).isReserve)
            }
        }
        for id in ["gpt-reserve", "codex.gpt-reserve-other.primary", "codex.other.primary"] {
            XCTAssertFalse(UsageWindowPresentation(providerID: .codex, window: window(id)).isReserve)
        }
    }

    func testReserveRemainsSecondaryWithUsableRegularCapacityAndNeverTakesMenuMetric() {
        let reserve = window("codex.base_model_inference.primary", used: 1)
        let regular = window("codex.codex.primary", used: 39)
        let value = state([reserve, regular])
        let projection = ProviderWindowsPresentation(state: value, now: now)
        XCTAssertEqual(projection.regularWindows, [regular])
        XCTAssertEqual(projection.reserveWindows, [reserve])
        XCTAssertFalse(projection.showsReserveProminently)
        XCTAssertEqual(menu(value).metrics.first?.usage?.percentage, 61)
        XCTAssertNil(menu(state([reserve])).metrics.first?.usage)
    }

    func testEitherRegularWindowCanSurfaceReserveWithoutReplacingRegularIdentity() {
        let reserve = window("codex.base_model_inference.primary", used: 5)
        for duration in [Duration.seconds(18_000), .seconds(604_800)] {
            let regular = window("codex.codex.secondary", used: 100, duration: duration)
            let value = state([reserve, regular])
            let projection = ProviderWindowsPresentation(state: value, now: now)
            XCTAssertTrue(projection.showsReserveProminently)
            XCTAssertEqual(projection.regularWindows, [regular])
            XCTAssertEqual(projection.reserveWindows, [reserve])
            let selection: MenuBarQuotaSelection = duration == .seconds(18_000)
                ? .fiveHour
                : .weekly
            XCTAssertEqual(menu(value, selection: selection).metrics.first?.usage?.percentage, 0)
        }
    }

    func testUnknownStaleInvalidAndReserveOnlyDataCannotClaimRegularExhaustion() {
        let reserve = window("codex.base_model_inference.primary", used: 100)
        for used: Double? in [nil, .nan, .infinity, -1, 99.9, 101] {
            let value = state([reserve, window("codex.codex.primary", used: used)])
            XCTAssertFalse(ProviderWindowsPresentation(state: value, now: now).showsReserveProminently)
        }
        for status: ProviderStatus in [.stale, .loading, .failed(.refreshFailed), .disabled] {
            let value = state([reserve, window("codex.codex.primary", used: 100)], status: status)
            XCTAssertFalse(ProviderWindowsPresentation(state: value, now: now).showsReserveProminently)
        }
        for value in [state([reserve]), state([reserve, window("codex.other.primary", used: 100)]),
                      state([reserve, window("codex.codex.primary", used: 100, duration: nil)])] {
            XCTAssertFalse(ProviderWindowsPresentation(state: value, now: now).showsReserveProminently)
        }
        let exhausted = state([reserve, window("codex.codex.primary", used: 100)])
        XCTAssertFalse(ProviderWindowsPresentation(state: exhausted, now: now.addingTimeInterval(900)).showsReserveProminently)
        XCTAssertFalse(ProviderWindowsPresentation(state: exhausted, now: now.addingTimeInterval(-1)).showsReserveProminently)
        let expired = window("codex.codex.primary", used: 100, resetAt: now)
        XCTAssertFalse(ProviderWindowsPresentation(state: state([reserve, expired]), now: now).showsReserveProminently)
    }

    func testReminderNameMatchesDashboardAndIdentityAndThresholdStayStable() throws {
        for (duration, nameEN, nameZH) in [(Duration.seconds(18_000), "5-hour", "5 小時"),
                                         (.seconds(604_800), "Weekly", "每週")] {
            let value = window("codex.codex.primary", duration: duration)
            for (locale, name) in [(en, nameEN), (zh, nameZH)] {
                let result = ResetNotificationPolicy.v01.evaluate(
                    [state([value])], state: .init(), now: now, locale: locale
                )
                let decision = try XCTUnwrap(result.decisions.first)
                XCTAssertTrue(decision.title.contains(name))
                XCTAssertEqual(decision.windowID, value.id)
                XCTAssertEqual(decision.thresholdMinutes, 60)
                XCTAssertTrue(decision.identifier.hasPrefix("quotapulse.reset.codex."))
                let completed = AppLocalization.resetCompletedBody(
                    windowName: UsageWindowPresentation(providerID: .codex, window: value).displayName(locale: locale),
                    locale: locale
                )
                XCTAssertTrue(completed.contains(name))
            }
        }
    }

    private func window(
        _ id: String,
        used: Double? = 39,
        duration: Duration? = .seconds(18_000),
        resetAt: Date? = nil
    ) -> UsageWindow {
        UsageWindow(id: id, label: "gpt-reserve · raw provider label", usedPercentage: used,
                    resetAt: resetAt ?? now.addingTimeInterval(3_600), duration: duration,
                    resetCycleIdentifier: "unchanged-cycle")
    }

    private func state(_ windows: [UsageWindow], status: ProviderStatus = .available) -> ProviderState {
        ProviderState(providerID: .codex, status: status, snapshot: ProviderUsageSnapshot(
            providerID: .codex, windows: windows, capturedAt: now,
            source: UsageSource(kind: .codexAppServer, label: "Test", documentationURL: nil)
        ))
    }

    private func menu(
        _ state: ProviderState,
        selection: MenuBarQuotaSelection = .fiveHour
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            providerStates: [state],
            persistedPinnedProviderRawValue: "codex",
            displayStyle: .single,
            quotaSelection: selection,
            mode: .remaining,
            now: now
        )
    }
}
