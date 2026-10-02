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

// Minimal account/usage/read wire projection. M1 owns semantic validation/mapping.
// Summary, threadUsage and unknown fields are deliberately not retained.
struct CodexAccountUsageTransportResult: Decodable, Equatable, Sendable {
    struct DailyBucket: Decodable, Equatable, Sendable {
        let startDate: String
        let tokens: Int64
    }

    let dailyUsageBuckets: [DailyBucket]?
}
