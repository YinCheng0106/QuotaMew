import Foundation
import XCTest
@testable import QuotaMew

final class MenuBarPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let english = Locale(identifier: "en")
    private let traditionalChinese = Locale(identifier: "zh-Hant-TW")

    func testSingleSelectionsUseSemanticWindowsAndCompactIdentifiers() {
        let state = codexState([
            window("codex.codex.secondary", used: 14, duration: .seconds(18_000)),
            window("codex.base_model_inference.primary", used: 58, duration: .seconds(604_800)),
            window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
        ])

        let values = MenuBarQuotaSelection.allCases.map { selection in
            presentation(state, style: .single, selection: selection).compactText(locale: english)
        }

        XCTAssertEqual(values, ["5H 86%", "W 71%", "R 42%"])
    }

    func testSingleMissingSelectionShowsItsPlaceholderWithoutMetricSubstitution() {
        let state = codexState([
            window("codex.codex.primary", used: 14, duration: .seconds(18_000)),
        ])
        let value = presentation(state, style: .single, selection: .weekly)

        XCTAssertEqual(value.selectedProvider, .codex)
        XCTAssertNil(value.currentlyRenderedProvider)
        XCTAssertEqual(value.metrics.map(\.quotaSelection), [.weekly])
        XCTAssertNil(value.metrics.first?.usage)
        XCTAssertEqual(value.compactText(locale: english), "W —")
        XCTAssertEqual(value.availability, .unavailable)
    }

    func testEverySingleSelectionHasASelectionSpecificUnavailablePlaceholder() {
        let state = codexState([])
        let values = MenuBarQuotaSelection.allCases.map { selection in
            presentation(state, style: .single, selection: selection).compactText(locale: english)
        }

        XCTAssertEqual(values, ["5H —", "W —", "R —"])
    }

    func testExplicitPinNeverFallsBackToAnotherProviderOrMetric() {
        let codex = codexState([
            window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
        ])
        let claude = providerState(.claude, windows: [
            window("claude.five-hour", used: 14, duration: .seconds(18_000)),
        ])
        let value = MenuBarPresentation(
            providerStates: [codex, claude],
            persistedPinnedProviderRawValue: ProviderID.claude.rawValue,
            displayStyle: .single,
            quotaSelection: .weekly,
            mode: .remaining,
            now: now
        )

        XCTAssertEqual(value.persistedPinnedProvider, .claude)
        XCTAssertEqual(value.selectedProvider, .claude)
        XCTAssertNil(value.currentlyRenderedProvider)
        XCTAssertEqual(value.compactText(locale: english), "W —")
    }

    func testDisabledExplicitPinStaysSelectedAndCanRenderAfterEnablement() {
        let windows = [window("codex.codex.primary", used: 29, duration: .seconds(604_800))]
        let disabled = presentation(
            codexState(windows, status: .disabled),
            style: .single,
            selection: .weekly
        )
        let enabled = presentation(
            codexState(windows),
            style: .single,
            selection: .weekly
        )

        XCTAssertEqual(disabled.selectedProvider, .codex)
        XCTAssertNil(disabled.currentlyRenderedProvider)
        XCTAssertEqual(disabled.compactText(locale: english), "W —")
        XCTAssertEqual(disabled.availability, .disabled)
        XCTAssertEqual(enabled.currentlyRenderedProvider, .codex)
        XCTAssertEqual(enabled.compactText(locale: english), "W 71%")
    }

    func testAutomaticUsesFirstProviderRenderableForChosenSemanticMetric() {
        let unavailableClaude = providerState(
            .claude,
            status: .notConfigured,
            windows: [window("claude.week", used: 24, duration: .seconds(604_800))]
        )
        let codex = codexState([
            window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
        ])
        let value = MenuBarPresentation(
            providerStates: [unavailableClaude, codex],
            persistedPinnedProviderRawValue: nil,
            displayStyle: .single,
            quotaSelection: .weekly,
            mode: .remaining,
            now: now
        )

        XCTAssertEqual(value.selectedProvider, .codex)
        XCTAssertEqual(value.currentlyRenderedProvider, .codex)
        XCTAssertEqual(value.compactText(locale: english), "W 71%")
    }

    func testUnknownPinIsSafeAndAllDisabledAutomaticStateIsEmpty() {
        let available = codexState([
            window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
        ])
        let unknown = MenuBarPresentation(
            providerStates: [available],
            persistedPinnedProviderRawValue: "future-provider",
            displayStyle: .single,
            quotaSelection: .weekly,
            mode: .remaining,
            now: now
        )
        let allDisabled = MenuBarPresentation(
            providerStates: [
                codexState([], status: .disabled),
                providerState(.claude, status: .disabled, windows: []),
            ],
            persistedPinnedProviderRawValue: nil,
            displayStyle: .overview,
            quotaSelection: .weekly,
            mode: .remaining,
            now: now
        )

        XCTAssertNil(unknown.persistedPinnedProvider)
        XCTAssertNil(unknown.selectedProvider)
        XCTAssertTrue(unknown.metrics.isEmpty)
        XCTAssertEqual(unknown.availability, .unavailable)
        XCTAssertTrue(allDisabled.metrics.isEmpty)
        XCTAssertEqual(allDisabled.availability, .empty)
    }

    func testOverviewHasFixedRegularOrderAndNormallyOmitsReserve() {
        let value = presentation(
            codexState([
                window("codex.base_model_inference.primary", used: 58),
                window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
                window("codex.codex.secondary", used: 14, duration: .seconds(18_000)),
            ]),
            style: .overview,
            selection: .lunaReserve
        )

        XCTAssertEqual(value.metrics.map(\.quotaSelection), [.fiveHour, .weekly])
        XCTAssertEqual(value.compactText(locale: english), "5H 86% · W 71%")
    }

    func testOverviewAddsReserveOnlyThroughExistingProminenceProjection() {
        let state = codexState([
            window("codex.codex.primary", used: 100, duration: .seconds(18_000)),
            window("codex.codex.secondary", used: 100, duration: .seconds(604_800)),
            window("codex.base_model_inference.primary", used: 29),
        ])
        XCTAssertTrue(ProviderWindowsPresentation(state: state, now: now).showsReserveProminently)

        let value = presentation(state, style: .overview, selection: .weekly)

        XCTAssertEqual(value.metrics.map(\.quotaSelection), [.fiveHour, .weekly, .lunaReserve])
        XCTAssertEqual(value.compactText(locale: english), "5H 0% · W 0% · R 71%")
    }

    func testOverviewDoesNotDuplicateSemanticMetricWhenSnapshotHasDuplicates() throws {
        let value = presentation(
            codexState([
                window("z-five-hour", used: 90, duration: .seconds(18_000)),
                window("a-five-hour", used: 14, duration: .seconds(18_000)),
                window("codex.codex.primary", used: 29, duration: .seconds(604_800)),
            ]),
            style: .overview,
            selection: .weekly
        )

        XCTAssertEqual(value.metrics.map(\.quotaSelection), [.fiveHour, .weekly])
        XCTAssertEqual(try XCTUnwrap(value.metrics.first?.windowPresentation?.windowID), "a-five-hour")
        XCTAssertEqual(value.compactText(locale: english), "5H 86% · W 71%")
    }

    func testRemainingAndUsedReuseUsagePresentationForEveryMetric() {
        let state = codexState([
            window("codex.codex.primary", used: 14, duration: .seconds(18_000)),
            window("codex.codex.secondary", used: 29, duration: .seconds(604_800)),
        ])
        let remaining = presentation(
            state,
            style: .overview,
            selection: .weekly,
            mode: .remaining
        )
        let used = presentation(
            state,
            style: .overview,
            selection: .weekly,
            mode: .used
        )

        XCTAssertEqual(remaining.compactText(locale: english), "5H 86% · W 71%")
        XCTAssertEqual(used.compactText(locale: english), "5H 14% · W 29%")
        XCTAssertEqual(remaining.metrics.map(\.usage?.mode), [.remaining, .remaining])
        XCTAssertEqual(used.metrics.map(\.usage?.mode), [.used, .used])
    }

    func testAccessibilityUsesFullLocalizedNamesWithoutParsingCompactText() {
        let state = codexState([
            window("codex.codex.primary", used: 14, duration: .seconds(18_000)),
            window("codex.codex.secondary", used: 29, duration: .seconds(604_800)),
        ])
        let single = presentation(state, style: .single, selection: .weekly)
        let overview = presentation(state, style: .overview, selection: .weekly)

        XCTAssertEqual(single.accessibilityValue(locale: english), "Weekly quota, 71% remaining")
        XCTAssertEqual(single.accessibilityValue(locale: traditionalChinese), "每週配額，剩餘 71%")
        XCTAssertEqual(
            overview.accessibilityValue(locale: english),
            "5-hour quota, 86% remaining; Weekly quota, 71% remaining"
        )
        XCTAssertEqual(
            overview.accessibilityValue(locale: traditionalChinese),
            "5 小時配額，剩餘 86%；每週配額，剩餘 71%"
        )
    }

    func testReserveAccessibilityUsesProductNameRatherThanRawIdentifier() {
        let value = presentation(
            codexState([
                window("codex.base_model_inference.primary", used: 29),
            ]),
            style: .single,
            selection: .lunaReserve
        )

        XCTAssertEqual(value.accessibilityValue(locale: english), "Luna Reserve quota, 71% remaining")
        XCTAssertFalse(value.accessibilityValue(locale: english)?.contains("base_model_inference") == true)
    }

    func testClaudeExactDurationsSupportFiveHourAndWeeklyLikeSelection() {
        let state = providerState(.claude, windows: [
            window("claude.long", used: 29, duration: .seconds(604_800)),
            window("claude.short", used: 14, duration: .seconds(18_000)),
        ])
        let value = MenuBarPresentation(
            providerStates: [state],
            persistedPinnedProviderRawValue: ProviderID.claude.rawValue,
            displayStyle: .overview,
            quotaSelection: .weekly,
            mode: .remaining,
            now: now
        )

        XCTAssertEqual(value.compactText(locale: english), "5H 86% · W 71%")
        XCTAssertEqual(
            value.accessibilityValue(locale: english),
            "5-hour quota, 86% remaining; Weekly quota, 71% remaining"
        )
    }

    private func presentation(
        _ state: ProviderState,
        style: MenuBarDisplayStyle,
        selection: MenuBarQuotaSelection,
        mode: UsagePresentationMode = .remaining
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            providerStates: [state],
            persistedPinnedProviderRawValue: state.providerID.rawValue,
            displayStyle: style,
            quotaSelection: selection,
            mode: mode,
            now: now
        )
    }

    private func window(
        _ id: String,
        used: Double?,
        duration: Duration? = .seconds(604_800)
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            label: "Untrusted provider label",
            usedPercentage: used,
            resetAt: now.addingTimeInterval(3_600),
            duration: duration
        )
    }

    private func codexState(
        _ windows: [UsageWindow],
        status: ProviderStatus = .available
    ) -> ProviderState {
        providerState(.codex, status: status, windows: windows)
    }

    private func providerState(
        _ providerID: ProviderID,
        status: ProviderStatus = .available,
        windows: [UsageWindow]
    ) -> ProviderState {
        ProviderState(
            providerID: providerID,
            status: status,
            snapshot: ProviderUsageSnapshot(
                providerID: providerID,
                windows: windows,
                capturedAt: now,
                source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
            )
        )
    }
}
