import Foundation

// Official stdin contract. Never decode it as the QuotaMew-owned camelCase document.
// Only the two subscription windows are modeled; no raw/private fields survive decoding.
private struct ClaudeStatusLineInput: Decodable {
    let rateLimits: Limits?
    enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }

    struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
        var snapshotWindow: ClaudeRateLimitWindow {
            .init(usedPercentage: usedPercentage, resetsAt: resetsAt)
        }
    }
}

enum ClaudeStatusLineParser {
    static let maximumBytes = 16_384

    static func parse(
        _ data: Data, observedAt: Date, claudeCodeVersion: String?, now: Date
    ) throws -> ClaudeValidatedQuotaSample {
        guard data.count <= maximumBytes else { throw ClaudeContractError.inputTooLarge }
        let input: ClaudeStatusLineInput
        do {
            input = try JSONDecoder().decode(ClaudeStatusLineInput.self, from: data)
        } catch {
            // DecodingError includes keys and values; it must not escape the pre-output boundary.
            throw ClaudeContractError.invalidInput
        }
        return try ClaudeQuotaValidation.sample(
            fiveHour: input.rateLimits?.fiveHour?.snapshotWindow,
            sevenDay: input.rateLimits?.sevenDay?.snapshotWindow,
            observedAt: observedAt, version: claudeCodeVersion, now: now
        )
    }
}
