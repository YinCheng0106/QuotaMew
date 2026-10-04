import Foundation

enum UsageSampleValidity: Equatable, Sendable {
    case unexpired, stale
}

struct ProviderUsageSnapshot: Equatable, Sendable {
    let providerID: ProviderID
    let windows: [UsageWindow]
    let capturedAt: Date
    let source: UsageSource
    var validity: UsageSampleValidity = .unexpired
}
