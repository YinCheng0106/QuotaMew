import Foundation
import XCTest
@testable import QuotaMew

final class ActivityInsightsPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let chinese = Locale(identifier: "zh-Hant-TW")

    private func projection(count: Int = 14, current: Int64 = 20, previous: Int64 = 10) throws -> ActivityProjection {
        let anchor = try ProviderCalendarDate("2026-10-03")
        let snapshot = try ProviderActivitySnapshot(providerID: .codex, buckets: (0..<count).map {
            try ActivityBucket(sourceDate: anchor.addingDays(-$0), reportedTokens: $0 < 7 ? current : previous)
        }, capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
        return try XCTUnwrap(ActivityProjection.query(snapshot))
    }

    func testLatestHasNoRedundantInsightsAndPeriodQueriesUseSameSnapshot() throws {
        let value = try projection()
        XCTAssertNil(ActivityPresentation(projection: value, period: .latest, locale: english).insights)
        for period in [ActivityPeriod.sevenDays, .thirtyDays] {
            let report = ActivityPresentation(projection: value, period: period, locale: english)
            XCTAssertNotNil(report.insights)
            XCTAssertEqual(report.sourceDates.suffix(10), "2026-10-03")
        }
    }

    func testExactAverageHighestDateAndNeutralIncreaseInBothLanguages() throws {
        let query = try projection().sevenDayInsights
        let en = ActivityInsightsPresentation(query: query, locale: english)
        let zh = ActivityInsightsPresentation(query: query, locale: chinese)
        XCTAssertEqual(en.averageText, "About 20 provider-reported tokens per reported date (reported dates: 7).")
        XCTAssertEqual(zh.averageText, "每個已回報日期約 20 token（已回報 7 個日期）。")
        XCTAssertEqual(en.highestText, "2026-10-03: 20 provider-reported tokens.")
        XCTAssertEqual(zh.highestText, "2026-10-03：供應商回報 20 token。")
        XCTAssertEqual(en.comparisonText, "Reported total increased by about 100 percent compared with the previous period.")
        XCTAssertEqual(zh.comparisonText, "已回報總量較前一期約增加 100%。")
        XCTAssertEqual(en.highestTieText, "7 reported dates share the highest value; the latest source date is shown.")
        XCTAssertEqual(zh.previousDatesText, "前一期來源日期：2026-09-20 – 2026-09-26")
    }

    func testPartialComparisonExplainsBothCoverageCountsInsteadOfZero() throws {
        let query = try projection(count: 11).sevenDayInsights
        for locale in [english, chinese] {
            let value = ActivityInsightsPresentation(query: query, locale: locale)
            XCTAssertFalse(value.comparisonText.contains("percent"))
            XCTAssertFalse(value.comparisonText.contains("%"))
            XCTAssertTrue(value.comparisonText.contains("4"))
            XCTAssertTrue(value.comparisonText.contains("7"))
        }
        XCTAssertEqual(ActivityInsightsPresentation(query: query, locale: chinese).comparisonText,
                       "無法比較：本期已回報 7／7 個日期，前一期已回報 4／7 個日期。兩期都需完整回報每個日期。")
    }

    func testFiftySixDatesThirtyDayComparisonRemainsUnavailable() throws {
        let value = ActivityInsightsPresentation(query: try projection(count: 56).thirtyDayInsights, locale: english)
        XCTAssertTrue(value.comparisonText.contains("30 of 30"))
        XCTAssertTrue(value.comparisonText.contains("26 of 30"))
        XCTAssertFalse(value.averageText.contains("unavailable"))
    }

    func testReportedZeroIsNotMissingAndNoDataHasNoPlaceholderNumber() throws {
        let zero = ActivityInsightsPresentation(query: try projection(current: 0, previous: 0).sevenDayInsights, locale: english)
        XCTAssertTrue(zero.averageText.contains("About 0"))
        XCTAssertTrue(zero.highestText.contains("0 provider-reported tokens"))
        XCTAssertEqual(zero.comparisonText, "Reported total is unchanged from the previous period.")
        for query in [ActivityInsightsQuery.noReportedData, .sourceDateOutOfRange] {
            let missing = ActivityInsightsPresentation(query: query, locale: english)
            XCTAssertFalse(missing.averageText.contains("0"))
            XCTAssertNil(missing.previousDatesText)
            XCTAssertNil(missing.highestTieText)
        }
    }

    func testDecreaseAndZeroBaselineUseFullMeaningfulSentences() throws {
        let decrease = try projection(current: 5, previous: 10).sevenDayInsights
        XCTAssertEqual(ActivityInsightsPresentation(query: decrease, locale: english).comparisonText,
                       "Reported total decreased by about 50 percent compared with the previous period.")
        XCTAssertEqual(ActivityInsightsPresentation(query: decrease, locale: chinese).comparisonText,
                       "已回報總量較前一期約減少 50%。")
        let baseline = try projection(current: 5, previous: 0).sevenDayInsights
        for locale in [english, chinese] {
            let text = ActivityInsightsPresentation(query: baseline, locale: locale).comparisonText
            XCTAssertTrue(text.contains("35"))
            XCTAssertFalse(text.contains("100"))
            XCTAssertFalse(text.contains("∞"))
        }
        XCTAssertEqual(ActivityInsightsPresentation(query: baseline, locale: chinese).comparisonText,
                       "已回報總量增加 35 token。前一期已回報總量為零，因此無法計算百分比比較。")
    }

    func testSmallChangeDoesNotAnnounceUnchanged() throws {
        for (current, previous, word) in [(Int64(1001), Int64(1000), "increased"), (999, 1000, "decreased")] {
            let query = try projection(current: current, previous: previous).sevenDayInsights
            let text = ActivityInsightsPresentation(query: query, locale: english).comparisonText
            XCTAssertTrue(text.contains(word))
            XCTAssertTrue(text.contains("less than 1%"))
            XCTAssertFalse(text.contains("unchanged"))
            XCTAssertTrue(ActivityInsightsPresentation(query: query, locale: chinese).comparisonText.contains("不到 1%"))
        }
    }

    func testAverageOverflowAndPercentageOverflowExplainWithoutInventedNumbers() throws {
        let date = try ProviderCalendarDate("2026-10-03")
        func query(_ values: [(Int, Int64)]) throws -> ActivityInsightsQuery {
            ActivityInsights.query(try ProviderActivitySnapshot(providerID: .codex, buckets: values.map {
                try ActivityBucket(sourceDate: date.addingDays(-$0.0), reportedTokens: $0.1)
            }, capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic), period: .sevenDays)
        }
        let overflow = try query([(0, .max), (1, 1)])
        XCTAssertEqual(ActivityInsightsPresentation(query: overflow, locale: english).averageText,
                       "Reported values are too large to summarize.")
        let percent = try query((0..<14).map { ($0, $0 == 0 ? .max : $0 == 7 ? 1 : 0) })
        let text = ActivityInsightsPresentation(query: percent, locale: english).comparisonText
        XCTAssertTrue(text.contains("increased"))
        XCTAssertTrue(text.contains("9,223,372,036,854,775,806"))
        XCTAssertTrue(text.contains("unavailable"))
    }

    func testLocalizedTitlesAndSemanticBoundaries() throws {
        for (key, expected) in [(String.LocalizationValue("Activity Insights"), "活動洞察"),
                                ("Daily reported average", "每日回報平均"),
                                ("Highest reported day", "最高回報日"),
                                ("Compared with previous period", "與前一期間相比")] {
            XCTAssertEqual(AppLocalization.string(key, locale: chinese), expected)
        }
        for locale in [english, chinese] {
            let value = ActivityInsightsPresentation(query: try projection().sevenDayInsights, locale: locale)
            let text = [value.averageText, value.highestText, value.comparisonText,
                        value.highestTieText, value.previousDatesText].compactMap { $0 }.joined(separator: " ")
            for forbidden in ["Today", "今天", "productivity", "efficiency", "billing", "cost", "spending", "good", "bad"] {
                XCTAssertFalse(text.contains(forbidden))
            }
        }
    }
}
