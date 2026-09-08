import Foundation
import Observation

struct NotificationPreferences: Equatable, Sendable {
    var isEnabled: Bool
    var enabledThresholdMinutes: [NotificationWindowClass: Set<Int>]

    static let defaults = NotificationPreferences(
        isEnabled: true,
        enabledThresholdMinutes: [
            .short: [60, 30],
            .long: [24 * 60, 6 * 60, 60],
        ]
    )

    func thresholds(for windowClass: NotificationWindowClass) -> Set<Int> {
        enabledThresholdMinutes[windowClass] ?? []
    }
}

enum UsagePresentationMode: String, CaseIterable, Codable, Sendable {
    case remaining
    case used
}

enum MenuBarDisplayStyle: String, CaseIterable, Codable, Sendable {
    case single
    case overview
}

enum MenuBarQuotaSelection: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
    case lunaReserve

    var compactIdentifier: String {
        switch self {
        case .fiveHour: "5H"
        case .weekly: "W"
        case .lunaReserve: "R"
        }
    }

    func displayName(locale: Locale) -> String {
        switch self {
        case .fiveHour:
            AppLocalization.string("5-hour", locale: locale)
        case .weekly:
            AppLocalization.string("Weekly", locale: locale)
        case .lunaReserve:
            AppLocalization.string("Luna Reserve", locale: locale)
        }
    }
}

enum OnboardingState: String, CaseIterable, Codable, Sendable {
    case neverShown
    case completed
    case skipped
}

@MainActor
protocol AppPreferencesProviding: AnyObject, Sendable {
    var notificationPreferences: NotificationPreferences { get }
    func isProviderEnabled(_ providerID: ProviderID) -> Bool
}

@Observable
@MainActor
final class SettingsStore: AppPreferencesProviding {
    private enum Key {
        // Keep the original key so existing installations retain their preference.
        static let menuBarItemRequested = "presentation.menu-bar-extra.requested"
        static let codexEnabled = "providers.codex.enabled"
        static let claudeEnabled = "providers.claude.enabled"
        static let notificationsEnabled = "notifications.enabled"
        static let reminder24HoursEnabled = "notifications.reminder.24h.enabled"
        static let reminder6HoursEnabled = "notifications.reminder.6h.enabled"
        static let reminder1HourEnabled = "notifications.reminder.1h.enabled"
        static let shortWindowReminder1HourEnabled = "notifications.short-window.reminder.1h.enabled"
        static let shortWindowReminder30MinutesEnabled = "notifications.short-window.reminder.30m.enabled"
        static let usagePresentationMode = "presentation.usage.mode"
        static let pinnedProvider = "presentation.menu-bar.pinned-provider"
        static let menuBarDisplayStyle = "presentation.menu-bar.display-style"
        static let menuBarQuotaSelection = "presentation.menu-bar.quota-selection"
        static let onboardingState = "onboarding.state"
        static let onboardingLastCompletedVersion = "onboarding.last-completed-version"
        static let resetIntelligenceEnabled = "reset-intelligence.enabled"
    }

    private let defaults: UserDefaults

    static let currentOnboardingVersion = 1

    private(set) var isMenuBarItemRequested: Bool
    private(set) var isCodexEnabled: Bool
    private(set) var isClaudeEnabled: Bool
    private(set) var areNotificationsEnabled: Bool
    private(set) var is24HourReminderEnabled: Bool
    private(set) var is6HourReminderEnabled: Bool
    private(set) var is1HourReminderEnabled: Bool
    private(set) var isShortWindow1HourReminderEnabled: Bool
    private(set) var isShortWindow30MinuteReminderEnabled: Bool
    private(set) var usagePresentationMode: UsagePresentationMode
    private(set) var menuBarDisplayStyle: MenuBarDisplayStyle
    private(set) var menuBarQuotaSelection: MenuBarQuotaSelection
    /// The raw value is retained so an older app does not erase a newer provider pin.
    private(set) var pinnedProviderRawValue: String?
    private(set) var onboardingState: OnboardingState
    private(set) var onboardingLastCompletedVersion: Int
    private(set) var isResetIntelligenceEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hasPersistedOnboardingState = defaults.object(forKey: Key.onboardingState) != nil
        let isEstablishedInstallation = Self.hasPreOnboardingInstallationEvidence(defaults)
        isMenuBarItemRequested = Self.bool(
            defaults,
            key: Key.menuBarItemRequested,
            defaultValue: true
        )
        isCodexEnabled = Self.bool(defaults, key: Key.codexEnabled, defaultValue: true)
        isClaudeEnabled = Self.bool(defaults, key: Key.claudeEnabled, defaultValue: true)
        areNotificationsEnabled = Self.bool(defaults, key: Key.notificationsEnabled, defaultValue: true)
        is24HourReminderEnabled = Self.bool(defaults, key: Key.reminder24HoursEnabled, defaultValue: true)
        is6HourReminderEnabled = Self.bool(defaults, key: Key.reminder6HoursEnabled, defaultValue: true)
        is1HourReminderEnabled = Self.bool(defaults, key: Key.reminder1HourEnabled, defaultValue: true)
        let hasShortWindowOneHourPreference = defaults.object(
            forKey: Key.shortWindowReminder1HourEnabled
        ) != nil
        let shortWindowOneHourDefault = Self.bool(
            defaults,
            key: Key.reminder1HourEnabled,
            defaultValue: true
        )
        let shortWindowOneHourPreference = Self.bool(
            defaults,
            key: Key.shortWindowReminder1HourEnabled,
            defaultValue: shortWindowOneHourDefault
        )
        isShortWindow1HourReminderEnabled = shortWindowOneHourPreference
        if !hasShortWindowOneHourPreference {
            defaults.set(
                shortWindowOneHourPreference,
                forKey: Key.shortWindowReminder1HourEnabled
            )
        }
        isShortWindow30MinuteReminderEnabled = Self.bool(
            defaults,
            key: Key.shortWindowReminder30MinutesEnabled,
            defaultValue: true
        )
        usagePresentationMode = Self.enumValue(
            defaults,
            key: Key.usagePresentationMode,
            defaultValue: .remaining
        )
        menuBarDisplayStyle = Self.enumValue(
            defaults,
            key: Key.menuBarDisplayStyle,
            defaultValue: .single
        )
        menuBarQuotaSelection = Self.enumValue(
            defaults,
            key: Key.menuBarQuotaSelection,
            defaultValue: .weekly
        )
        pinnedProviderRawValue = defaults.string(forKey: Key.pinnedProvider)
        if hasPersistedOnboardingState {
            onboardingState = Self.enumValue(
                defaults,
                key: Key.onboardingState,
                defaultValue: .neverShown
            )
            onboardingLastCompletedVersion = defaults.object(
                forKey: Key.onboardingLastCompletedVersion
            ) == nil ? 0 : defaults.integer(forKey: Key.onboardingLastCompletedVersion)
        } else if isEstablishedInstallation {
            // Milestone A froze the rule that an update must not interrupt an
            // established user. Persist the existing skipped state so this
            // one-time classification remains stable on future launches.
            onboardingState = .skipped
            let migratedVersion = Self.currentOnboardingVersion
            onboardingLastCompletedVersion = migratedVersion
            defaults.set(OnboardingState.skipped.rawValue, forKey: Key.onboardingState)
            defaults.set(
                migratedVersion,
                forKey: Key.onboardingLastCompletedVersion
            )
        } else {
            // Persisting the default distinguishes a fresh Beta 3 install from
            // an older install after the rest of this initializer writes its
            // existing migration defaults.
            onboardingState = .neverShown
            onboardingLastCompletedVersion = 0
            defaults.set(OnboardingState.neverShown.rawValue, forKey: Key.onboardingState)
        }
        isResetIntelligenceEnabled = Self.bool(defaults, key: Key.resetIntelligenceEnabled, defaultValue: false)
    }

    var notificationPreferences: NotificationPreferences {
        var shortWindowThresholds: Set<Int> = []
        if isShortWindow1HourReminderEnabled { shortWindowThresholds.insert(60) }
        if isShortWindow30MinuteReminderEnabled { shortWindowThresholds.insert(30) }

        var longWindowThresholds: Set<Int> = []
        if is24HourReminderEnabled { longWindowThresholds.insert(24 * 60) }
        if is6HourReminderEnabled { longWindowThresholds.insert(6 * 60) }
        if is1HourReminderEnabled { longWindowThresholds.insert(60) }
        return NotificationPreferences(
            isEnabled: areNotificationsEnabled,
            enabledThresholdMinutes: [
                .short: shortWindowThresholds,
                .long: longWindowThresholds,
            ]
        )
    }

    func isProviderEnabled(_ providerID: ProviderID) -> Bool {
        switch providerID {
        case .codex: isCodexEnabled
        case .claude: isClaudeEnabled
        }
    }

    func setProvider(_ providerID: ProviderID, enabled: Bool) {
        switch providerID {
        case .codex:
            isCodexEnabled = enabled
            defaults.set(enabled, forKey: Key.codexEnabled)
        case .claude:
            isClaudeEnabled = enabled
            defaults.set(enabled, forKey: Key.claudeEnabled)
        }
    }

    func setMenuBarItemRequested(_ requested: Bool) {
        isMenuBarItemRequested = requested
        defaults.set(requested, forKey: Key.menuBarItemRequested)
    }

    var pinnedProviderID: ProviderID? { pinnedProviderRawValue.flatMap(ProviderID.init(rawValue:)) }

    func setUsagePresentationMode(_ mode: UsagePresentationMode) {
        usagePresentationMode = mode
        defaults.set(mode.rawValue, forKey: Key.usagePresentationMode)
    }

    func setMenuBarDisplayStyle(_ style: MenuBarDisplayStyle) {
        menuBarDisplayStyle = style
        defaults.set(style.rawValue, forKey: Key.menuBarDisplayStyle)
    }

    func setMenuBarQuotaSelection(_ selection: MenuBarQuotaSelection) {
        menuBarQuotaSelection = selection
        defaults.set(selection.rawValue, forKey: Key.menuBarQuotaSelection)
    }

    func setPinnedProvider(_ providerID: ProviderID?) {
        pinnedProviderRawValue = providerID?.rawValue
        if let providerID { defaults.set(providerID.rawValue, forKey: Key.pinnedProvider) }
        else { defaults.removeObject(forKey: Key.pinnedProvider) }
    }

    func setOnboardingState(_ state: OnboardingState) {
        onboardingState = state
        onboardingLastCompletedVersion = Self.currentOnboardingVersion
        defaults.set(state.rawValue, forKey: Key.onboardingState)
        defaults.set(onboardingLastCompletedVersion, forKey: Key.onboardingLastCompletedVersion)
    }

    func setResetIntelligenceEnabled(_ enabled: Bool) {
        isResetIntelligenceEnabled = enabled
        defaults.set(enabled, forKey: Key.resetIntelligenceEnabled)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        areNotificationsEnabled = enabled
        defaults.set(enabled, forKey: Key.notificationsEnabled)
    }

    func setReminder(
        windowClass: NotificationWindowClass,
        minutes: Int,
        enabled: Bool
    ) {
        switch (windowClass, minutes) {
        case (.short, 60):
            isShortWindow1HourReminderEnabled = enabled
            defaults.set(enabled, forKey: Key.shortWindowReminder1HourEnabled)
        case (.short, 30):
            isShortWindow30MinuteReminderEnabled = enabled
            defaults.set(enabled, forKey: Key.shortWindowReminder30MinutesEnabled)
        case (.long, 24 * 60):
            is24HourReminderEnabled = enabled
            defaults.set(enabled, forKey: Key.reminder24HoursEnabled)
        case (.long, 6 * 60):
            is6HourReminderEnabled = enabled
            defaults.set(enabled, forKey: Key.reminder6HoursEnabled)
        case (.long, 60):
            is1HourReminderEnabled = enabled
            defaults.set(enabled, forKey: Key.reminder1HourEnabled)
        default:
            assertionFailure("Unsupported reset reminder threshold")
        }
    }

    private static func bool(_ defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func enumValue<Value: RawRepresentable>(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Value
    ) -> Value where Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key), let value = Value(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }

    private static func hasPreOnboardingInstallationEvidence(_ defaults: UserDefaults) -> Bool {
        let keys = [
            Key.menuBarItemRequested,
            Key.codexEnabled,
            Key.claudeEnabled,
            Key.notificationsEnabled,
            Key.reminder24HoursEnabled,
            Key.reminder6HoursEnabled,
            Key.reminder1HourEnabled,
            Key.shortWindowReminder1HourEnabled,
            Key.shortWindowReminder30MinutesEnabled,
            Key.usagePresentationMode,
            Key.pinnedProvider,
            Key.menuBarDisplayStyle,
            Key.menuBarQuotaSelection,
            Key.onboardingLastCompletedVersion,
            Key.resetIntelligenceEnabled,
            "notification.deduplication.v1",
            "notification.deduplication.v1.local-reset.v1",
            "notification.deduplication.v1.provider-lifecycle.v1",
        ]
        return keys.contains { defaults.object(forKey: $0) != nil }
    }
}
