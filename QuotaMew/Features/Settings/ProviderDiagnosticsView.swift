import SwiftUI

struct ProviderDiagnosticsView: View {
    @Environment(\.locale) private var locale

    let diagnostics: ProviderDiagnosticSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(diagnostics.providerID.displayName)
                .font(.headline)

            LabeledContent("Enabled", value: yesNo(diagnostics.isEnabled))
            LabeledContent("Availability", value: availability())

            if let hostApplication = diagnostics.hostApplication {
                LabeledContent("Host app") {
                    Text(
                        "\(hostApplication.application.englishLabel) · "
                            + yesNo(hostApplication.isDetected)
                    )
                }
                if let version = hostApplication.version, hostApplication.isDetected {
                    LabeledContent("Host app version", value: version.value)
                }
            }

            LabeledContent("Runtime", value: runtimeSource(diagnostics.runtimeSource))
            LabeledContent(
                "Runtime detected",
                value: yesNoUnknown(diagnostics.runtimeDetected)
            )
            LabeledContent(
                "Runtime compatibility",
                value: compatibility(diagnostics.compatibilityStatus)
            )
            LabeledContent("App Server", value: appServer(diagnostics.appServerState))
            LabeledContent(
                "Usage metadata",
                value: availabilityValue(diagnostics.usageMetadataAvailable)
            )
            LabeledContent(
                "Reset metadata",
                value: availabilityValue(diagnostics.resetMetadataAvailable)
            )
            LabeledContent("Last refresh", value: refresh(diagnostics.refreshOutcome))

            if let lastRefreshAttemptAt = diagnostics.lastRefreshAttemptAt {
                LabeledContent("Last refresh attempt") {
                    Text(lastRefreshAttemptAt, style: .relative)
                }
            }

            if let failure = diagnostics.lastFailureCategory {
                LabeledContent("Last failure", value: failureCategory(failure))
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }

    private func localized(_ value: String.LocalizationValue) -> String {
        AppLocalization.string(value, locale: locale)
    }

    private func yesNo(_ value: Bool) -> String {
        localized(value ? "Yes" : "No")
    }

    private func yesNoUnknown(_ value: Bool?) -> String {
        value.map(yesNo) ?? localized("Unknown")
    }

    private func availabilityValue(_ value: Bool) -> String {
        localized(value ? "Available" : "Unavailable")
    }

    private func availability() -> String {
        if diagnostics.availability == .notInstalled,
           diagnostics.hostApplication?.isDetected == true {
            return localized("Runtime not detected")
        }
        return switch diagnostics.availability {
        case .loading: localized("Loading")
        case .available: localized("Available")
        case .disabled: localized("Disabled")
        case .stale: localized("Stale")
        case .notConfigured: localized("Not configured")
        case .notInstalled: localized("Not installed")
        case .unsupportedAuthentication: localized("Unsupported authentication")
        case .failed: localized("Failed")
        }
    }

    private func runtimeSource(_ value: DiagnosticRuntimeSource) -> String {
        switch value {
        case .chatGPTApplication: "ChatGPT.app"
        case .legacyCodexApplication: "Codex.app"
        case .standaloneCodex: localized("Standalone Codex")
        case .localSnapshot: localized("Local snapshot")
        case .notDetected: localized("Not detected")
        case .notApplicable: localized("Not applicable")
        case .unknown: localized("Unknown")
        }
    }

    private func compatibility(_ value: DiagnosticCompatibilityStatus) -> String {
        switch value {
        case .compatible: localized("Compatible")
        case .unverified: localized("Unverified")
        case .unavailable: localized("Unavailable")
        case .notApplicable: localized("Not applicable")
        case .unknown: localized("Unknown")
        }
    }

    private func appServer(_ value: DiagnosticAppServerState) -> String {
        switch value {
        case .connected: localized("Connected")
        case .disconnected: localized("Disconnected")
        case .notStarted: localized("Not started")
        case .launchFailed: localized("Launch failed")
        case .notApplicable: localized("Not applicable")
        case .unknown: localized("Unknown")
        }
    }

    private func refresh(_ value: DiagnosticRefreshOutcome) -> String {
        switch value {
        case .successful: localized("Successful")
        case .failed: localized("Failed")
        case .inProgress: localized("In progress")
        case .disabled: localized("Disabled")
        case .notAttempted: localized("Not attempted")
        }
    }

    private func failureCategory(_ value: DiagnosticFailureCategory) -> String {
        switch value {
        case .runtimeNotDetected: localized("Runtime not detected")
        case .runtimeNotExecutable: localized("Runtime is not executable")
        case .appServerLaunchFailed: localized("App Server launch failed")
        case .appServerConnectionFailed: localized("App Server connection failed")
        case .rpcUnavailable: localized("Usage request unavailable")
        case .usageUnavailable: localized("Usage data unavailable")
        case .refreshFailed: localized("Refresh failed")
        case .providerDisabled: localized("Provider disabled")
        case .notConfigured: localized("Not configured")
        }
    }
}
