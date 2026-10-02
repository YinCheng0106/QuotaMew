import Foundation

enum ActivityFetchError: Error, Equatable, Sendable {
    case fetchFailed
    case timedOut
    case invalidData
    case limitExceeded
    case providerUnavailable
}

/// Static provenance only. No provider-controlled labels or metadata.
enum ActivitySource: Equatable, Sendable {
    case codexAccountUsage
    case synthetic

    enum Scope: Sendable { case accountAggregate }
    enum Basis: Sendable { case providerReportedTotal }
    enum Confidence: Sendable { case providerReported, synthetic }

    var scope: Scope { .accountAggregate }
    var basis: Basis { .providerReportedTotal }
    var confidence: Confidence { self == .synthetic ? .synthetic : .providerReported }
}

struct ActivityBucket: Equatable, Sendable {
    let sourceDate: ProviderCalendarDate
    let reportedTokens: Int64

    init(sourceDate: ProviderCalendarDate, reportedTokens: Int64) throws {
        guard reportedTokens >= 0 else { throw ActivityFetchError.invalidData }
        self.sourceDate = sourceDate
        self.reportedTokens = reportedTokens
    }
}

/// One successful source read. Missing dates remain absent; no history is accumulated.
struct ProviderActivitySnapshot: Equatable, Sendable {
    // Engineering capacity, not a provider retention guarantee. Count before deduplication.
    static let maximumBucketCount = 366

    let providerID: ProviderID
    let buckets: [ActivityBucket]
    let capturedAt: Date
    let source: ActivitySource

    init(providerID: ProviderID, buckets: [ActivityBucket], capturedAt: @autoclosure () -> Date,
         source: ActivitySource) throws {
        guard buckets.count <= Self.maximumBucketCount else { throw ActivityFetchError.limitExceeded }
        var unique: [ProviderCalendarDate: ActivityBucket] = [:]
        for bucket in buckets {
            if let previous = unique[bucket.sourceDate], previous != bucket {
                throw ActivityFetchError.invalidData
            }
            unique[bucket.sourceDate] = bucket
        }
        self.providerID = providerID
        self.buckets = unique.values.sorted { $0.sourceDate < $1.sourceDate }
        self.capturedAt = capturedAt()
        self.source = source
    }
}

enum NoDailyBucketsReason: Equatable, Sendable {
    case missingCollection
    case nullCollection
    case emptyCollection
}

enum ActivityFetchResult: Equatable, Sendable {
    case snapshot(ProviderActivitySnapshot)
    case noDailyBuckets(source: ActivitySource, capturedAt: Date, reason: NoDailyBucketsReason)
    case unsupported
}
