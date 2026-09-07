import SwiftUI

struct OnboardingView: View {
    let model: SettingsModel
    let mode: OnboardingPresentationMode
    let skip: @MainActor () -> Void
    let complete: @MainActor () -> Void
    let close: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    OnboardingHeader()
                    OnboardingProvidersSection(model: model)
                    Divider()
                    OnboardingPrivacySection()
                    Divider()
                    OnboardingDisplaySection(model: model)
                    Divider()
                    OnboardingBehaviorSection(model: model)
                    Divider()
                    OnboardingNotificationsSection(model: model)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            OnboardingActions(
                mode: mode,
                skip: skip,
                complete: complete,
                close: close
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 600, minHeight: 640)
        .task {
            await model.refreshSystemState()
            await model.refreshDiagnostics()
        }
    }
}

private struct OnboardingHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QuotaMew")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Keep track of your AI coding quota from the menu bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingProvidersSection: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingSectionHeading("Providers")
            OnboardingProviderRow(
                providerID: .codex,
                diagnostics: diagnostics(for: .codex)
            )
            OnboardingProviderRow(
                providerID: .claude,
                diagnostics: diagnostics(for: .claude)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Providers")
    }

    private func diagnostics(for providerID: ProviderID) -> ProviderDiagnosticSnapshot? {
        model.diagnostics?.providers.first { $0.providerID == providerID }
    }
}

private struct OnboardingProviderRow: View {
    let providerID: ProviderID
    let diagnostics: ProviderDiagnosticSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: providerID.systemImageName)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(providerID.displayName)
                    .font(.headline)
                if providerID == .claude {
                    Text("Experimental / Unverified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            if let diagnostics {
                statusText(status(for: diagnostics))
                    .multilineTextAlignment(.trailing)
            } else {
                ProgressView("Checking status…")
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(for diagnostics: ProviderDiagnosticSnapshot) -> OnboardingProviderStatus {
        providerID == .codex
            ? OnboardingProviderStatus.codex(diagnostics)
            : OnboardingProviderStatus.claude(diagnostics)
    }

    @ViewBuilder
    private func statusText(_ status: OnboardingProviderStatus) -> some View {
        switch status {
        case .available:
            Text("Available")
        case .detected:
            Text("Detected")
        case .notDetected:
            Text("Not detected")
        case .configured:
            Text("Configured")
        case .notConfigured:
            Text("Not configured")
        case .disabled:
            Text("Disabled")
        case .unavailable:
            Text("Unavailable")
        }
    }
}

private struct OnboardingPrivacySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnboardingSectionHeading("Privacy")
            Text("QuotaMew processes quota information locally.")
            Text(
                "QuotaMew does not intentionally upload prompts, project or source paths, account identifiers, credentials, usage history, or device identifiers."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingDisplaySection: View {
    @Environment(\.locale) private var locale

    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingSectionHeading("Display")
            Picker("Usage display", selection: usagePresentationModeBinding) {
                Text("Remaining").tag(UsagePresentationMode.remaining)
                Text("Used").tag(UsagePresentationMode.used)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Usage display")

            Picker("Menu Bar Provider", selection: pinnedProviderBinding) {
                Text("Automatic").tag(ProviderID?.none)
                if model.store.isCodexEnabled {
                    Text("Codex").tag(ProviderID.codex as ProviderID?)
                } else {
                    Text("Codex (Disabled)").tag(ProviderID.codex as ProviderID?)
                }
                if model.store.isClaudeEnabled {
                    Text("Claude Code").tag(ProviderID.claude as ProviderID?)
                } else {
                    Text("Claude Code (Disabled)").tag(ProviderID.claude as ProviderID?)
                }
            }

            if model.pinnedProviderRawValue != nil, model.pinnedProviderID == nil {
                Text("The selected menu bar provider is unavailable in this version of QuotaMew.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let providerID = model.pinnedProviderID,
                      !model.store.isProviderEnabled(providerID) {
                Text(
                    AppLocalization.string(
                        "menu-bar-provider.disabled \(providerID.displayName)",
                        locale: locale
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var usagePresentationModeBinding: Binding<UsagePresentationMode> {
        Binding(
            get: { model.usagePresentationMode },
            set: { model.setUsagePresentationMode($0) }
        )
    }

    private var pinnedProviderBinding: Binding<ProviderID?> {
        Binding(
            get: { model.pinnedProviderID },
            set: { model.setPinnedProvider($0) }
        )
    }
}

private struct OnboardingBehaviorSection: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnboardingSectionHeading("App Behavior")
            Toggle("Launch at Login", isOn: launchAtLoginBinding)
                .disabled(
                    model.isUpdatingLaunchAtLogin
                        || model.launchAtLoginStatus == .requiresApproval
                )

            if model.launchAtLoginUpdateFailed {
                Label(
                    "Launch at Login could not be changed.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            } else if model.launchAtLoginStatus == .requiresApproval {
                Text("Approval is required in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.launchAtLoginStatus == .unavailable {
                Text("Launch at Login is not registered with macOS yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginStatus == .enabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }
}

private struct OnboardingNotificationsSection: View {
    @State private var isRequestingAuthorization = false

    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnboardingSectionHeading("Notifications")

            switch model.notificationAuthorizationStatus {
            case .authorized where model.store.areNotificationsEnabled:
                Label("Notifications are enabled.", systemImage: "checkmark.circle")
            case .denied:
                Label(
                    "Notifications are disabled in System Settings.",
                    systemImage: "bell.slash"
                )
                .foregroundStyle(.secondary)
            case .authorized, .notDetermined:
                Button("Enable Notifications", systemImage: "bell.badge") {
                    isRequestingAuthorization = true
                    Task {
                        await model.enableNotifications()
                        isRequestingAuthorization = false
                    }
                }
                .disabled(isRequestingAuthorization)
                .accessibilityHint("Requests macOS notification permission.")
            }

            Text("Notification permission is requested only when you choose Enable Notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingActions: View {
    let mode: OnboardingPresentationMode
    let skip: @MainActor () -> Void
    let complete: @MainActor () -> Void
    let close: @MainActor () -> Void

    var body: some View {
        HStack {
            if mode == .firstRun {
                Button("Skip", action: skip)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Get Started", action: complete)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

private struct OnboardingSectionHeading: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Onboarding") {
    let appModel = AppDependencies.makePreviewModel()
    let store = SettingsStore(defaults: UserDefaults(suiteName: "OnboardingPreview")!)
    OnboardingView(
        model: SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: PreviewOnboardingNotificationService(),
            launchAtLoginController: PreviewOnboardingLaunchAtLoginController()
        ),
        mode: .firstRun,
        skip: {},
        complete: {},
        close: {}
    )
}

@MainActor
private final class PreviewOnboardingNotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    func authorizationStatus() async -> NotificationAuthorizationStatus { .notDetermined }
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

@MainActor
private final class PreviewOnboardingLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) throws {
        status = enabled ? .enabled : .disabled
    }
}
