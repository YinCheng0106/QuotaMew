import Foundation

struct ActivityCoverage: Equatable, Sendable {
    let reportedDays: Int
    let expectedDays: Int
    var missingDays: Int { expectedDays - reportedDays }
    // Completeness means dates were reported, not that provider bucket values are final.
    var isComplete: Bool { reportedDays == expectedDays }
}

enum ActivityPresentationPoint: Equatable, Sendable {
    case reported(ActivityBucket)
    case missing(ProviderCalendarDate)

    var sourceDate: ProviderCalendarDate {
        switch self {
        case .reported(let bucket): bucket.sourceDate
        case .missing(let date): date
        }
    }
}

struct ActivityWindowProjection: Equatable, Sendable {
    let anchorSourceDate: ProviderCalendarDate
    let startSourceDate: ProviderCalendarDate
    let endSourceDate: ProviderCalendarDate
    let coverage: ActivityCoverage
    let reportedTotal: Int64
    let points: [ActivityPresentationPoint]
    /// Only date coverage is complete; provider completeness is still unknown.
    var completePeriodTotal: Int64? { coverage.isComplete ? reportedTotal : nil }
}

/// Pure bounded queries over one current response. No local "today" or history.
struct ActivityProjection: Equatable, Sendable {
    let latestReported: ActivityBucket
    let sevenDays: ActivityWindowProjection
    let thirtyDays: ActivityWindowProjection
    let capturedAt: Date
    let source: ActivitySource

    static func query(_ snapshot: ProviderActivitySnapshot) throws -> Self? {
        guard let latest = snapshot.buckets.last else { return nil }
        let buckets = Dictionary(uniqueKeysWithValues: snapshot.buckets.map { ($0.sourceDate, $0) })
        func window(days: Int) throws -> ActivityWindowProjection {
            let start = try latest.sourceDate.addingDays(1 - days)
            var points: [ActivityPresentationPoint] = []
            var reportedDays = 0
            var reportedTotal: Int64 = 0
            for offset in 0..<days {
                let date = try start.addingDays(offset)
                if let bucket = buckets[date] {
                    let (sum, overflow) = reportedTotal.addingReportingOverflow(bucket.reportedTokens)
                    guard !overflow else { throw ActivityFetchError.invalidData }
                    reportedTotal = sum
                    reportedDays += 1
                    points.append(.reported(bucket))
                } else {
                    points.append(.missing(date))
                }
            }
            return ActivityWindowProjection(
                anchorSourceDate: latest.sourceDate, startSourceDate: start,
                endSourceDate: latest.sourceDate,
                coverage: ActivityCoverage(reportedDays: reportedDays, expectedDays: days),
                reportedTotal: reportedTotal, points: points
            )
        }
        return try Self(latestReported: latest, sevenDays: window(days: 7),
                        thirtyDays: window(days: 30), capturedAt: snapshot.capturedAt, source: snapshot.source)
    }
}
