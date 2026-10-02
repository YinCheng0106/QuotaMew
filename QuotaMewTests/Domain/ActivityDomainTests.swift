import Foundation
import XCTest
@testable import QuotaMew

final class ActivityDomainTests: XCTestCase {
    func testValidDatesPreserveSourceAndGregorianLeapYears() throws {
        for value in ["0001-01-01", "2026-10-01", "2024-02-29", "2000-02-29", "9999-12-31"] {
            XCTAssertEqual(try ProviderCalendarDate(value).rawValue, value)
        }
    }

    func testInvalidDatesAreRejectedWithoutNormalization() {
        for value in ["", "../../etc", "2026-02-29", "1900-02-29", "0000-01-01", "2026-13-01",
                      "2026-00-01", "2026-04-31", "2026-01-00", "2026-01-32", "2026-1-01",
                      "2026-01-1", "2026-10-01Z", " 2026-10-01", "２０２６-10-01", "2026/10/01"] {
            XCTAssertThrowsError(try ProviderCalendarDate(value)) {
                XCTAssertEqual($0 as? ActivityFetchError, .invalidData)
            }
        }
    }

    func testLexicalOrderMatchesCalendarOrder() throws {
        let values = ["2026-01-01", "2024-03-01", "2024-02-29", "2025-12-31"]
        XCTAssertEqual(try values.map(ProviderCalendarDate.init).sorted().map(\.rawValue),
                       ["2024-02-29", "2024-03-01", "2025-12-31", "2026-01-01"])
    }

    func testTokensZeroPositiveAndInt64MaximumAreValid() throws {
        for count: Int64 in [0, 1, Int64.max] {
            XCTAssertEqual(try bucket("2026-10-01", count).reportedTokens, count)
        }
        XCTAssertNil(Int64("9223372036854775808"), "Overflow cannot enter the integer domain")
    }

    func testNegativeTokensAreRejected() {
        XCTAssertThrowsError(try bucket("2026-10-01", -1)) {
            XCTAssertEqual($0 as? ActivityFetchError, .invalidData)
        }
    }

    func testSnapshotsSortDeduplicateAndPreserveGapsAndEquality() throws {
        let first = try bucket("2026-10-01", 0)
        let third = try bucket("2026-10-03", 5)
        let capture = Date(timeIntervalSince1970: 123)
        let a = try ProviderActivitySnapshot(providerID: .codex, buckets: [third, first, first],
                                             capturedAt: capture, source: .synthetic)
        let b = try ProviderActivitySnapshot(providerID: .codex, buckets: [first, third],
                                             capturedAt: capture, source: .synthetic)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.buckets.map(\.sourceDate.rawValue), ["2026-10-01", "2026-10-03"])
        XCTAssertEqual(a.buckets.first?.reportedTokens, 0)
        XCTAssertNotEqual(a, try ProviderActivitySnapshot(providerID: .codex, buckets: [first, third],
                             capturedAt: capture.addingTimeInterval(1), source: .synthetic))
    }

    func testConflictingDatesRejectEntireSnapshot() throws {
        XCTAssertThrowsError(try ProviderActivitySnapshot(providerID: .codex,
            buckets: [bucket("2026-10-01", 0), bucket("2026-10-01", 1)],
            capturedAt: .distantPast, source: .synthetic)) {
            XCTAssertEqual($0 as? ActivityFetchError, .invalidData)
        }
    }

    func testCapacityAppliesBeforeDeduplicationAndCapture() throws {
        let value = try bucket("2026-10-01", 0)
        let valid = try ProviderActivitySnapshot(providerID: .codex,
            buckets: Array(repeating: value, count: 366), capturedAt: .distantPast, source: .synthetic)
        XCTAssertEqual(valid.buckets.count, 1)
        func forbiddenCapture() -> Date { XCTFail("Invalid candidates must not capture"); return .distantPast }
        XCTAssertThrowsError(try ProviderActivitySnapshot(providerID: .codex,
            buckets: Array(repeating: value, count: 367), capturedAt: forbiddenCapture(), source: .synthetic)) {
            XCTAssertEqual($0 as? ActivityFetchError, .limitExceeded)
        }
    }

    func testEmptySnapshotDoesNotFillDates() throws {
        XCTAssertTrue(try ProviderActivitySnapshot(providerID: .codex, buckets: [],
            capturedAt: .distantPast, source: .synthetic).buckets.isEmpty)
    }

    private func bucket(_ date: String, _ tokens: Int64) throws -> ActivityBucket {
        try ActivityBucket(sourceDate: ProviderCalendarDate(date), reportedTokens: tokens)
    }
}
