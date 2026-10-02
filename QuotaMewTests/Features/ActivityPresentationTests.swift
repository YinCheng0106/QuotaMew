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
