import Foundation
import XCTest
@testable import QuotaMew

final class ActivityProjectionTests: XCTestCase {
    private func snapshot(_ values: [(String, Int64)]) throws -> ProviderActivitySnapshot {
        try ProviderActivitySnapshot(providerID: .codex, buckets: values.map {
            try ActivityBucket(sourceDate: ProviderCalendarDate($0.0), reportedTokens: $0.1)
        }, capturedAt: Date(timeIntervalSince1970: 1), source: .synthetic)
    }

    func testGregorianBoundariesAndDistance() throws {
        for (before, after) in [
            ("2026-01-31", "2026-02-01"), ("2026-12-31", "2027-01-01"),
            ("2024-02-28", "2024-02-29"), ("2024-02-29", "2024-03-01"),
            ("2026-02-28", "2026-03-01"), ("1900-02-28", "1900-03-01"),
            ("2000-02-28", "2000-02-29"), ("0001-01-01", "0001-01-02"),
            ("9999-12-30", "9999-12-31")
        ] {
            let first = try ProviderCalendarDate(before), second = try ProviderCalendarDate(after)
            XCTAssertEqual(try first.addingDays(1), second)
            XCTAssertEqual(try second.addingDays(-1), first)
            XCTAssertEqual(first.distance(to: second), 1)
            XCTAssertEqual(second.distance(to: first), -1)
        }
        XCTAssertEqual(try ProviderCalendarDate("2024-01-01").distance(to: ProviderCalendarDate("2025-01-01")), 366)
        XCTAssertEqual(try ProviderCalendarDate("2025-01-01").distance(to: ProviderCalendarDate("2026-01-01")), 365)
    }

    func testOrdinalRoundTripAcrossAllSupportedMonthBoundaries() throws {
        // All month edges across the supported domain, including century rules.
        for year in 1...9999 {
            for month in 1...12 {
                let yearText = String(repeating: "0", count: 4 - String(year).count) + String(year)
                let monthText = month < 10 ? "0\(month)" : String(month)
                let first = try ProviderCalendarDate("\(yearText)-\(monthText)-01")
                XCTAssertEqual(try first.addingDays(0), first)
                if first.ordinal > 0 {
                    XCTAssertEqual(try first.addingDays(-1).addingDays(1), first)
                }
            }
        }
    }

    func testArithmeticBoundsAndTimezoneFreeStrategy() throws {
        let first = try ProviderCalendarDate("0001-01-01")
        let last = try ProviderCalendarDate("9999-12-31")
        XCTAssertEqual(first.ordinal, 0)
        XCTAssertEqual(last.ordinal, 3_652_058)
        XCTAssertEqual(try first.addingDays(last.ordinal), last)
        XCTAssertThrowsError(try first.addingDays(-1))
        XCTAssertThrowsError(try last.addingDays(1))
        XCTAssertThrowsError(try last.addingDays(Int.max))
        XCTAssertThrowsError(try first.addingDays(Int.min))
        // Fixed civil results require no ambient calendar, locale or clock input.
        XCTAssertEqual(try ProviderCalendarDate("2026-10-07").addingDays(-6).rawValue, "2026-10-01")
        XCTAssertThrowsError(try ActivityProjection.query(snapshot([("0001-01-07", 1)])))
    }

    func testLatestOrderedShuffledExplicitZeroAndEmpty() throws {
        let values: [(String, Int64)] = [("2026-10-01", 4), ("2026-10-02", 8), ("2026-10-07", 0)]
        let ordered = try XCTUnwrap(ActivityProjection.query(snapshot(values)))
        let shuffled = try XCTUnwrap(ActivityProjection.query(snapshot([values[2], values[0], values[1]])))
        XCTAssertEqual(ordered, shuffled)
        XCTAssertEqual(ordered.latestReported.sourceDate.rawValue, "2026-10-07")
        XCTAssertEqual(ordered.latestReported.reportedTokens, 0)
        XCTAssertEqual(ordered.capturedAt, Date(timeIntervalSince1970: 1))
        XCTAssertNil(try ActivityProjection.query(snapshot([])))
    }

    func testFourOfSevenRegressionDoesNotBackfillOrInventZeros() throws {
        let projection = try XCTUnwrap(ActivityProjection.query(snapshot([
            ("2026-09-28", 900), ("2026-09-30", 800),
            ("2026-10-01", 1), ("2026-10-02", 2), ("2026-10-04", 0), ("2026-10-07", 7)
        ]))).sevenDays
        XCTAssertEqual(projection.anchorSourceDate.rawValue, "2026-10-07")
        XCTAssertEqual(projection.startSourceDate.rawValue, "2026-10-01")
        XCTAssertEqual(projection.endSourceDate.rawValue, "2026-10-07")
        XCTAssertEqual(projection.coverage, ActivityCoverage(reportedDays: 4, expectedDays: 7))
        XCTAssertEqual(projection.coverage.missingDays, 3)
        XCTAssertFalse(projection.coverage.isComplete)
        XCTAssertEqual(projection.reportedTotal, 10)
        XCTAssertNil(projection.completePeriodTotal)
        XCTAssertEqual(projection.points.map(\.sourceDate.rawValue), (1...7).map { "2026-10-0\($0)" })
        XCTAssertEqual(projection.points[2], .missing(try ProviderCalendarDate("2026-10-03")))
        guard case .reported(let zero) = projection.points[3] else { return XCTFail("Zero must be reported") }
        XCTAssertEqual(zero.reportedTokens, 0)
    }

    func testSevenDaysCompleteSingleGapAndAllZeros() throws {
        let complete = (1...7).map { ("2026-10-0\($0)", Int64(0)) }
        let full = try XCTUnwrap(ActivityProjection.query(snapshot(complete))).sevenDays
        XCTAssertTrue(full.coverage.isComplete)
        XCTAssertEqual(full.coverage.missingDays, 0)
        XCTAssertEqual(full.reportedTotal, 0)
        XCTAssertEqual(full.completePeriodTotal, 0)
        let gap = try XCTUnwrap(ActivityProjection.query(snapshot(complete.filter { $0.0 != "2026-10-04" }))).sevenDays
        XCTAssertEqual(gap.coverage.reportedDays, 6)
        XCTAssertEqual(gap.coverage.missingDays, 1)
        XCTAssertNil(gap.completePeriodTotal)
    }

    func testThirtyDaysAcrossMonthYearAndLeapDay() throws {
        for (anchorText, startText) in [
            ("2026-10-07", "2026-09-08"), ("2027-01-07", "2026-12-09"),
            ("2024-03-15", "2024-02-15"), ("2026-03-15", "2026-02-14")
        ] {
            let anchor = try ProviderCalendarDate(anchorText)
            let values = try (-29...0).map { (try anchor.addingDays($0).rawValue, Int64(1)) }
            let full = try XCTUnwrap(ActivityProjection.query(snapshot(values))).thirtyDays
            XCTAssertEqual(full.startSourceDate.rawValue, startText)
            XCTAssertEqual(full.coverage.reportedDays, 30)
            XCTAssertTrue(full.coverage.isComplete)
            XCTAssertEqual(full.reportedTotal, 30)
            XCTAssertEqual(full.completePeriodTotal, 30)
            let partial = try XCTUnwrap(ActivityProjection.query(snapshot([values[0], values[29]]))).thirtyDays
            XCTAssertEqual(partial.coverage.missingDays, 28)
            XCTAssertEqual(partial.reportedTotal, 2)
            XCTAssertNil(partial.completePeriodTotal)
        }
    }

    func testCheckedSumAtLimitAndOverflowInEitherWindow() throws {
        let valid = try XCTUnwrap(ActivityProjection.query(snapshot([("2026-10-01", Int64.max - 1), ("2026-10-07", 1)])))
        XCTAssertEqual(valid.sevenDays.reportedTotal, Int64.max)
        XCTAssertThrowsError(try ActivityProjection.query(snapshot([("2026-10-01", Int64.max), ("2026-10-07", 1)]))) {
            XCTAssertEqual($0 as? ActivityFetchError, .invalidData)
        }
        // Seven-day sum fits; thirty-day sum still rejects the aggregate projection.
        XCTAssertThrowsError(try ActivityProjection.query(snapshot([("2026-09-08", Int64.max), ("2026-10-07", 1)])))
    }
}
