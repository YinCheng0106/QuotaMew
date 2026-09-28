import Foundation

struct DiagnosticVersion: Equatable, Sendable {
    let value: String

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.-+")
        guard value.first?.isNumber == true,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.value = value
    }
}

enum DiagnosticArchitecture: String, Equatable, Sendable {
    case arm64
    case x86_64
    case unknown

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }
}

enum DiagnosticAvailability: String, Equatable, Sendable {
    case loading
    case available
    case disabled
    case stale
    case notConfigured
    case notInstalled
    case unsupportedAuthentication
    case failed
}

enum DiagnosticRuntimeSource: String, Equatable, Sendable {
    case chatGPTApplication
    case legacyCodexApplication
    case standaloneCodex
    case localSnapshot
    case notDetected
    case notApplicable
    case unknown

    var englishLabel: String {
        switch self {
        case .chatGPTApplication: "ChatGPT.app"
        case .legacyCodexApplication: "Codex.app"
        case .standaloneCodex: "Standalone Codex"
        case .localSnapshot: "Local snapshot"
        case .notDetected: "Not detected"
        case .notApplicable: "Not applicable"
        case .unknown: "Unknown"
        }
    }
}

enum DiagnosticHostApplication: String, Equatable, Sendable {
    case chatGPT
    case codex

    var englishLabel: String {
        switch self {
        case .chatGPT: "ChatGPT.app"
        case .codex: "Codex.app"
        }
    }
}

struct DiagnosticHostApplicationState: Equatable, Sendable {
    let application: DiagnosticHostApplication
    let isDetected: Bool
    let version: DiagnosticVersion?
}

enum DiagnosticCompatibilityStatus: String, Equatable, Sendable {
    case compatible
    case unverified
    case unavailable
    case notApplicable
    case unknown
}

enum DiagnosticAppServerState: String, Equatable, Sendable {
    case connected
    case disconnected
    case notStarted
    case launchFailed
    case notApplicable
    case unknown
}

enum DiagnosticRefreshOutcome: String, Equatable, Sendable {
    case successful
    case failed
    case inProgress
    case disabled
    case notAttempted
}

enum DiagnosticFailureCategory: String, Equatable, Sendable {
    case runtimeNotDetected
    case runtimeNotExecutable
    case appServerLaunchFailed
    case appServerConnectionFailed
    case rpcUnavailable
    case usageUnavailable
    case refreshFailed
    case providerDisabled
    case notConfigured
}

struct ProviderRuntimeDiagnostic: Equatable, Sendable {
    let hostApplication: DiagnosticHostApplicationState?
    let runtimeSource: DiagnosticRuntimeSource
    let runtimeDetected: Bool?
    let compatibilityStatus: DiagnosticCompatibilityStatus
    let appServerState: DiagnosticAppServerState
    let lastFailureCategory: DiagnosticFailureCategory?

    static let unknown = ProviderRuntimeDiagnostic(
        hostApplication: nil,
        runtimeSource: .unknown,
        runtimeDetected: nil,
        compatibilityStatus: .unknown,
        appServerState: .notApplicable,
        lastFailureCategory: nil
    )
}

struct ProviderDiagnosticContext: Equatable, Sendable {
    let providerID: ProviderID
    let isEnabled: Bool
    let runtime: ProviderRuntimeDiagnostic
}

struct ProviderDiagnosticSnapshot: Identifiable, Equatable, Sendable {
    let providerID: ProviderID
    let isEnabled: Bool
    let availability: DiagnosticAvailability
    let hostApplication: DiagnosticHostApplicationState?
    let runtimeSource: DiagnosticRuntimeSource
    let runtimeDetected: Bool?
    let compatibilityStatus: DiagnosticCompatibilityStatus
    let appServerState: DiagnosticAppServerState
    let refreshOutcome: DiagnosticRefreshOutcome
    let lastRefreshAttemptAt: Date?
    let lastSuccessfulRefreshAt: Date?
    let lastFailureCategory: DiagnosticFailureCategory?
    let usageMetadataAvailable: Bool
    let resetMetadataAvailable: Bool

    var id: ProviderID { providerID }
}

struct CompatibilityDiagnosticEnvironment: Equatable, Sendable {
    let appVersion: DiagnosticVersion?
    let buildNumber: DiagnosticVersion?
    let macOSVersion: DiagnosticVersion?
    let architecture: DiagnosticArchitecture

    static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Self {
        let version = processInfo.operatingSystemVersion
        return Self(
            appVersion: DiagnosticVersion(
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ),
            buildNumber: DiagnosticVersion(
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ),
            macOSVersion: DiagnosticVersion(
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            ),
            architecture: .current
        )
    }
}

struct CompatibilityDiagnosticsSnapshot: Equatable, Sendable {
    let appVersion: DiagnosticVersion?
    let buildNumber: DiagnosticVersion?
    let macOSVersion: DiagnosticVersion?
    let architecture: DiagnosticArchitecture
    let providers: [ProviderDiagnosticSnapshot]

    init(
        environment: CompatibilityDiagnosticEnvironment,
        providerStates: [ProviderState],
        providerContexts: [ProviderDiagnosticContext],
        lastRefreshAttemptAt: Date?
    ) {
        appVersion = environment.appVersion
        buildNumber = environment.buildNumber
        macOSVersion = environment.macOSVersion
        architecture = environment.architecture

        let statesByProvider = Dictionary(
            providerStates.map { ($0.providerID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let contextsByProvider = Dictionary(
            providerContexts.map { ($0.providerID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var seenProviderIDs: Set<ProviderID> = []
        let providerIDs = (providerStates.map(\.providerID) + providerContexts.map(\.providerID))
            .filter { seenProviderIDs.insert($0).inserted }
        providers = providerIDs.map { providerID in
            let state = statesByProvider[providerID] ?? .loading(providerID)
            let context = contextsByProvider[providerID] ?? ProviderDiagnosticContext(
                providerID: providerID,
                isEnabled: state.status != .disabled,
                runtime: .unknown
            )
            return Self.providerSnapshot(
                state: state,
                context: context,
                lastRefreshAttemptAt: lastRefreshAttemptAt
            )
        }
    }

    private static func providerSnapshot(
        state: ProviderState,
        context: ProviderDiagnosticContext,
        lastRefreshAttemptAt: Date?
    ) -> ProviderDiagnosticSnapshot {
        let windows = state.snapshot?.windows ?? []
        let inferredFailure = failureCategory(for: state.status)
        return ProviderDiagnosticSnapshot(
            providerID: state.providerID,
            isEnabled: context.isEnabled,
            availability: availability(for: state.status),
            hostApplication: context.runtime.hostApplication,
            runtimeSource: context.runtime.runtimeSource,
            runtimeDetected: context.runtime.runtimeDetected,
            compatibilityStatus: context.runtime.compatibilityStatus,
            appServerState: context.runtime.appServerState,
            refreshOutcome: refreshOutcome(
                for: state.status,
                lastRefreshAttemptAt: lastRefreshAttemptAt
            ),
            lastRefreshAttemptAt: context.isEnabled ? lastRefreshAttemptAt : nil,
            lastSuccessfulRefreshAt: state.snapshot?.capturedAt,
            lastFailureCategory: context.runtime.lastFailureCategory ?? inferredFailure,
            usageMetadataAvailable: windows.contains { $0.usedPercentage != nil },
            resetMetadataAvailable: windows.contains { $0.resetAt != nil }
        )
    }

    private static func availability(for status: ProviderStatus) -> DiagnosticAvailability {
        switch status {
        case .loading: .loading
        case .available: .available
        case .disabled: .disabled
        case .stale: .stale
        case .notConfigured: .notConfigured
        case .notInstalled: .notInstalled
        case .unsupportedAuthentication: .unsupportedAuthentication
        case .failed: .failed
        }
    }

    private static func refreshOutcome(
        for status: ProviderStatus,
        lastRefreshAttemptAt: Date?
    ) -> DiagnosticRefreshOutcome {
        switch status {
        case .available: .successful
        case .loading: lastRefreshAttemptAt == nil ? .notAttempted : .inProgress
        case .disabled: .disabled
        case .stale, .notConfigured, .notInstalled, .unsupportedAuthentication, .failed: .failed
        }
    }

    private static func failureCategory(
        for status: ProviderStatus
    ) -> DiagnosticFailureCategory? {
        switch status {
        case .disabled: .providerDisabled
        case .notConfigured: .notConfigured
        case .notInstalled: .runtimeNotDetected
        case .failed(.runtimeLaunchFailed): .appServerLaunchFailed
        case .failed(.usageUnavailable): .usageUnavailable
        case .failed(.refreshFailed), .stale, .unsupportedAuthentication: .refreshFailed
        case .loading, .available: nil
        }
    }
}

enum CompatibilityDiagnosticsReport {
    static func make(from snapshot: CompatibilityDiagnosticsSnapshot) -> String {
        var lines = [
            "QuotaMew Diagnostics",
            "",
            "QuotaMew",
            "Version: \(version(snapshot.appVersion))",
            "Build: \(version(snapshot.buildNumber))",
            "",
            "System",
            "macOS: \(version(snapshot.macOSVersion))",
            "Architecture: \(snapshot.architecture.rawValue)",
        ]

        for provider in snapshot.providers {
            lines.append(contentsOf: [
                "",
                provider.providerID.displayName,
                "Enabled: \(yesNo(provider.isEnabled))",
                "Availability: \(englishAvailability(provider))",
            ])
            if let application = provider.hostApplication {
                lines.append(
                    "\(application.application.englishLabel) Installed: \(yesNo(application.isDetected))"
                )
                if application.isDetected {
                    lines.append(
                        "\(application.application.englishLabel) Version: \(version(application.version))"
                    )
                }
            }
            lines.append(contentsOf: [
                "Runtime Source: \(provider.runtimeSource.englishLabel)",
                "Runtime Detected: \(yesNoUnknown(provider.runtimeDetected))",
                "Runtime Compatibility: \(englishCompatibility(provider.compatibilityStatus))",
                "App Server: \(englishAppServer(provider.appServerState))",
                "Usage Available: \(yesNo(provider.usageMetadataAvailable))",
                "Reset Available: \(yesNo(provider.resetMetadataAvailable))",
                "Last Refresh Attempt: \(timestamp(provider.lastRefreshAttemptAt))",
                "Last Successful Refresh: \(timestamp(provider.lastSuccessfulRefreshAt))",
                "Last Refresh: \(englishRefresh(provider.refreshOutcome))",
                "Last Failure: \(provider.lastFailureCategory?.rawValue ?? "None")",
            ])
        }

        lines.append(contentsOf: [
            "",
            "Privacy:",
            "No credentials, prompts, session contents, project data, private paths, or raw provider responses are included.",
        ])
        return lines.joined(separator: "\n")
    }

    private static func version(_ version: DiagnosticVersion?) -> String {
        version?.value ?? "Unknown"
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func yesNoUnknown(_ value: Bool?) -> String {
        value.map(yesNo) ?? "Unknown"
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else { return "Not available" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter.string(from: date)
    }

    private static func englishAvailability(_ provider: ProviderDiagnosticSnapshot) -> String {
        if provider.availability == .notInstalled,
           provider.hostApplication?.isDetected == true {
            return "Runtime unavailable"
        }
        return switch provider.availability {
        case .loading: "Loading"
        case .available: "Available"
        case .disabled: "Disabled"
        case .stale: "Stale"
        case .notConfigured: "Not configured"
        case .notInstalled: "Not installed"
        case .unsupportedAuthentication: "Unsupported authentication"
        case .failed: "Failed"
        }
    }

    private static func englishCompatibility(_ value: DiagnosticCompatibilityStatus) -> String {
        switch value {
        case .compatible: "Compatible"
        case .unverified: "Unverified"
        case .unavailable: "Unavailable"
        case .notApplicable: "Not applicable"
        case .unknown: "Unknown"
        }
    }

    private static func englishAppServer(_ value: DiagnosticAppServerState) -> String {
        switch value {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .notStarted: "Not started"
        case .launchFailed: "Launch failed"
        case .notApplicable: "Not applicable"
        case .unknown: "Unknown"
        }
    }

    private static func englishRefresh(_ value: DiagnosticRefreshOutcome) -> String {
        switch value {
        case .successful: "Successful"
        case .failed: "Failed"
        case .inProgress: "In progress"
        case .disabled: "Disabled"
        case .notAttempted: "Not attempted"
        }
    }
}
