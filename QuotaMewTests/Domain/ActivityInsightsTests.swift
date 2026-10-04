import Foundation
import XCTest
@testable import QuotaMew

final class ActivityInsightsTests: XCTestCase {
    private func snapshot(_ offsets: [(Int, Int64)], anchor: String = "2024-03-03") throws -> ProviderActivitySnapshot {
        let date = try ProviderCalendarDate(anchor)
        return try ProviderActivitySnapshot(providerID: .codex, buckets: offsets.map {
            try ActivityBucket(sourceDate: date.addingDays(-$0.0), reportedTokens: $0.1)
        }, capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
    }

    private func insights(_ offsets: [(Int, Int64)], period: ActivityInsightPeriod = .sevenDays,
                          anchor: String = "2024-03-03") throws -> ActivityInsights {
        guard case .available(let result) = ActivityInsights.query(try snapshot(offsets, anchor: anchor), period: period) else {
            throw ActivityFetchError.invalidData
        }
        return result
    }

    private func change(_ value: ActivityPeriodComparison) throws -> ActivityPeriodChange {
        guard case .available(let result) = value else { throw ActivityFetchError.invalidData }
        return result
    }

    func testCompleteSevenDaysAndAdjacentPreviousDates() throws {
        let result = try insights((0..<14).map { ($0, $0 < 7 ? 20 : 10) })
        XCTAssertEqual(result.current.coverage, ActivityCoverage(reportedDays: 7, expectedDays: 7))
        XCTAssertEqual(result.current.reportedTotal, .available(140))
        XCTAssertEqual(result.current.dailyReportedAverage,
                       .available(ActivityReportedAverage(reportedTotal: 140, reportedDays: 7)))
        XCTAssertEqual(result.current.startSourceDate.rawValue, "2024-02-26")
        XCTAssertEqual(result.previous?.startSourceDate.rawValue, "2024-02-19")
        XCTAssertEqual(result.previous?.endSourceDate.rawValue, "2024-02-25")
        let comparison = try change(result.comparison)
        XCTAssertEqual(comparison.delta, 70)
        XCTAssertEqual(comparison.direction, .increased)
        XCTAssertEqual(comparison.percentage, .roundedWholePercent(100))
    }

    func testPartialAverageUsesOnlyReportedDatesIncludingZero() throws {
        let result = try insights([(0, 0), (2, 10), (6, 0)])
        XCTAssertEqual(result.current.coverage, ActivityCoverage(reportedDays: 3, expectedDays: 7))
        XCTAssertEqual(result.current.reportedTotal, .available(10))
        guard case .available(let average) = result.current.dailyReportedAverage else { return XCTFail() }
        XCTAssertEqual(average.reportedDays, 3)
        XCTAssertEqual(average.roundedTokens, 3)
        XCTAssertEqual(result.comparison, .insufficientCoverage(
            current: result.current.coverage, previous: ActivityCoverage(reportedDays: 0, expectedDays: 7)))
    }

    func testCurrentCompletePreviousPartialSuppressesComparison() throws {
        let result = try insights((0..<11).map { ($0, 10) })
        XCTAssertEqual(result.comparison, .insufficientCoverage(
            current: ActivityCoverage(reportedDays: 7, expectedDays: 7),
            previous: ActivityCoverage(reportedDays: 4, expectedDays: 7)))
    }

    func testCurrentPartialPreviousCompleteSuppressesComparison() throws {
        let result = try insights((0..<14).filter { $0 != 3 }.map { ($0, 10) })
        XCTAssertEqual(result.comparison, .insufficientCoverage(
            current: ActivityCoverage(reportedDays: 6, expectedDays: 7),
            previous: ActivityCoverage(reportedDays: 7, expectedDays: 7)))
    }

    func testAllZeroIsReportedAverageAndUnchangedComparison() throws {
        let result = try insights((0..<14).map { ($0, 0) })
        guard case .available(let average) = result.current.dailyReportedAverage,
              case .available(let highest) = result.current.highestReportedDay else { return XCTFail() }
        XCTAssertEqual(average.roundedTokens, 0)
        XCTAssertEqual(average.reportedDays, 7)
        XCTAssertEqual(highest.bucket.reportedTokens, 0)
        XCTAssertEqual(highest.bucket.sourceDate.rawValue, "2024-03-03")
        XCTAssertEqual(highest.tiedReportedDays, 7)
        XCTAssertEqual(try change(result.comparison).direction, .unchanged)
        XCTAssertEqual(try change(result.comparison).percentage, .roundedWholePercent(0))
    }

    func testEmptyHasNoAnchorAndNeverFabricatesZeros() throws {
        for period in ActivityInsightPeriod.allCases {
            XCTAssertEqual(ActivityInsights.query(try snapshot([]), period: period), .noReportedData)
        }
    }

    func testAllMissingPreviousWindowHasTypedNoReportedData() throws {
        let result = try insights([(0, 42)])
        XCTAssertEqual(result.previous?.reportedTotal, .noReportedData)
        XCTAssertEqual(result.previous?.dailyReportedAverage, .noReportedData)
        XCTAssertEqual(result.previous?.highestReportedDay, .noReportedData)
        XCTAssertEqual(result.previous?.coverage.reportedDays, 0)
    }

    func testSingleReportedDayIsNotSevenDayAverage() throws {
        let result = try insights([(0, 123)])
        guard case .available(let average) = result.current.dailyReportedAverage else { return XCTFail() }
        XCTAssertEqual(average.roundedTokens, 123)
        XCTAssertEqual(average.reportedDays, 1)
        XCTAssertEqual(result.current.coverage.missingDays, 6)
    }

    func testHighestIncludesZerosAndLatestTieDateWithTieCount() throws {
        let result = try insights([(0, 0), (1, 50), (2, 50), (3, 20)])
        guard case .available(let highest) = result.current.highestReportedDay else { return XCTFail() }
        XCTAssertEqual(highest.bucket.reportedTokens, 50)
        XCTAssertEqual(highest.bucket.sourceDate.rawValue, "2024-03-02")
        XCTAssertEqual(highest.tiedReportedDays, 2)
    }

    func testAverageRoundingIsIntegerHalfUpAtInt64Boundary() throws {
        for (total, days, expected) in [(Int64(1), 2, Int64(1)), (1, 3, 0), (5, 2, 3),
                                       (.max, 1, .max), (.max, 2, 4_611_686_018_427_387_904)] {
            XCTAssertEqual(ActivityReportedAverage(reportedTotal: total, reportedDays: days).roundedTokens, expected)
        }
        let result = try insights([(0, .max), (1, 0)])
        guard case .available(let average) = result.current.dailyReportedAverage else { return XCTFail() }
        XCTAssertEqual(average.roundedTokens, 4_611_686_018_427_387_904)
    }

    func testCurrentSumOverflowDoesNotOverflowAverageOrHidePeak() throws {
        let result = try insights([(0, .max), (1, 1)])
        XCTAssertEqual(result.current.reportedTotal, .overflow)
        XCTAssertEqual(result.current.dailyReportedAverage, .overflow)
        guard case .available(let highest) = result.current.highestReportedDay else { return XCTFail() }
        XCTAssertEqual(highest.bucket.reportedTokens, .max)
    }

    func testPreviousOverflowIsIsolatedFromCurrentMetrics() throws {
        let result = try insights((0..<14).map { ($0, $0 < 7 ? 1 : .max) })
        XCTAssertEqual(result.current.reportedTotal, .available(7))
        XCTAssertEqual(result.previous?.reportedTotal, .overflow)
        XCTAssertEqual(result.comparison, .overflow)
    }

    func testCompleteCurrentOverflowSuppressesComparisonAndKeepsIndependentPeak() throws {
        let result = try insights((0..<14).map { ($0, $0 == 0 ? .max : $0 == 1 ? 1 : 0) })
        XCTAssertTrue(result.current.coverage.isComplete)
        XCTAssertTrue(result.previous!.coverage.isComplete)
        XCTAssertEqual(result.current.dailyReportedAverage, .overflow)
        XCTAssertEqual(result.comparison, .overflow)
        guard case .available(let peak) = result.current.highestReportedDay else { return XCTFail() }
        XCTAssertEqual(peak.bucket.reportedTokens, .max)
    }

    func testFullWidthPercentageCanFitDespiteIntermediateMultiplyExceedingInt64() throws {
        let exact = try change(insights((0..<14).map { ($0, $0 == 0 ? .max : $0 == 7 ? 100 : 0) }).comparison)
        XCTAssertEqual(exact.percentage, .roundedWholePercent(Int64.max - 100))
        let beyondInt64 = try change(insights((0..<14).map { ($0, $0 == 0 ? .max : $0 == 7 ? 99 : 0) }).comparison)
        XCTAssertEqual(beyondInt64.percentage, .overflow)
    }

    func testDeltaExtremesAndPercentageOverflowAreTyped() throws {
        let increase = try change(insights((0..<14).map { ($0, $0 == 0 ? .max : $0 == 7 ? 1 : 0) }).comparison)
        XCTAssertEqual(increase.delta, Int64.max - 1)
        XCTAssertEqual(increase.percentage, .overflow)
        let decrease = try change(insights((0..<14).map { ($0, $0 == 7 ? .max : 0) }).comparison)
        XCTAssertEqual(decrease.delta, -Int64.max)
        XCTAssertEqual(decrease.percentage, .roundedWholePercent(100))
    }

    func testZeroBaselineHasNoInventedPercentage() throws {
        let result = try insights((0..<14).map { ($0, $0 == 0 ? 5 : 0) })
        let comparison = try change(result.comparison)
        XCTAssertEqual(comparison.delta, 5)
        XCTAssertEqual(comparison.percentage, .zeroBaseline)
    }

    func testPercentageSmallChangesAndRoundingWithoutFalseUnchanged() throws {
        for (current, previous, expected) in [(Int64(101), Int64(100), ActivityPercentageChange.roundedWholePercent(1)),
                                               (1001, 1000, .lessThanOnePercent),
                                               (999, 1000, .lessThanOnePercent),
                                               (203, 200, .roundedWholePercent(2)),
                                               (197, 200, .roundedWholePercent(2))] {
            let result = try insights((0..<14).map { ($0, $0 == 0 ? current : $0 == 7 ? previous : 0) })
            XCTAssertEqual(try change(result.comparison).percentage, expected)
            XCTAssertEqual(try change(result.comparison).direction, current > previous ? .increased : .decreased)
        }
    }

    func testHighTotalsCompareExactlyWithoutSumOfBothPeriods() throws {
        let result = try insights((0..<14).map { ($0, ($0 == 0 || $0 == 7) ? .max : 0) })
        XCTAssertEqual(try change(result.comparison).delta, 0)
        XCTAssertEqual(try change(result.comparison).percentage, .roundedWholePercent(0))
    }

    func testFiftySixDaysCannotFabricatePreviousThirtyDays() throws {
        let result = try insights((0..<56).map { ($0, 1) }, period: .thirtyDays)
        XCTAssertEqual(result.current.coverage.reportedDays, 30)
        XCTAssertEqual(result.previous?.coverage.reportedDays, 26)
        XCTAssertEqual(result.previous?.coverage.missingDays, 4)
        XCTAssertEqual(result.comparison, .insufficientCoverage(
            current: result.current.coverage, previous: ActivityCoverage(reportedDays: 26, expectedDays: 30)))
    }

    func testSixtyCompleteDatesPermitThirtyDayComparison() throws {
        let result = try insights((0..<60).map { ($0, $0 < 30 ? 2 : 1) }, period: .thirtyDays)
        XCTAssertEqual(try change(result.comparison).percentage, .roundedWholePercent(100))
        XCTAssertEqual(result.previous?.coverage.reportedDays, 30)
    }

    func testSparseOldHistoryCannotBackfillRecentWindow() throws {
        let result = try insights([(0, 1), (2, 0), (20, 42), (60, 999), (200, 999)])
        XCTAssertEqual(result.current.coverage.reportedDays, 2)
        XCTAssertEqual(result.current.reportedTotal, .available(1))
        XCTAssertEqual(result.previous?.coverage.reportedDays, 0)
    }

    func testLeapMonthAndYearBoundariesUseProviderDates() throws {
        for (anchor, start, previousEnd) in [("2024-03-03", "2024-02-26", "2024-02-25"),
                                            ("2026-03-03", "2026-02-25", "2026-02-24"),
                                            ("2027-01-03", "2026-12-28", "2026-12-27")] {
            let result = try insights([(0, 0)], anchor: anchor)
            XCTAssertEqual(result.current.startSourceDate.rawValue, start)
            XCTAssertEqual(result.previous?.endSourceDate.rawValue, previousEnd)
        }
    }

    func testCivilDateUnderflowIsTypedAndPreviousFailureDoesNotHideCurrent() throws {
        XCTAssertEqual(ActivityInsights.query(try snapshot([(0, 1)], anchor: "0001-01-01"), period: .sevenDays),
                       .sourceDateOutOfRange)
        let result = try insights([(0, 1)], anchor: "0001-01-07")
        XCTAssertEqual(result.current.reportedTotal, .available(1))
        XCTAssertNil(result.previous)
        XCTAssertEqual(result.comparison, .sourceDateOutOfRange)
    }

    func testSingleSnapshotReplacementNeverAccumulatesHistory() throws {
        let first = try insights((0..<14).map { ($0, 1) })
        let replacement = try insights([(0, 2)])
        XCTAssertEqual(try change(first.comparison).direction, .unchanged)
        XCTAssertEqual(replacement.previous?.coverage.reportedDays, 0)
        XCTAssertEqual(replacement.current.reportedTotal, .available(2))
    }
}
