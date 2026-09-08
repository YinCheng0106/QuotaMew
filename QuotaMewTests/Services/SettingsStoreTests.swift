import Foundation
import XCTest
@testable import QuotaMew

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testPersistedSettingsSurviveStoreRecreation() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)

        first.setProvider(.codex, enabled: false)
        first.setProvider(.claude, enabled: false)
        first.setMenuBarItemRequested(false)
        first.setNotificationsEnabled(false)
        first.setReminder(windowClass: .short, minutes: 60, enabled: false)
        first.setReminder(windowClass: .short, minutes: 30, enabled: false)
        first.setReminder(windowClass: .long, minutes: 24 * 60, enabled: false)
        first.setReminder(windowClass: .long, minutes: 6 * 60, enabled: false)
        first.setReminder(windowClass: .long, minutes: 60, enabled: false)
        first.setUsagePresentationMode(.used)
        first.setMenuBarDisplayStyle(.overview)
        first.setMenuBarQuotaSelection(.lunaReserve)
        first.setPinnedProvider(.claude)
        first.setOnboardingState(.completed)
        first.setResetIntelligenceEnabled(true)

        let recreated = SettingsStore(defaults: defaults)

        XCTAssertFalse(recreated.isCodexEnabled)
        XCTAssertFalse(recreated.isClaudeEnabled)
        XCTAssertFalse(recreated.isMenuBarItemRequested)
        XCTAssertFalse(recreated.areNotificationsEnabled)
        XCTAssertEqual(recreated.notificationPreferences.thresholds(for: .short), [])
        XCTAssertEqual(recreated.notificationPreferences.thresholds(for: .long), [])
        XCTAssertEqual(recreated.usagePresentationMode, .used)
        XCTAssertEqual(recreated.menuBarDisplayStyle, .overview)
        XCTAssertEqual(recreated.menuBarQuotaSelection, .lunaReserve)
        XCTAssertEqual(recreated.pinnedProviderID, .claude)
        XCTAssertEqual(recreated.onboardingState, .completed)
        XCTAssertEqual(recreated.onboardingLastCompletedVersion, SettingsStore.currentOnboardingVersion)
        XCTAssertTrue(recreated.isResetIntelligenceEnabled)
    }

    func testNewStoreUsesV01Defaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.isCodexEnabled)
        XCTAssertTrue(store.isClaudeEnabled)
        XCTAssertTrue(store.isMenuBarItemRequested)
        XCTAssertTrue(store.areNotificationsEnabled)
        XCTAssertEqual(store.notificationPreferences.thresholds(for: .short), [60, 30])
        XCTAssertEqual(
            store.notificationPreferences.thresholds(for: .long),
            [24 * 60, 6 * 60, 60]
        )
        XCTAssertEqual(store.usagePresentationMode, .remaining)
        XCTAssertEqual(store.menuBarDisplayStyle, .single)
        XCTAssertEqual(store.menuBarQuotaSelection, .weekly)
        XCTAssertNil(store.pinnedProviderID)
        XCTAssertEqual(store.onboardingState, .neverShown)
        XCTAssertEqual(store.onboardingLastCompletedVersion, 0)
        XCTAssertFalse(store.isResetIntelligenceEnabled)
    }

    func testFreshInstallPersistsNeverShownClassificationAcrossRecreation() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SettingsStore(defaults: defaults)
        let recreated = SettingsStore(defaults: defaults)

        XCTAssertEqual(first.onboardingState, .neverShown)
        XCTAssertEqual(first.onboardingLastCompletedVersion, 0)
        XCTAssertEqual(recreated.onboardingState, .neverShown)
        XCTAssertEqual(recreated.onboardingLastCompletedVersion, 0)
        XCTAssertEqual(defaults.string(forKey: "onboarding.state"), "neverShown")
    }

    func testBetaTwoInstallationWithoutOnboardingStateMigratesToSkipped() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Beta 2 persisted this migration key during SettingsStore initialization.
        defaults.set(true, forKey: "notifications.short-window.reminder.1h.enabled")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.onboardingState, .skipped)
        XCTAssertEqual(
            store.onboardingLastCompletedVersion,
            SettingsStore.currentOnboardingVersion
        )
        XCTAssertEqual(defaults.string(forKey: "onboarding.state"), "skipped")
    }

    func testEarlierInstallationEvidenceWithoutOnboardingStateMigratesToSkipped() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{}".utf8), forKey: "notification.deduplication.v1")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.onboardingState, .skipped)
        XCTAssertEqual(
            store.onboardingLastCompletedVersion,
            SettingsStore.currentOnboardingVersion
        )
    }

    func testPersistedOnboardingStateAndVersionTakePriorityOverMigrationEvidence() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingState.completed.rawValue, forKey: "onboarding.state")
        defaults.set(7, forKey: "onboarding.last-completed-version")
        defaults.set(false, forKey: "providers.codex.enabled")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.onboardingState, .completed)
        XCTAssertEqual(store.onboardingLastCompletedVersion, 7)
    }

    func testMenuBarVisibilityPreferenceDoesNotModifyProviderEnablement() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        store.setMenuBarItemRequested(false)

        XCTAssertFalse(store.isMenuBarItemRequested)
        XCTAssertTrue(store.isCodexEnabled)
        XCTAssertTrue(store.isClaudeEnabled)
    }

    func testProviderEnablementDoesNotModifyMenuBarVisibilityPreference() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        store.setProvider(.codex, enabled: false)
        store.setProvider(.claude, enabled: false)
        XCTAssertTrue(store.isMenuBarItemRequested)

        store.setMenuBarItemRequested(false)
        store.setProvider(.codex, enabled: true)
        store.setProvider(.claude, enabled: true)
        XCTAssertFalse(store.isMenuBarItemRequested)
    }

    func testLegacyOneHourPreferenceMigratesToShortWindowSetting() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "notifications.reminder.1h.enabled")

        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.isShortWindow1HourReminderEnabled)
        XCTAssertFalse(store.is1HourReminderEnabled)
        XCTAssertTrue(store.isShortWindow30MinuteReminderEnabled)
    }

    func testShortAndLongWindowReminderSettingsAreIndependent() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        store.setReminder(windowClass: .short, minutes: 60, enabled: false)

        XCTAssertEqual(store.notificationPreferences.thresholds(for: .short), [30])
        XCTAssertEqual(
            store.notificationPreferences.thresholds(for: .long),
            [24 * 60, 6 * 60, 60]
        )

        store.setReminder(windowClass: .long, minutes: 60, enabled: false)

        XCTAssertEqual(store.notificationPreferences.thresholds(for: .short), [30])
        XCTAssertEqual(
            store.notificationPreferences.thresholds(for: .long),
            [24 * 60, 6 * 60]
        )

        let recreated = SettingsStore(defaults: defaults)
        XCTAssertEqual(recreated.notificationPreferences.thresholds(for: .short), [30])
        XCTAssertEqual(
            recreated.notificationPreferences.thresholds(for: .long),
            [24 * 60, 6 * 60]
        )
    }

    func testMigratedShortWindowPreferenceStaysIndependentAfterRestart() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "notifications.reminder.1h.enabled")
        let first = SettingsStore(defaults: defaults)

        first.setReminder(windowClass: .long, minutes: 60, enabled: false)
        let recreated = SettingsStore(defaults: defaults)

        XCTAssertTrue(recreated.isShortWindow1HourReminderEnabled)
        XCTAssertFalse(recreated.is1HourReminderEnabled)
    }

    func testUnknownPresentationModeFallsBackWithoutOverwritingStoredValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-mode", forKey: "presentation.usage.mode")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.usagePresentationMode, .remaining)
        XCTAssertEqual(defaults.string(forKey: "presentation.usage.mode"), "future-mode")
    }

    func testMissingMenuBarPreferencesPreserveBetaTwoWeeklyMeaning() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(UsagePresentationMode.used.rawValue, forKey: "presentation.usage.mode")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.menuBarDisplayStyle, .single)
        XCTAssertEqual(store.menuBarQuotaSelection, .weekly)
        XCTAssertNil(defaults.object(forKey: "presentation.menu-bar.display-style"))
        XCTAssertNil(defaults.object(forKey: "presentation.menu-bar.quota-selection"))
        XCTAssertEqual(store.usagePresentationMode, .used)
    }

    func testSingleAndOverviewPreferencesPersistIndependently() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)

        first.setMenuBarDisplayStyle(.overview)
        XCTAssertEqual(SettingsStore(defaults: defaults).menuBarDisplayStyle, .overview)

        first.setMenuBarDisplayStyle(.single)
        first.setMenuBarQuotaSelection(.fiveHour)
        let recreated = SettingsStore(defaults: defaults)

        XCTAssertEqual(recreated.menuBarDisplayStyle, .single)
        XCTAssertEqual(recreated.menuBarQuotaSelection, .fiveHour)
    }

    func testEveryQuotaSelectionPersists() {
        for selection in MenuBarQuotaSelection.allCases {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = SettingsStore(defaults: defaults)

            store.setMenuBarQuotaSelection(selection)

            XCTAssertEqual(SettingsStore(defaults: defaults).menuBarQuotaSelection, selection)
        }
    }

    func testUnknownMenuBarValuesFallBackWithoutOverwritingStoredValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-style", forKey: "presentation.menu-bar.display-style")
        defaults.set("future-quota", forKey: "presentation.menu-bar.quota-selection")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.menuBarDisplayStyle, .single)
        XCTAssertEqual(store.menuBarQuotaSelection, .weekly)
        XCTAssertEqual(defaults.string(forKey: "presentation.menu-bar.display-style"), "future-style")
        XCTAssertEqual(defaults.string(forKey: "presentation.menu-bar.quota-selection"), "future-quota")
    }

    func testChangingMenuBarPreferencesDoesNotChangeUnrelatedSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.claude, enabled: false)
        store.setNotificationsEnabled(false)
        store.setUsagePresentationMode(.used)
        store.setPinnedProvider(.codex)

        store.setMenuBarDisplayStyle(.overview)
        store.setMenuBarQuotaSelection(.lunaReserve)

        XCTAssertFalse(store.isClaudeEnabled)
        XCTAssertFalse(store.areNotificationsEnabled)
        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertEqual(store.pinnedProviderID, .codex)
    }

    func testDisabledOrUnavailableProviderDoesNotMutatePersistedPin() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setPinnedProvider(.codex)

        store.setProvider(.codex, enabled: false)

        XCTAssertEqual(store.pinnedProviderID, .codex)
        XCTAssertEqual(defaults.string(forKey: "presentation.menu-bar.pinned-provider"), "codex")
    }

    func testChangingDisplayPreferenceDoesNotAlterProviderOrNotificationPreferences() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.claude, enabled: false)
        store.setNotificationsEnabled(false)
        let beforeThresholds = store.notificationPreferences.enabledThresholdMinutes

        store.setUsagePresentationMode(.used)

        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertTrue(store.isCodexEnabled)
        XCTAssertFalse(store.isClaudeEnabled)
        XCTAssertFalse(store.areNotificationsEnabled)
        XCTAssertEqual(store.notificationPreferences.enabledThresholdMinutes, beforeThresholds)
    }

    func testChangingProviderEnablementDoesNotAlterDisplayPreference() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setUsagePresentationMode(.used)

        store.setProvider(.codex, enabled: false)
        store.setProvider(.claude, enabled: false)

        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertFalse(store.isCodexEnabled)
        XCTAssertFalse(store.isClaudeEnabled)
    }

    func testUnknownPinnedProviderIsNotRenderedOrErasedByOlderApp() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-provider", forKey: "presentation.menu-bar.pinned-provider")

        let store = SettingsStore(defaults: defaults)

        XCTAssertNil(store.pinnedProviderID)
        XCTAssertEqual(store.pinnedProviderRawValue, "future-provider")
        XCTAssertEqual(defaults.string(forKey: "presentation.menu-bar.pinned-provider"), "future-provider")
    }

    func testOnboardingCompletionAndSkipDoNotResetOtherPreferences() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.claude, enabled: false)
        store.setUsagePresentationMode(.used)
        store.setMenuBarDisplayStyle(.overview)
        store.setMenuBarQuotaSelection(.lunaReserve)
        store.setPinnedProvider(.codex)

        store.setOnboardingState(.skipped)
        store.setOnboardingState(.completed)

        XCTAssertFalse(store.isClaudeEnabled)
        XCTAssertEqual(store.usagePresentationMode, .used)
        XCTAssertEqual(store.menuBarDisplayStyle, .overview)
        XCTAssertEqual(store.menuBarQuotaSelection, .lunaReserve)
        XCTAssertEqual(store.pinnedProviderID, .codex)
        XCTAssertEqual(store.onboardingState, .completed)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "dev.quotapulse.tests.settings.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
