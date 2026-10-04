import Foundation

enum ClaudeContractError: Error, Equatable, Sendable {
    case invalidInput, inputTooLarge, invalidPercentage, invalidReset, invalidObservation
    case unverifiedVersion, unsupportedVersion
}

extension ClaudeContractError: ProviderStatusProvidingError {
    var providerStatus: ProviderStatus { .failed(.refreshFailed) }

    var runtimeAvailability: ProviderRuntimeAvailability {
        switch self {
        case .unsupportedVersion: .unavailable(.unsupportedVersion)
        case .unverifiedVersion: .unknown
        default: .unavailable(.invalidData)
        }
    }
}

struct ClaudeCodeVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        guard text.utf8.count <= 32 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), value <= 999_999 else { return nil }
            return value
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    var canonicalString: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum ClaudeVersionCompatibility: Equatable, Sendable {
    case missing, malformed, belowQuotaMinimum
    case quotaFieldsOnly, idleExpiryFix, future

    static func evaluate(_ text: String?) -> Self {
        guard let text else { return .missing }
        guard let version = ClaudeCodeVersion(text) else { return .malformed }
        if version < ClaudeCodeVersion("2.1.80")! { return .belowQuotaMinimum }
        if version < ClaudeCodeVersion("2.1.243")! { return .quotaFieldsOnly }
        if version <= ClaudeCodeVersion("2.1.246")! { return .idleExpiryFix }
        return .future
    }

    var permitsQuotaParsing: Bool {
        switch self {
        case .quotaFieldsOnly, .idleExpiryFix, .future: true
        case .missing, .malformed, .belowQuotaMinimum: false
        }
    }
}

enum ClaudeAccountContinuity: Equatable, Sendable {
    case unknown
}

struct ClaudeSampleProvenance: Equatable, Sendable {
    // Time received locally, supplied by the caller. No upstream fetched timestamp is known.
    let observedAt: Date
    let accountContinuity = ClaudeAccountContinuity.unknown
}

enum ClaudeResetObservation: Equatable, Sendable {
    case missing
    case reported(Date)
    case expired(Date)

    var date: Date? {
        switch self {
        case .missing: nil
        case .reported(let date), .expired(let date): date
        }
    }
}

struct ClaudeValidatedQuotaWindow: Equatable, Sendable {
    let usedPercentage: Double?
    let reset: ClaudeResetObservation

    var quotaAvailability: ProviderRuntimeAvailability {
        guard usedPercentage != nil else { return .unavailable(.awaitingSource) }
        if case .expired = reset { return .unavailable(.stale) }
        return .available
    }

    var resetAvailability: ProviderRuntimeAvailability {
        switch reset {
        case .missing: .unavailable(.awaitingSource)
        case .reported: .available
        case .expired: .unavailable(.stale)
        }
    }
}

struct ClaudeValidatedQuotaSample: Equatable, Sendable {
    let fiveHour: ClaudeValidatedQuotaWindow?
    let sevenDay: ClaudeValidatedQuotaWindow?
    let provenance: ClaudeSampleProvenance
    let version: ClaudeCodeVersion
    let compatibility: ClaudeVersionCompatibility

    func isStale(at now: Date) -> Bool {
        let age = now.timeIntervalSince(provenance.observedAt)
        return age > 15 * 60 || [fiveHour, sevenDay].compactMap { $0 }.contains {
            guard let reset = $0.reset.date else { return false }
            return reset <= now
        }
    }

    func availability(for capability: ProviderCapability, at now: Date) -> ProviderRuntimeAvailability {
        switch capability {
        case .quota, .resetTimeDisplay:
            guard !isStale(at: now) else { return .unavailable(.stale) }
            let windows = [fiveHour, sevenDay].compactMap { $0 }
            let hasValue = windows.contains {
                capability == .quota ? $0.usedPercentage != nil : $0.reset.date != nil
            }
            return hasValue ? .available : .unavailable(.awaitingSource)
        case .resetNotifications: return .unavailable(.continuityUnknown)
        default: return .unknown
        }
    }

    func snapshotDocument() -> ClaudeUsageSnapshotDocument {
        func project(_ window: ClaudeValidatedQuotaWindow?) -> ClaudeRateLimitWindow? {
            window.map { .init(usedPercentage: $0.usedPercentage,
                               resetsAt: $0.reset.date?.timeIntervalSince1970) }
        }
        return .init(schemaVersion: 1, capturedAt: provenance.observedAt,
                     claudeCodeVersion: version.canonicalString,
                     rateLimits: .init(fiveHour: project(fiveHour), sevenDay: project(sevenDay)))
    }
}

enum ClaudeQuotaValidation {
    // 2000-01-01...2100-01-01: a deliberately generous product range, not a plan duration.
    // It rejects milliseconds-shaped contemporary timestamps and Date/Int overflow.
    static let epochRange: ClosedRange<Double> = 946_684_800...4_102_444_800

    static func window(used: Double?, reset: Double?, now: Date) throws -> ClaudeValidatedQuotaWindow {
        if let used, !used.isFinite || !(0...100).contains(used) {
            throw ClaudeContractError.invalidPercentage
        }
        let observation: ClaudeResetObservation
        if let reset {
            guard reset.isFinite, epochRange.contains(reset) else {
                throw ClaudeContractError.invalidReset
            }
            let date = Date(timeIntervalSince1970: reset)
            observation = date <= now ? .expired(date) : .reported(date)
        } else {
            observation = .missing
        }
        return .init(usedPercentage: used, reset: observation)
    }

    static func sample(
        fiveHour: ClaudeRateLimitWindow?, sevenDay: ClaudeRateLimitWindow?,
        observedAt: Date, version: String?, now: Date
    ) throws -> ClaudeValidatedQuotaSample {
        guard observedAt.timeIntervalSince1970.isFinite,
              epochRange.contains(observedAt.timeIntervalSince1970),
              now.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince(now) <= 5 * 60 else {
            throw ClaudeContractError.invalidObservation
        }
        let compatibility = ClaudeVersionCompatibility.evaluate(version)
        guard compatibility != .belowQuotaMinimum else { throw ClaudeContractError.unsupportedVersion }
        guard compatibility.permitsQuotaParsing, let version, let parsed = ClaudeCodeVersion(version) else {
            throw ClaudeContractError.unverifiedVersion
        }
        func validate(_ input: ClaudeRateLimitWindow?) throws -> ClaudeValidatedQuotaWindow? {
            try input.map { try window(used: $0.usedPercentage, reset: $0.resetsAt, now: now) }
        }
        return try .init(fiveHour: validate(fiveHour), sevenDay: validate(sevenDay),
                         provenance: .init(observedAt: observedAt), version: parsed,
                         compatibility: compatibility)
    }
}
