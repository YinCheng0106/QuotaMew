import Foundation

// Official stdin contract. Never decode it as the QuotaMew-owned camelCase document.
// Only the two subscription windows are modeled; no raw/private fields survive decoding.
private struct ClaudeStatusLineInput: Decodable {
    let version: String?
    let rateLimits: Limits?
    enum CodingKeys: String, CodingKey { case version; case rateLimits = "rate_limits" }

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
        _ data: Data, observedAt: Date, claudeCodeVersion: String? = nil, now: Date
    ) throws -> ClaudeValidatedQuotaSample {
        guard data.count <= maximumBytes else { throw ClaudeContractError.inputTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw ClaudeContractError.invalidInput }
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
            observedAt: observedAt, version: claudeCodeVersion ?? input.version, now: now
        )
    }
}
