import Foundation
import XCTest
@testable import QuotaMew

final class ActivityPresentationTests: XCTestCase {
    let english = Locale(identifier: "en_US")
    let chinese = Locale(identifier: "zh-Hant-TW")

    func testCompactAndExactFormatting() {
        for (value, expected) in [(Int64(0), "0"), (999, "999"), (1_000, "1K"),
                                  (1_250, "1.2K"), (1_000_000, "1M"), (42_600, "42.6K"),
                                  (3_200_000, "3.2M"), (1_100_000_000, "1.1B")] {
            XCTAssertEqual(ActivityFormatting.compact(value, locale: english), expected)
        }
        XCTAssertEqual(ActivityFormatting.full(.max, locale: english), "9,223,372,036,854,775,807")
        XCTAssertFalse(ActivityFormatting.compact(.max, locale: english).isEmpty)
        XCTAssertEqual(ActivityFormatting.compact(42_600, locale: Locale(identifier: "de_DE")), "42.600")
        XCTAssertEqual(ActivityFormatting.compact(42_600, locale: chinese), "4.3萬")
    }

    func testChartAxisFormattingIsCompactAndUsesExistingActivityNumberFormatter() throws {
        for locale in [english, chinese] {
            for value in [25_000_000, 50_000_000, 75_000_000, 100_000_000] {
                let formatted = ActivityFormatting.compact(Int64(value), locale: locale)
                XCTAssertFalse(formatted.contains("E"), "Unexpected scientific notation: \(formatted)")
                XCTAssertEqual(formatted, Int64(value).formatted(
                    .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale)
                ))
            }
        }
        XCTAssertEqual(ActivityFormatting.compact(75_000_000, locale: english), "75M")
    }

    func testChartDateFormattingAcrossMonthAndYearBoundaries() throws {
        XCTAssertEqual(ActivityFormatting.chartDate(try ProviderCalendarDate("2026-09-26")), "9/26")
        XCTAssertEqual(ActivityFormatting.chartDate(try ProviderCalendarDate("2026-10-01")), "10/1")
        XCTAssertEqual(ActivityFormatting.chartDate(try ProviderCalendarDate("2026-12-31")), "12/31")
        XCTAssertEqual(ActivityFormatting.chartDate(try ProviderCalendarDate("2027-01-01")), "1/1")
    }

    func testSevenDayChartAxisKeepsDailyDataAndCompactChronologicalLabels() throws {
        let report = ActivityPresentation(projection: try fixture(), period: .sevenDays, locale: english)
        let ticks = ActivityChartAxisPolicy.ticks(for: report.points, period: .sevenDays, availableWidth: 372)
        XCTAssertEqual(report.points.count, 7)
        XCTAssertEqual(ticks.map(\.label), ["9/26", "9/27", "9/28", "9/29", "9/30", "10/1", "10/2"])
        XCTAssertEqual(ticks.map(\.sourceDate), ticks.map(\.sourceDate).sorted())
        XCTAssertEqual(Set(ticks.map(\.label)).count, ticks.count)
    }

    func testThirtyDayChartAxisUsesFiveEvenlySpacedTicksWithoutDroppingDailyMarks() throws {
        let report = ActivityPresentation(projection: try fixture(), period: .thirtyDays, locale: english)
        let originalPoints = report.points
        let ticks = ActivityChartAxisPolicy.ticks(for: report.points, period: .thirtyDays, availableWidth: 372)
        XCTAssertEqual(report.points.count, 30)
        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(ticks.first?.sourceDate, report.points.first?.sourceDate)
        XCTAssertEqual(ticks.last?.sourceDate, report.points.last?.sourceDate)
        XCTAssertEqual(ticks.map(\.sourceDate), ticks.map(\.sourceDate).sorted())
        XCTAssertEqual(Set(ticks.map(\.label)).count, ticks.count)
        XCTAssertEqual(report.points, originalPoints)
        XCTAssertEqual(report.points.filter { $0.mark == .missing }.count, 28)
        XCTAssertEqual(report.points.filter { $0.mark == .zero }.count, 1)
    }

    func testSevenDayChartAxisReducesTicksOnlyBelowMinimumSpacing() throws {
        let report = ActivityPresentation(projection: try fixture(), period: .sevenDays, locale: english)
        let ticks = ActivityChartAxisPolicy.ticks(for: report.points, period: .sevenDays, availableWidth: 240)
        XCTAssertLessThan(ticks.count, report.points.count)
        XCTAssertEqual(ticks.first?.sourceDate, report.points.first?.sourceDate)
        XCTAssertEqual(ticks.last?.sourceDate, report.points.last?.sourceDate)
        XCTAssertEqual(ticks.map(\.sourceDate), ticks.map(\.sourceDate).sorted())
        XCTAssertEqual(report.points.count, 7)
    }

    func testCoverageLocalizationForCompleteAndPartialWindows() {
        for (reported, expected) in [(7, 7), (4, 7), (30, 30), (28, 30)] {
            let coverage = ActivityCoverage(reportedDays: reported, expectedDays: expected)
            XCTAssertEqual(ActivityFormatting.coverage(coverage, locale: english), "\(reported) of \(expected) dates reported")
            XCTAssertEqual(ActivityFormatting.coverage(coverage, locale: chinese), "已回報 \(reported)／\(expected) 個日期")
        }
        XCTAssertEqual(ActivityFormatting.missing(3, locale: english), "3 dates were not reported by Codex")
    }

    func testZeroAndMissingHaveDifferentMarksValuesAndAccessibility() throws {
        let date = try ProviderCalendarDate("2026-10-02")
        for locale in [english, chinese] {
            let zero = ActivityPointPresentation(.reported(try ActivityBucket(sourceDate: date, reportedTokens: 0)), locale: locale)
            let missing = ActivityPointPresentation(.missing(date), locale: locale)
            XCTAssertEqual(zero.mark, .zero)
            XCTAssertEqual(zero.reportedTokens, 0)
            XCTAssertEqual(zero.valueText, "0")
            XCTAssertEqual(missing.mark, .missing)
            XCTAssertNil(missing.reportedTokens)
            XCTAssertNotEqual(zero.accessibilityText, missing.accessibilityText)
            XCTAssertFalse(missing.accessibilityText.contains("0 provider-reported tokens"))
        }
    }

    func testLatestDateUsesProviderValueAndNeverRelativeDayOrBilling() throws {
        let projection = try fixture()
        for locale in [english, chinese] {
            let latest = ActivityPresentation(projection: projection, period: .latest, locale: locale)
            XCTAssertEqual(latest.sourceDates, "2026-10-02")
            XCTAssertEqual(latest.metricText, "0")
            XCTAssertNil(latest.coverageText)
            XCTAssertTrue(latest.points.isEmpty)
            XCTAssertFalse(latest.summaryAccessibilityText.lowercased().contains("today"))
            XCTAssertFalse(latest.summaryAccessibilityText.contains("今天"))
            XCTAssertFalse(latest.summaryAccessibilityText.contains("billing"))
        }
    }

    func testRangesKeepReportedLabelCoverageAndBoundedMissingPoints() throws {
        let projection = try fixture()
        for (period, days) in [(ActivityPeriod.sevenDays, 7), (.thirtyDays, 30)] {
            let report = ActivityPresentation(projection: projection, period: period, locale: english)
            XCTAssertEqual(report.metricLabel, "Reported total")
            XCTAssertEqual(report.points.count, days)
            XCTAssertEqual(report.points.filter { $0.mark == .missing }.count, days - 2)
            XCTAssertEqual(report.points.filter { $0.mark == .zero }.count, 1)
            XCTAssertEqual(report.metricAccessibilityValue, "1,250")
            XCTAssertEqual(report.coverageText, "2 of \(days) dates reported")
            XCTAssertTrue(report.summaryAccessibilityText.contains("Reported total"))
            XCTAssertFalse(report.summaryAccessibilityText.contains("day total"))
        }
    }

    func testSanitizedStateMappingAndRefreshEligibilityInBothLanguages() {
        let states: [ActivityModelState] = [.disabled, .idle, .loading, .unsupported,
                                          .unavailable(.providerUnavailable), .failed(.timedOut),
                                          .noReportedBuckets(source: .codexAccountUsage, capturedAt: .distantPast, reason: .emptyCollection)]
        for locale in [english, chinese] {
            for state in states {
                let status = ActivityStatePresentation(state: state, locale: locale)
                XCTAssertFalse(status.title.isEmpty)
                XCTAssertFalse(status.explanation.isEmpty)
                XCTAssertEqual(status.offersSettings, state == .disabled)
                XCTAssertEqual(status.canRefresh, ![.disabled, .loading, .unsupported].contains(state))
                let visible = status.title + status.explanation
                for forbidden in ["NSError", "RPC", "timedOut", "account ID", "/Users/", "No usage"] {
                    XCTAssertFalse(visible.contains(forbidden))
                }
            }
        }
    }

    func testFetchedTimestampIsFetchAttributionAndPeriodLabelsAreLocalized() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ActivityFormatting.fetched(instant, locale: english).hasPrefix("Fetched "))
        XCTAssertTrue(ActivityFormatting.fetched(instant, locale: chinese).hasPrefix("擷取時間："))
        XCTAssertEqual(ActivityPeriod.latest.title(locale: chinese), "最新")
        XCTAssertEqual(ActivityPeriod.sevenDays.title(locale: chinese), "7D")
        XCTAssertEqual(ActivityPeriod.thirtyDays.title(locale: chinese), "30D")
    }

    private func fixture() throws -> ActivityProjection {
        let buckets = try [
            ActivityBucket(sourceDate: ProviderCalendarDate("2026-09-30"), reportedTokens: 1_250),
            ActivityBucket(sourceDate: ProviderCalendarDate("2026-10-02"), reportedTokens: 0),
        ]
        return try XCTUnwrap(ActivityProjection.query(ProviderActivitySnapshot(
            providerID: .codex, buckets: buckets, capturedAt: Date(timeIntervalSince1970: 1), source: .codexAccountUsage
        )))
    }
}
