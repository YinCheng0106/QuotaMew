import SwiftUI

struct SettingsView: View {
    let model: SettingsModel
    let appModel: AppModel
    let showOnboarding: @MainActor () -> Void

    var body: some View {
        TabView {
            GeneralSettingsPage(
                model: model,
                appModel: appModel,
                showOnboarding: showOnboarding
            )
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettingsPage(model: model)
                .tabItem { Label("Providers", systemImage: "rectangle.3.group") }
            NotificationSettingsPage(model: model, appModel: appModel)
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 500, height: 590)
        .task {
            await model.refreshSystemState()
            await model.refreshDiagnostics()
        }
    }
}

private struct GeneralSettingsPage: View {
    @Environment(\.locale) private var locale

    let model: SettingsModel
    let appModel: AppModel
    let showOnboarding: @MainActor () -> Void

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Menu Bar Item", isOn: menuBarVisibilityBinding)
                Text("macOS may also control visibility in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .disabled(model.isUpdatingLaunchAtLogin || model.launchAtLoginStatus == .requiresApproval)
                launchAtLoginStatus
                LabeledContent("Background refresh") { Text("Every 15 minutes") }
                Button("Show Onboarding Again", systemImage: "questionmark.circle") {
                    showOnboarding()
                }
            }

            Section("Display") {
                Picker("Usage display", selection: usagePresentationModeBinding) {
                    Text("Remaining").tag(UsagePresentationMode.remaining)
                    Text("Used").tag(UsagePresentationMode.used)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Usage display")

                Picker("Menu Bar Provider", selection: pinnedProviderBinding) {
                    Text("Automatic").tag(ProviderID?.none)
                    Text(model.store.isCodexEnabled ? "Codex" : "Codex (Disabled)")
                        .tag(ProviderID.codex as ProviderID?)
                    Text(model.store.isClaudeEnabled ? "Claude Code" : "Claude Code (Disabled)")
                        .tag(ProviderID.claude as ProviderID?)
                }

                if model.pinnedProviderRawValue != nil, model.pinnedProviderID == nil {
                    Text("The selected menu bar provider is unavailable in this version of QuotaMew.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DiagnosticsSection(model: model)

            #if DEBUG
            Section("Development") {
                Button("Log runtime snapshot", systemImage: "waveform.path.ecg") {
                    Task { await appModel.logRuntimeDiagnosticsSnapshot() }
                }
                .accessibilityHint("Writes a privacy-safe runtime diagnostics snapshot to Console.")
                if let runtimeDiagnosticsFeedback = appModel.runtimeDiagnosticsFeedback {
                    Text(runtimeDiagnosticsFeedback).foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .padding()
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { model.store.isMenuBarItemRequested },
            set: { model.setMenuBarItemRequested($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLoginStatus == .enabled }, set: { model.setLaunchAtLoginEnabled($0) })
    }

    private var usagePresentationModeBinding: Binding<UsagePresentationMode> {
        Binding(get: { model.usagePresentationMode }, set: { model.setUsagePresentationMode($0) })
    }

    private var pinnedProviderBinding: Binding<ProviderID?> {
        Binding(get: { model.pinnedProviderID }, set: { model.setPinnedProvider($0) })
    }

    @ViewBuilder
    private var launchAtLoginStatus: some View {
        if model.launchAtLoginUpdateFailed {
            Label("Launch at Login could not be changed.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            switch model.launchAtLoginStatus {
            case .requiresApproval:
                Text("Approval is required in System Settings > General > Login Items.").foregroundStyle(.secondary)
            case .unavailable:
                Text("Launch at Login is not registered with macOS yet.").foregroundStyle(.secondary)
            case .enabled, .disabled:
                EmptyView()
            }
        }
    }
}

private struct ProviderSettingsPage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Providers") {
                Toggle("Codex", isOn: providerBinding(.codex))
                Toggle("Claude Code (Experimental, Unverified)", isOn: providerBinding(.claude))
                Text("Claude Code remains Experimental and Unverified. QuotaMew does not install or configure its bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerBinding(_ providerID: ProviderID) -> Binding<Bool> {
        Binding(get: { model.store.isProviderEnabled(providerID) }, set: { model.setProvider(providerID, enabled: $0) })
    }
}

private struct NotificationSettingsPage: View {
    let model: SettingsModel
    let appModel: AppModel

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable reset notifications", isOn: notificationsEnabledBinding)
                notificationPermissionStatus
                VStack(alignment: .leading, spacing: 8) {
                    Text("Short windows (up to 6 hours)").font(.headline)
                    Toggle("1-hour reminder", isOn: reminderBinding(.short, 60))
                    Toggle("30-minute reminder", isOn: reminderBinding(.short, 30))
                    Divider()
                    Text("Long windows").font(.headline)
                    Toggle("24-hour reminder", isOn: reminderBinding(.long, 24 * 60))
                    Toggle("6-hour reminder", isOn: reminderBinding(.long, 6 * 60))
                    Toggle("1-hour reminder", isOn: reminderBinding(.long, 60))
                }
                .disabled(!model.store.areNotificationsEnabled)
            }
            #if DEBUG
            Section("Development") {
                Button("Send test notification", systemImage: "bell.badge") {
                    Task { await appModel.sendTestNotification(); await model.refreshSystemState() }
                }
                .accessibilityHint("Requests notification permission if needed, then schedules a local notification for about five seconds from now.")
                if let notificationFeedback = appModel.notificationFeedback {
                    Text(notificationFeedback).foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .padding()
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(get: { model.store.areNotificationsEnabled }, set: { enabled in Task { await model.setNotificationsEnabled(enabled) } })
    }

    @ViewBuilder
    private var notificationPermissionStatus: some View {
        switch model.notificationAuthorizationStatus {
        case .denied:
            Label("Notifications are disabled in System Settings.", systemImage: "bell.slash").foregroundStyle(.secondary)
        case .notDetermined where model.store.areNotificationsEnabled:
            Button("Enable Notifications", systemImage: "bell.badge") {
                Task { await model.enableNotifications() }
            }
            .accessibilityHint("Requests macOS notification permission.")
        case .authorized, .notDetermined:
            EmptyView()
        }
    }

    private func reminderBinding(_ windowClass: NotificationWindowClass, _ minutes: Int) -> Binding<Bool> {
        Binding(
            get: {
                switch (windowClass, minutes) {
                case (.short, 60): model.store.isShortWindow1HourReminderEnabled
                case (.short, 30): model.store.isShortWindow30MinuteReminderEnabled
                case (.long, 24 * 60): model.store.is24HourReminderEnabled
                case (.long, 6 * 60): model.store.is6HourReminderEnabled
                case (.long, 60): model.store.is1HourReminderEnabled
                default: false
                }
            },
            set: { enabled in Task { await model.setReminder(windowClass: windowClass, minutes: minutes, enabled: enabled) } }
        )
    }
}

private struct DiagnosticsSection: View {
    let model: SettingsModel

    var body: some View {
        Section("Diagnostics") {
            if let diagnostics = model.diagnostics {
                LabeledContent("QuotaMew") {
                    Text(diagnostics.appVersion.map { "\($0.value) (\(diagnostics.buildNumber?.value ?? "—"))" } ?? "—")
                        .monospacedDigit()
                }
                ForEach(diagnostics.providers) { ProviderDiagnosticsView(diagnostics: $0) }
            } else {
                ProgressView("Loading diagnostics…").controlSize(.small)
            }
            Button("Copy Diagnostics", systemImage: "doc.on.doc") { Task { await model.copyDiagnostics() } }
                .accessibilityHint("Copies a privacy-safe English report for GitHub Issues.")
            if let feedback = model.diagnosticsCopyFeedback { Text(feedback).foregroundStyle(.secondary) }
            Text("Diagnostics exclude credentials, prompts, sessions, project data, private paths, and raw provider responses.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Settings") {
    let appModel = AppDependencies.makePreviewModel()
    let store = SettingsStore(defaults: UserDefaults(suiteName: "SettingsPreview")!)
    SettingsView(
        model: SettingsModel(
            store: store,
            appModel: appModel,
            notificationService: PreviewSettingsNotificationService(),
            launchAtLoginController: PreviewLaunchAtLoginController()
        ),
        appModel: appModel,
        showOnboarding: {}
    )
}

@MainActor private final class PreviewSettingsNotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    func authorizationStatus() async -> NotificationAuthorizationStatus { .authorized }
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}

@MainActor private final class PreviewLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) throws { status = enabled ? .enabled : .disabled }
}
