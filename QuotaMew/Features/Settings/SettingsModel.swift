import AppKit
import Observation

@MainActor
protocol DiagnosticClipboardWriting: AnyObject {
    func write(_ text: String) -> Bool
}

@MainActor
private final class SystemDiagnosticClipboard: DiagnosticClipboardWriting {
    func write(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

@Observable
@MainActor
final class SettingsModel {
    let store: SettingsStore

    private(set) var isMenuBarItemVisible = false
    private(set) var usagePresentationMode: UsagePresentationMode
    /// Retains unknown future provider values while this app version is running.
    private(set) var pinnedProviderRawValue: String?
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    private(set) var notificationAuthorizationStatus: NotificationAuthorizationStatus = .notDetermined
    private(set) var diagnostics: CompatibilityDiagnosticsSnapshot?
    private(set) var diagnosticsCopyFeedback: String?
    private(set) var isUpdatingLaunchAtLogin = false
    private(set) var launchAtLoginUpdateFailed = false

    private let appModel: AppModel
    private let notificationService: any NotificationServicing
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let diagnosticClipboard: any DiagnosticClipboardWriting

    init(
        store: SettingsStore,
        appModel: AppModel,
        notificationService: any NotificationServicing,
        launchAtLoginController: any LaunchAtLoginControlling = LaunchAtLoginController(),
        diagnosticClipboard: any DiagnosticClipboardWriting = SystemDiagnosticClipboard()
    ) {
        self.store = store
        usagePresentationMode = store.usagePresentationMode
        pinnedProviderRawValue = store.pinnedProviderRawValue
        self.appModel = appModel
        self.notificationService = notificationService
        self.launchAtLoginController = launchAtLoginController
        self.diagnosticClipboard = diagnosticClipboard
        refreshLaunchAtLoginStatus()
    }

    func refreshSystemState() async {
        refreshLaunchAtLoginStatus()
        notificationAuthorizationStatus = await notificationService.authorizationStatus()
    }

    func refreshDiagnostics() async {
        diagnostics = await appModel.compatibilityDiagnostics()
    }

    func copyDiagnostics() async {
        let snapshot = await appModel.compatibilityDiagnostics()
        diagnostics = snapshot
        let didCopy = diagnosticClipboard.write(
            CompatibilityDiagnosticsReport.make(from: snapshot)
        )
        diagnosticsCopyFeedback = AppLocalization.string(
            didCopy ? "Diagnostics copied." : "Diagnostics could not be copied."
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        launchAtLoginUpdateFailed = false
        defer {
            refreshLaunchAtLoginStatus()
            isUpdatingLaunchAtLogin = false
        }

        do {
            try launchAtLoginController.setEnabled(enabled)
        } catch {
            launchAtLoginUpdateFailed = true
        }
    }

    func setMenuBarItemRequested(_ requested: Bool) {
        store.setMenuBarItemRequested(requested)
    }

    func setUsagePresentationMode(_ mode: UsagePresentationMode) {
        guard usagePresentationMode != mode else { return }
        store.setUsagePresentationMode(mode)
        usagePresentationMode = mode
    }

    func setPinnedProvider(_ providerID: ProviderID?) {
        store.setPinnedProvider(providerID)
        pinnedProviderRawValue = providerID?.rawValue
    }

    var pinnedProviderID: ProviderID? {
        pinnedProviderRawValue.flatMap(ProviderID.init(rawValue:))
    }

    var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation(
            providerStates: appModel.providerStates,
            persistedPinnedProviderRawValue: pinnedProviderRawValue,
            mode: usagePresentationMode
        )
    }

    func menuBarItemVisibilityDidChange(_ isVisible: Bool) {
        guard isMenuBarItemVisible != isVisible else { return }
        isMenuBarItemVisible = isVisible
    }

    func setProvider(
        _ providerID: ProviderID,
        enabled: Bool
    ) {
        guard store.isProviderEnabled(providerID) != enabled else { return }
        notificationService.providerEnablementDidChange(
            providerID,
            isEnabled: enabled
        )
        store.setProvider(providerID, enabled: enabled)
        appModel.applyProviderEligibilityChange(providerID, isEnabled: enabled)

        if enabled {
            appModel.refreshAfterProviderEnablement(providerID)
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            await enableNotifications()
            return
        }
        guard store.areNotificationsEnabled else { return }
        store.setNotificationsEnabled(enabled)
        await notificationService.preferencesDidChange()
        notificationAuthorizationStatus = await notificationService.authorizationStatus()
    }

    func enableNotifications() async {
        if !store.areNotificationsEnabled {
            store.setNotificationsEnabled(true)
            await notificationService.preferencesDidChange()
        }
        notificationAuthorizationStatus = await notificationService.requestAuthorization()
    }

    func completeOnboarding() {
        store.setOnboardingState(.completed)
    }

    func skipOnboarding() {
        store.setOnboardingState(.skipped)
    }

    func setReminder(
        windowClass: NotificationWindowClass,
        minutes: Int,
        enabled: Bool
    ) async {
        let before = store.notificationPreferences
        store.setReminder(windowClass: windowClass, minutes: minutes, enabled: enabled)
        guard store.notificationPreferences != before else { return }
        await notificationService.preferencesDidChange()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginController.refreshStatus()
        launchAtLoginStatus = launchAtLoginController.status
    }
}
