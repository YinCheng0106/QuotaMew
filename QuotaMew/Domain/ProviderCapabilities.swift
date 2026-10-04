import Foundation

enum ProviderCapability: CaseIterable, Hashable, Sendable {
    case quota, resetTimeDisplay, resetNotifications
    case accountActivity, activityInsights, reserveBucket, broadAuthDiagnostic
}

enum ProviderCapabilitySupport: Equatable, Sendable {
    case supported, conditional, unsupported, unverified
}

enum ProviderRuntimeUnavailableReason: Equatable, Sendable {
    case notInstalled, notAuthenticated, awaitingSource, unsupportedVersion
    case unsupportedSchema, invalidData, permissionDenied, providerError
    case stale, continuityUnknown
}

enum ProviderRuntimeAvailability: Equatable, Sendable {
    case available
    case unknown
    case unavailable(ProviderRuntimeUnavailableReason)
}

struct ProviderCapabilityEnablement: Equatable, Sendable {
    let providerEnabled: Bool
    let featureEnabled: Bool
}

struct ProviderCapabilityAssessment: Equatable, Sendable {
    let support: ProviderCapabilitySupport
    let runtime: ProviderRuntimeAvailability
    let enablement: ProviderCapabilityEnablement

    // A conditional contract still requires independently established runtime evidence.
    var isUsable: Bool {
        (support == .supported || support == .conditional)
            && runtime == .available
            && enablement.providerEnabled && enablement.featureEnabled
    }
}

struct ProviderCapabilities: Equatable, Sendable {
    let providerID: ProviderID

    func support(for capability: ProviderCapability) -> ProviderCapabilitySupport {
        switch (providerID, capability) {
        case (.codex, .broadAuthDiagnostic): .unverified
        case (.codex, _): .supported
        case (.claude, .quota), (.claude, .resetTimeDisplay), (.claude, .broadAuthDiagnostic):
            .conditional
        case (.claude, _): .unsupported
        }
    }

    func assessment(
        for capability: ProviderCapability,
        runtime: ProviderRuntimeAvailability,
        enablement: ProviderCapabilityEnablement
    ) -> ProviderCapabilityAssessment {
        .init(support: support(for: capability), runtime: runtime, enablement: enablement)
    }

    // Unknown personal-account continuity forbids carrying failed Claude samples forward.
    var retainsUnavailableQuotaSample: Bool { providerID == .codex }
}

extension ProviderID {
    var capabilities: ProviderCapabilities { .init(providerID: self) }
}
