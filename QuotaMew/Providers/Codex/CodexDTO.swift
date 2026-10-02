import Foundation

struct CodexRateLimitsResult: Decodable, Equatable, Sendable {
    let rateLimits: CodexRateLimitBucket?
    let rateLimitsByLimitId: [String: CodexRateLimitBucket]?
}

struct CodexRateLimitBucket: Decodable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

struct CodexRateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}

// Minimal account/usage/read wire projection. The activity adapter validates semantics.
// Summary, threadUsage and unknown fields are deliberately not retained.
struct CodexAccountUsageTransportResult: Decodable, Equatable, Sendable {
    struct DailyBucket: Decodable, Equatable, Sendable {
        let startDate: String
        let tokens: Int64
    }

    let dailyUsageBuckets: [DailyBucket]?
    let hasDailyUsageBuckets: Bool

    private enum CodingKeys: String, CodingKey { case dailyUsageBuckets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasDailyUsageBuckets = container.contains(.dailyUsageBuckets)
        if !hasDailyUsageBuckets {
            dailyUsageBuckets = nil
            return
        }
        if try container.decodeNil(forKey: .dailyUsageBuckets) {
            dailyUsageBuckets = nil
            return
        }
        var collection = try container.nestedUnkeyedContainer(forKey: .dailyUsageBuckets)
        var buckets: [DailyBucket] = []
        while !collection.isAtEnd {
            guard buckets.count < ProviderActivitySnapshot.maximumBucketCount else {
                throw DecodingError.dataCorruptedError(in: collection, debugDescription: "Daily bucket capacity exceeded")
            }
            buckets.append(try collection.decode(DailyBucket.self))
        }
        dailyUsageBuckets = buckets
    }
}
