import Foundation

struct ClaudeUsageSnapshotDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let capturedAt: Date
    let claudeCodeVersion: String?
    let rateLimits: ClaudeRateLimits
}

struct ClaudeRateLimits: Codable, Equatable, Sendable {
    let fiveHour: ClaudeRateLimitWindow?
    let sevenDay: ClaudeRateLimitWindow?
}

struct ClaudeRateLimitWindow: Codable, Equatable, Sendable {
    let usedPercentage: Double?
    let resetsAt: TimeInterval?
}
