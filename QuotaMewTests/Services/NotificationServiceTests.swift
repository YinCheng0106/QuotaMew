import XCTest
import UserNotifications
@testable import QuotaMew

@MainActor
final class NotificationServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testReserveDoesNotSendRemindersCompletedResetsOrRequestPermission() async {
        for bucket in ["base_model_inference", "gpt-reserve"] {
            let (service, center, store) = makeService(status: .notDetermined)
            let id = "codex.\(bucket).primary"
            let baseline = makeState(windowID: id, resetAfter: 3_600, usedPercentage: 82)
            let after = now.addingTimeInterval(3_630)
            let refreshed = makeState(
                windowID: id, resetAt: after.addingTimeInterval(604_800),
                usedPercentage: 1, capturedAt: after
            )
            let detectorBaseline = LocalResetDetector.standard.evaluate([baseline], state: .init(), now: now)
            let detectorReset = LocalResetDetector.standard.evaluate([refreshed], state: detectorBaseline.state, now: after)
            XCTAssertEqual(detectorReset.resets.count, 1, "Detector semantics must remain unchanged")

            await service.evaluate([baseline], now: now)
            await service.evaluate([refreshed], now: after)
            XCTAssertTrue(center.requests.isEmpty)
            XCTAssertEqual(center.authorizationRequestCount, 0)
            XCTAssertTrue(store.state.entries.isEmpty, "Reserve does not introduce reminder dedup entries")

            await service.evaluate([makeState(resetAt: after.addingTimeInterval(3_600), capturedAt: after)], now: after)
            XCTAssertEqual(center.authorizationRequestCount, 0)
            XCTAssertTrue(center.requests.isEmpty)

            let authorizationStatus = await service.requestAuthorization()
            XCTAssertEqual(authorizationStatus, .authorized)
            await service.evaluate([makeState(resetAt: after.addingTimeInterval(3_600), capturedAt: after)], now: after)
            XCTAssertEqual(center.authorizationRequestCount, 1)
            XCTAssertEqual(center.requests.count, 1)
            XCTAssertTrue(center.requests[0].title.contains("Weekly"))
        }
    }

    func testWeeklyWindowSupportsTwentyFourHourReminder() async throws {
        let (service, center, _) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 24 * 3_600, duration: .seconds(7 * 24 * 3_600), usedPercentage: 39)],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(request.title, "Codex Weekly quota resets in 24 hours")
        XCTAssertEqual(request.body, "You still have 61% of your quota remaining.")
    }

    func testWeeklyWindowSupportsSixHourReminder() async throws {
        let (service, center, store) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600, duration: .seconds(7 * 24 * 3_600), usedPercentage: 39)],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(request.title, "Codex Weekly quota resets in 6 hours")
        XCTAssertEqual(store.state.entries.first?.emittedThresholdMinutes, [24 * 60, 6 * 60])
    }

    func testWeeklyWindowSupportsOneHourReminder() async throws {
        let (service, center, store) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 60 * 60, duration: .seconds(7 * 24 * 3_600), usedPercentage: 39)],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(request.title, "Codex Weekly quota resets in 1 hour")
        XCTAssertEqual(
            store.state.entries.first?.emittedThresholdMinutes,
            [24 * 60, 6 * 60, 60]
        )
    }

    func testFiveHourWindowDoesNotScheduleSixHourReminder() async {
        let (service, center, _) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 5 * 3_600, duration: .seconds(5 * 3_600))],
            now: now
        )

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testFiveHourWindowSupportsOneHourReminder() async throws {
        let (service, center, store) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 60 * 60, duration: .seconds(5 * 3_600))],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.title, "Codex 5-hour quota resets in 1 hour")
        XCTAssertTrue(request.identifier.hasSuffix(".short.60m"))
        XCTAssertEqual(store.state.entries.first?.emittedThresholdMinutes, [60])
    }

    func testFiveHourWindowSupportsThirtyMinuteReminder() async throws {
        let (service, center, store) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 30 * 60, duration: .seconds(5 * 3_600))],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.title, "Codex 5-hour quota resets in 30 minutes")
        XCTAssertTrue(request.identifier.hasSuffix(".short.30m"))
        XCTAssertEqual(store.state.entries.first?.emittedThresholdMinutes, [60, 30])
    }

    func testWindowSpecificSettingsMapToMatchingQuotaWindows() async {
        let suiteName = "dev.quotapulse.tests.notifications.window-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setReminder(windowClass: .short, minutes: 60, enabled: false)
        let center = TestUserNotificationCenter()
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences
        )

        await service.evaluate(
            [makeState(windowID: "short", resetAfter: 60 * 60, duration: .seconds(5 * 3_600))],
            now: now
        )
        await service.evaluate(
            [makeState(windowID: "weekly", resetAfter: 60 * 60, duration: .seconds(7 * 24 * 3_600))],
            now: now
        )

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.requests[0].identifier.hasSuffix(".long.60m"))
    }

    func testRepeatedRefreshDoesNotDuplicateNotification() async {
        let (service, center, _) = makeService()
        let states = [makeState(resetAfter: 6 * 3_600)]

        await service.evaluate(states, now: now)
        await service.evaluate(states, now: now.addingTimeInterval(60))

        XCTAssertEqual(center.requests.count, 1)
    }

    func testConcurrentAuthorizedEvaluationDoesNotDuplicateNotification() async {
        let (service, center, _) = makeService(status: .authorized)
        center.yieldsBeforeReturningAuthorizationStatus = true
        let states = [makeState(resetAfter: 6 * 3_600)]
        let currentDate = now

        let first = Task { @MainActor in
            await service.evaluate(states, now: currentDate)
        }
        let second = Task { @MainActor in
            await service.evaluate(states, now: currentDate)
        }
        await first.value
        await second.value

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.requests.count, 1)
    }

    func testExplicitPermissionRequestDoesNotEvaluateOrDeliverSnapshots() async {
        let clock = TestDateSource(now)
        let center = TestUserNotificationCenter(status: .notDetermined)
        center.onRequestAuthorization = {
            clock.advance(by: 16 * 60)
        }
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            currentDate: { clock.now }
        )

        let status = await service.requestAuthorization()

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testAppRestartDoesNotDuplicateNotification() async {
        let suiteName = "dev.quotapulse.tests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstCenter = TestUserNotificationCenter()
        let firstService = NotificationService(
            center: firstCenter,
            stateStore: UserDefaultsNotificationStateStore(
                defaults: defaults,
                key: "deduplication"
            )
        )
        let states = [makeState(resetAfter: 6 * 3_600)]

        await firstService.evaluate(states, now: now)

        let relaunchedCenter = TestUserNotificationCenter()
        let relaunchedService = NotificationService(
            center: relaunchedCenter,
            stateStore: UserDefaultsNotificationStateStore(
                defaults: defaults,
                key: "deduplication"
            )
        )
        await relaunchedService.evaluate(states, now: now.addingTimeInterval(60))

        XCTAssertEqual(firstCenter.requests.count, 1)
        XCTAssertTrue(relaunchedCenter.requests.isEmpty)
    }

    func testRestartPreservesCurrentPendingRequestWithoutSchedulingDuplicate() async throws {
        let suiteName = "dev.quotapulse.tests.notifications.pending-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        let key = "pending-restart"
        let states = [makeState(resetAfter: 6 * 3_600)]

        do {
            let service = NotificationService(
                center: center,
                stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key)
            )
            await service.evaluate(states, now: now)
        }
        let pendingIdentifier = try XCTUnwrap(center.pendingIdentifiers.first)
        XCTAssertTrue(pendingIdentifier.contains(".lifecycle-0."))

        let relaunchedService = NotificationService(
            center: center,
            stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key)
        )
        await relaunchedService.evaluate(states, now: now.addingTimeInterval(60))

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.pendingIdentifiers, [pendingIdentifier])
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
    }

    func testDisablingProviderAfterRestartRemovesPreviousProcessPendingRequest() async {
        let suiteName = "dev.quotapulse.tests.notifications.disable-after-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        let key = "disable-after-restart"

        do {
            let service = NotificationService(
                center: center,
                stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key)
            )
            await service.evaluate([makeState(resetAfter: 6 * 3_600)], now: now)
        }
        XCTAssertEqual(center.pendingIdentifiers.count, 1)

        let relaunchedService = NotificationService(
            center: center,
            stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key)
        )
        relaunchedService.providerEnablementDidChange(.codex, isEnabled: false)
        await relaunchedService.waitForProviderCleanupForTesting(.codex)

        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
    }

    func testLaunchPreparationRemovesPendingRequestForProviderDisabledBeforeRestart() async {
        let suiteName = "dev.quotapulse.tests.notifications.disabled-launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setProvider(.codex, enabled: false)
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        let codexIdentifier = "quotapulse.reset.codex.lifecycle-0.primary.123.long.360m"
        let claudeIdentifier = "quotapulse.reset.claude.lifecycle-0.primary.123.long.360m"
        center.pendingIdentifiers = [codexIdentifier, claudeIdentifier]
        let service = NotificationService(
            center: center,
            stateStore: UserDefaultsNotificationStateStore(
                defaults: defaults,
                key: "disabled-launch"
            ),
            preferences: preferences
        )

        service.prepareForLaunch()
        await center.waitForRemovalCount(1)

        XCTAssertEqual(center.pendingIdentifiers, [claudeIdentifier])
        XCTAssertEqual(center.removedIdentifiers, [[codexIdentifier]])
    }

    func testRestartUsesPersistedLifecycleGenerationToRemoveStalePendingRequest() async {
        let suiteName = "dev.quotapulse.tests.notifications.lifecycle-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        let key = "lifecycle-restart"

        do {
            let service = NotificationService(
                center: center,
                stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key),
                preferences: preferences
            )
            service.providerEnablementDidChange(.codex, isEnabled: false)
            await service.waitForProviderCleanupForTesting(.codex)
            service.providerEnablementDidChange(.codex, isEnabled: true)
        }

        let staleIdentifier = "quotapulse.reset.codex.lifecycle-0.primary.123.long.360m"
        let currentIdentifier = "quotapulse.reset.codex.lifecycle-2.primary.456.long.360m"
        center.pendingIdentifiers = [staleIdentifier, currentIdentifier]

        let relaunchedService = NotificationService(
            center: center,
            stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key),
            preferences: preferences
        )
        await relaunchedService.evaluate([], now: now)

        XCTAssertEqual(center.pendingIdentifiers, [currentIdentifier])
        XCTAssertEqual(center.removedIdentifiers.last, [staleIdentifier])
    }

    func testRestartLifecycleReconciliationRemainsProviderScoped() async {
        let sharedState = SharedNotificationState()
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true

        do {
            let service = NotificationService(
                center: center,
                stateStore: TestNotificationStateStore(sharedState: sharedState)
            )
            service.providerEnablementDidChange(.codex, isEnabled: false)
            await service.waitForProviderCleanupForTesting(.codex)
            service.providerEnablementDidChange(.codex, isEnabled: true)
        }

        let staleCodexIdentifier =
            "quotapulse.reset.codex.lifecycle-0.primary.123.long.360m"
        let currentClaudeIdentifier =
            "quotapulse.reset.claude.lifecycle-0.primary.123.long.360m"
        center.pendingIdentifiers = [staleCodexIdentifier, currentClaudeIdentifier]

        let relaunchedService = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(sharedState: sharedState)
        )
        await relaunchedService.evaluate([], now: now)

        XCTAssertEqual(center.pendingIdentifiers, [currentClaudeIdentifier])
        XCTAssertEqual(center.removedIdentifiers.last, [staleCodexIdentifier])
    }

    func testGenuineLocalResetEmitsOneLocalizedCompletedNotification() async throws {
        let (preferences, defaults, suiteName) = makePreferencesWithRemindersDisabled()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = TestUserNotificationCenter()
        let store = TestNotificationStateStore()
        let service = NotificationService(
            center: center,
            stateStore: store,
            preferences: preferences,
            locale: Locale(identifier: "en")
        )
        let oldReset = now.addingTimeInterval(60 * 60)

        await service.evaluate(
            [makeState(
                resetAt: oldReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 82,
                capturedAt: now
            )],
            now: now
        )
        let afterCapture = oldReset.addingTimeInterval(30)
        let refreshedState = makeState(
            resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
            duration: .seconds(5 * 60 * 60),
            usedPercentage: 1,
            capturedAt: afterCapture
        )
        await service.evaluate([refreshedState], now: afterCapture)
        await service.evaluate(
            [makeState(
                resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 1,
                capturedAt: afterCapture.addingTimeInterval(60)
            )],
            now: afterCapture.addingTimeInterval(60)
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(request.identifier.hasPrefix("quotapulse.reset-completed.codex."))
        XCTAssertEqual(request.title, "Codex quota reset")
        XCTAssertEqual(request.body, "Your 5-hour quota has refreshed.")
    }

    func testRestartDoesNotDuplicateCompletedResetNotification() async {
        let suiteName = "dev.quotapulse.tests.local-reset-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        disableAllReminders(in: preferences)
        let key = "local-reset-deduplication"
        let firstCenter = TestUserNotificationCenter()
        let firstService = NotificationService(
            center: firstCenter,
            stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key),
            preferences: preferences,
            locale: Locale(identifier: "en")
        )
        let oldReset = now.addingTimeInterval(60 * 60)
        await firstService.evaluate(
            [makeState(
                resetAt: oldReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 82,
                capturedAt: now
            )],
            now: now
        )
        let afterCapture = oldReset.addingTimeInterval(30)
        let nextReset = oldReset.addingTimeInterval(5 * 60 * 60)
        await firstService.evaluate(
            [makeState(
                resetAt: nextReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 1,
                capturedAt: afterCapture
            )],
            now: afterCapture
        )

        let relaunchedCenter = TestUserNotificationCenter()
        let relaunchedService = NotificationService(
            center: relaunchedCenter,
            stateStore: UserDefaultsNotificationStateStore(defaults: defaults, key: key),
            preferences: preferences,
            locale: Locale(identifier: "en")
        )
        await relaunchedService.evaluate(
            [makeState(
                resetAt: nextReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 1,
                capturedAt: afterCapture.addingTimeInterval(60)
            )],
            now: afterCapture.addingTimeInterval(60)
        )

        XCTAssertEqual(firstCenter.requests.count, 1)
        XCTAssertTrue(relaunchedCenter.requests.isEmpty)
    }

    func testRepeatedManualRefreshDoesNotDuplicateNotification() async {
        let center = TestUserNotificationCenter()
        let notificationService = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore()
        )
        let provider = StaticNotificationProvider(
            snapshot: makeState(resetAfter: 6 * 3_600).snapshot!
        )
        let currentDate = now
        let model = AppModel(
            providerIDs: [.codex],
            refreshCoordinator: RefreshCoordinator(
                usageService: UsageService(providers: [provider])
            ),
            notificationService: notificationService,
            now: { currentDate },
            observesLifecycle: false
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(center.requests.count, 1)
        let fetchCount = await provider.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testGenuinelyNewResetWindowBecomesEligibleAfterPreviousResetPasses() async throws {
        let (service, center, _) = makeService()
        let firstReset = now.addingTimeInterval(6 * 3_600)
        await service.evaluate(
            [makeState(resetAt: firstReset, capturedAt: now)],
            now: now
        )

        let nextNow = firstReset.addingTimeInterval(60)
        let nextReset = nextNow.addingTimeInterval(6 * 3_600)
        await service.evaluate(
            [makeState(resetAt: nextReset, capturedAt: nextNow)],
            now: nextNow
        )

        XCTAssertEqual(center.requests.count, 2)
        XCTAssertNotEqual(center.requests[0].identifier, center.requests[1].identifier)
    }

    func testResetTimestampMoveWithinActiveWindowDoesNotReissueThreshold() async {
        let (service, center, _) = makeService()
        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600)],
            now: now
        )

        let laterCapture = now.addingTimeInterval(60)
        await service.evaluate(
            [makeState(
                resetAt: now.addingTimeInterval(8 * 3_600),
                capturedAt: laterCapture
            )],
            now: laterCapture
        )
        let crossedAgain = now.addingTimeInterval(2 * 3_600 + 60)
        await service.evaluate(
            [makeState(
                resetAt: now.addingTimeInterval(8 * 3_600),
                capturedAt: crossedAgain
            )],
            now: crossedAgain
        )

        XCTAssertEqual(center.requests.count, 1)
    }

    func testResetTimestampMoveEarlierWithinActiveWindowUsesNewThresholdTiming() async throws {
        let (service, center, store) = makeService()
        await service.evaluate(
            [makeState(resetAfter: 30 * 3_600)],
            now: now
        )
        let originalIdentity = try XCTUnwrap(
            store.state.entries.first?.resetWindowIdentityMinute
        )

        let nextNow = now.addingTimeInterval(60)
        await service.evaluate(
            [makeState(
                resetAt: nextNow.addingTimeInterval(5 * 3_600),
                capturedAt: nextNow
            )],
            now: nextNow
        )

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.title, "Codex Weekly quota resets in 6 hours")
        XCTAssertEqual(
            store.state.entries.first?.resetWindowIdentityMinute,
            originalIdentity
        )
    }

    func testPassedResetWindowDoesNotNotify() async {
        let (service, center, _) = makeService()

        await service.evaluate(
            [makeState(resetAfter: -60)],
            now: now
        )

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testMissingResetTimestampDoesNotNotify() async {
        let (service, center, _) = makeService()

        await service.evaluate(
            [makeState(resetAt: nil, capturedAt: now)],
            now: now
        )

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testMissingUsagePercentageSendsSimpleResetReminder() async throws {
        let (service, center, _) = makeService()

        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600, usedPercentage: nil)],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.title, "Codex Weekly quota resets in 6 hours")
        XCTAssertEqual(request.body, "Your quota window is approaching its scheduled reset.")
        XCTAssertFalse(request.body.contains("%"))
    }

    func testStaleSnapshotDoesNotNotifyOrRequestPermission() async {
        let (service, center, _) = makeService(status: .notDetermined)

        await service.evaluate(
            [makeState(
                resetAfter: 6 * 3_600,
                capturedAt: now.addingTimeInterval(-(16 * 60))
            )],
            now: now
        )

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    func testMockSnapshotDoesNotNotifyOrRequestPermission() async {
        let (service, center, _) = makeService(status: .notDetermined)
        let realState = makeState(resetAfter: 6 * 3_600)
        let snapshot = realState.snapshot!
        let mockState = ProviderState(
            providerID: realState.providerID,
            status: .available,
            snapshot: ProviderUsageSnapshot(
                providerID: snapshot.providerID,
                windows: snapshot.windows,
                capturedAt: snapshot.capturedAt,
                source: UsageSource(kind: .mock, label: "Test", documentationURL: nil)
            )
        )

        await service.evaluate([mockState], now: now)

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    func testPermanentlyUnavailableProviderDoesNotNotify() async {
        let (service, center, _) = makeService()
        let staleCachedState = makeState(
            status: .notInstalled,
            resetAfter: 6 * 3_600
        )

        await service.evaluate([staleCachedState], now: now)

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testDeniedPermissionDoesNotNotifyOrPromptAgain() async {
        let (service, center, store) = makeService(status: .denied)

        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600)],
            now: now
        )

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(store.state.entries.first?.emittedThresholdMinutes, [])
    }

    func testDisabledNotificationPreferenceSuppressesNotification() async {
        let suiteName = "dev.quotapulse.tests.notifications.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setNotificationsEnabled(false)
        let center = TestUserNotificationCenter(status: .notDetermined)
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences
        )

        await service.evaluate([makeState(resetAfter: 6 * 3_600)], now: now)

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    func testDisabledProviderSchedulesNoNotificationWhileAnotherProviderStillDoes() async {
        let suiteName = "dev.quotapulse.tests.notifications.provider-disabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setProvider(.codex, enabled: false)
        let center = TestUserNotificationCenter()
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences,
            locale: Locale(identifier: "en")
        )

        await service.evaluate(
            [
                makeState(providerID: .codex, resetAfter: 6 * 3_600),
                makeState(providerID: .claude, resetAfter: 6 * 3_600),
            ],
            now: now
        )

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.title, "Claude Code Weekly quota resets in 6 hours")
    }

    func testDisablingProviderCancelsOnlyThatProvidersPendingQuotaRequests() async {
        let center = TestUserNotificationCenter()
        center.pendingIdentifiers = [
            "quotapulse.reset.codex.primary.123.long.360m",
            "quotapulse.reset-completed.codex.primary.123",
            "quotapulse.reset.claude.primary.123.long.360m",
            "quotapulse.reset-completed.claude.primary.123",
            "another-app.request",
        ]
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore()
        )

        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForRemovalCount(1)

        XCTAssertEqual(
            center.removedIdentifiers,
            [[
                "quotapulse.reset.codex.primary.123.long.360m",
                "quotapulse.reset-completed.codex.primary.123",
            ]]
        )
    }

    func testDisableThenImmediateEnableInvalidatesStaleCleanup() async {
        let suiteName = "dev.quotapulse.tests.notifications.cleanup-race.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences,
            locale: Locale(identifier: "en")
        )
        await service.evaluate([], now: now)
        center.blocksPendingRequestLookups = true

        preferences.setProvider(.codex, enabled: false)
        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForPendingLookupCount(2)
        preferences.setProvider(.codex, enabled: true)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        await service.evaluate([makeState(resetAfter: 6 * 3_600)], now: now)
        let currentIdentifier = try? XCTUnwrap(center.requests.last?.identifier)

        center.resumePendingRequestLookups()
        await service.waitForProviderCleanupForTesting(.codex)

        XCTAssertNotNil(currentIdentifier)
        XCTAssertEqual(center.pendingIdentifiers, [currentIdentifier].compactMap { $0 })
        XCTAssertFalse(center.removedIdentifiers.joined().contains(currentIdentifier ?? ""))
    }

    func testDisableEnableDisableConvergesToDisabledAndRemovesEnabledGeneration() async {
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        center.blocksPendingRequestLookups = true
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            locale: Locale(identifier: "en")
        )

        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForPendingLookupCount(1)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        center.pendingIdentifiers = [
            "quotapulse.reset.codex.lifecycle-2.primary.123.long.360m",
        ]
        service.providerEnablementDidChange(.codex, isEnabled: false)

        center.resumePendingRequestLookups()
        await service.waitForProviderCleanupForTesting(.codex)

        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
        XCTAssertEqual(
            center.removedIdentifiers,
            [["quotapulse.reset.codex.lifecycle-2.primary.123.long.360m"]]
        )
    }

    func testDisableEnableDisableEnablePreservesOnlyCurrentGeneration() async {
        let center = TestUserNotificationCenter()
        center.tracksRequestsAsPending = true
        center.blocksPendingRequestLookups = true
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            locale: Locale(identifier: "en")
        )

        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForPendingLookupCount(1)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        service.providerEnablementDidChange(.codex, isEnabled: false)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        let staleIdentifier = "quotapulse.reset.codex.lifecycle-2.primary.123.long.360m"
        let currentIdentifier = "quotapulse.reset.codex.lifecycle-4.primary.456.long.360m"
        center.pendingIdentifiers = [staleIdentifier, currentIdentifier]

        center.resumePendingRequestLookups()
        await service.waitForProviderCleanupForTesting(.codex)

        XCTAssertEqual(center.pendingIdentifiers, [currentIdentifier])
        XCTAssertEqual(center.removedIdentifiers, [[staleIdentifier]])
    }

    func testRapidProviderTransitionsCoalesceToOneCleanupLookup() async {
        let center = TestUserNotificationCenter()
        center.blocksPendingRequestLookups = true
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore()
        )

        for index in 0..<100 {
            service.providerEnablementDidChange(.codex, isEnabled: index.isMultiple(of: 2))
        }
        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForPendingLookupCount(1)

        XCTAssertEqual(center.pendingLookupCount, 1)
        XCTAssertEqual(service.providerCleanupTaskCountForTesting, 1)

        center.resumePendingRequestLookups()
        await service.waitForProviderCleanupForTesting(.codex)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        XCTAssertEqual(center.pendingLookupCount, 1)
        XCTAssertEqual(service.providerCleanupTaskCountForTesting, 0)
    }

    func testDisableReenableRetainsReminderDeduplication() async {
        let (service, center, _) = makeService()
        center.tracksRequestsAsPending = true
        let state = makeState(resetAfter: 6 * 3_600)

        await service.evaluate([state], now: now)
        service.providerEnablementDidChange(.codex, isEnabled: false)
        await center.waitForRemovalCount(1)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        await service.evaluate([state], now: now.addingTimeInterval(60))

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
    }

    func testReenableRebaselinesProviderWithoutFalseCompletedResetNotification() async {
        let (preferences, defaults, suiteName) = makePreferencesWithRemindersDisabled()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = TestUserNotificationCenter()
        let store = TestNotificationStateStore()
        let service = NotificationService(
            center: center,
            stateStore: store,
            preferences: preferences,
            locale: Locale(identifier: "en")
        )
        let oldReset = now.addingTimeInterval(60 * 60)
        await service.evaluate(
            [makeState(
                resetAt: oldReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 82,
                capturedAt: now
            )],
            now: now
        )
        XCTAssertEqual(store.localResetState.entries.map(\.providerID), [.codex])

        preferences.setProvider(.codex, enabled: false)
        service.providerEnablementDidChange(.codex, isEnabled: false)
        XCTAssertTrue(store.localResetState.entries.isEmpty)
        await center.waitForPendingLookupCount(2)
        preferences.setProvider(.codex, enabled: true)
        service.providerEnablementDidChange(.codex, isEnabled: true)
        XCTAssertTrue(store.localResetState.entries.isEmpty)

        let afterCapture = oldReset.addingTimeInterval(30)
        let nextReset = oldReset.addingTimeInterval(5 * 60 * 60)
        await service.evaluate(
            [makeState(
                resetAt: nextReset,
                duration: .seconds(5 * 60 * 60),
                usedPercentage: 1,
                capturedAt: afterCapture
            )],
            now: afterCapture
        )

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(store.localResetState.entries.map(\.providerID), [.codex])
    }

    func testDisabledThresholdDoesNotScheduleNotification() async {
        let suiteName = "dev.quotapulse.tests.notifications.threshold.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        preferences.setReminder(windowClass: .long, minutes: 24 * 60, enabled: false)
        preferences.setReminder(windowClass: .long, minutes: 6 * 60, enabled: false)
        let center = TestUserNotificationCenter()
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences
        )

        await service.evaluate([makeState(resetAfter: 6 * 3_600)], now: now)

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testDisablingNotificationsCancelsPendingResetRequestsOnly() async {
        let suiteName = "dev.quotapulse.tests.notifications.cancellation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        let center = TestUserNotificationCenter()
        center.pendingIdentifiers = [
            "quotapulse.reset.codex.primary.123.24h",
            "quotapulse.reset.claude.primary.123.6h",
            "another-app.request",
        ]
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences
        )
        preferences.setNotificationsEnabled(false)

        await service.preferencesDidChange()

        XCTAssertEqual(
            center.removedIdentifiers,
            [[
                "quotapulse.reset.codex.primary.123.24h",
                "quotapulse.reset.claude.primary.123.6h",
            ]]
        )
    }

    func testDisablingOneThresholdCancelsOnlyThatPendingThreshold() async {
        let suiteName = "dev.quotapulse.tests.notifications.threshold-cancellation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SettingsStore(defaults: defaults)
        let center = TestUserNotificationCenter()
        center.pendingIdentifiers = [
            "quotapulse.reset.codex.primary.123.long.1440m",
            "quotapulse.reset.codex.primary.123.long.360m",
        ]
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            preferences: preferences
        )
        preferences.setReminder(windowClass: .long, minutes: 24 * 60, enabled: false)

        await service.preferencesDidChange()

        XCTAssertEqual(
            center.removedIdentifiers,
            [["quotapulse.reset.codex.primary.123.long.1440m"]]
        )
    }

    func testLegacyPendingThresholdIsRemovedBeforeEvaluation() async {
        let (service, center, _) = makeService()
        center.pendingIdentifiers = [
            "quotapulse.reset.codex.primary.123.6h",
            "another-app.request",
        ]

        await service.evaluate(
            [makeState(resetAfter: 5 * 3_600, duration: .seconds(5 * 3_600))],
            now: now
        )

        XCTAssertEqual(
            center.removedIdentifiers,
            [["quotapulse.reset.codex.primary.123.6h"]]
        )
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testLegacyPersistedThresholdsMigrateWithoutLosingDeduplication() throws {
        let suiteName = "dev.quotapulse.tests.notifications.legacy-state.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let json = """
        {
          "schemaVersion": 1,
          "entries": [{
            "providerID": "codex",
            "windowID": "primary",
            "resetWindowIdentityMinute": 123,
            "currentResetMinute": 123,
            "emittedThresholdHours": [24, 6, 1],
            "lastObservedMinute": 100
          }]
        }
        """
        defaults.set(Data(json.utf8), forKey: "deduplication")

        let store = UserDefaultsNotificationStateStore(
            defaults: defaults,
            key: "deduplication"
        )

        XCTAssertEqual(
            store.load().entries.first?.emittedThresholdMinutes,
            [24 * 60, 6 * 60, 60]
        )
    }

    func testEligibleSnapshotDoesNotRequestUndeterminedPermission() async {
        let (service, center, _) = makeService(status: .notDetermined)

        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600)],
            now: now
        )
        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600)],
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertTrue(center.requests.isEmpty)

        let authorizationStatus = await service.requestAuthorization()
        XCTAssertEqual(authorizationStatus, .authorized)
        await service.evaluate(
            [makeState(resetAfter: 6 * 3_600)],
            now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.requests.count, 1)
    }

    func testOneProviderNotificationStateDoesNotAffectAnotherProvider() async {
        let (service, center, _) = makeService()
        let states = [
            makeState(providerID: .codex, windowID: "primary", resetAfter: 6 * 3_600),
            makeState(providerID: .claude, windowID: "five-hour", resetAfter: 6 * 3_600),
        ]

        await service.evaluate(states, now: now)
        await service.evaluate(states, now: now.addingTimeInterval(60))

        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(Set(center.requests.map(\.title)), [
            "Codex Weekly quota resets in 6 hours",
            "Claude Code Weekly quota resets in 6 hours",
        ])
    }

    func testTraditionalChineseNotificationFormatsThresholdAndRemainingQuota() async throws {
        let center = TestUserNotificationCenter()
        let service = NotificationService(
            center: center,
            stateStore: TestNotificationStateStore(),
            locale: Locale(identifier: "zh-Hant-TW")
        )

        await service.evaluate(
            [makeState(resetAfter: 60 * 60, duration: .seconds(5 * 3_600), usedPercentage: 39)],
            now: now
        )

        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.title, "Codex 5 小時額度將在 1 小時後重置")
        XCTAssertEqual(request.body, "你還有 61% 的配額尚未使用。")
    }

    func testNotificationStateRemainsBounded() {
        let policy = ResetNotificationPolicy.v01
        let states = (0..<40).map { index in
            makeState(windowID: "window-\(index)", resetAfter: 6 * 3_600)
        }

        let evaluation = policy.evaluate(
            states,
            state: NotificationDeduplicationState(),
            now: now
        )

        XCTAssertEqual(evaluation.state.entries.count, 32)
        XCTAssertEqual(evaluation.decisions.count, 32)
    }

    func testPersistedNotificationStateRespectsEncodedByteLimit() throws {
        let suiteName = "dev.quotapulse.tests.notifications.byte-limit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "notification.byte-limit"
        let store = UserDefaultsNotificationStateStore(defaults: defaults, key: key)
        let entries = (0..<2).map { index in
            NotificationDeduplicationState.Entry(
                providerID: .codex,
                windowID: "window-\(index)-" + String(repeating: "x", count: 40_000),
                resetWindowIdentityMinute: Int64(index),
                currentResetMinute: Int64(index),
                emittedThresholdMinutes: [60],
                lastObservedMinute: Int64(2 - index)
            )
        }

        store.save(NotificationDeduplicationState(entries: entries))

        let data = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertLessThanOrEqual(data.count, 64 * 1_024)
        XCTAssertEqual(store.load().entries, [entries[0]])
    }

    func testProviderLifecyclePersistenceIsBoundedToKnownProviders() {
        let suiteName = "dev.quotapulse.tests.notifications.lifecycle-bounds.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "lifecycle-bounds"
        let lifecycleKey = "\(key).provider-lifecycle.v1"
        defaults.set(
            ["codex": NSNumber(value: 7), "unknown": NSNumber(value: 99)],
            forKey: lifecycleKey
        )
        let store = UserDefaultsNotificationStateStore(defaults: defaults, key: key)

        XCTAssertEqual(store.loadProviderLifecycleGenerations(), [.codex: 7])

        store.saveProviderLifecycleGenerations([.codex: 8, .claude: 3])
        let persisted = defaults.dictionary(forKey: lifecycleKey)
        XCTAssertEqual(persisted?.count, ProviderID.allCases.count)
        XCTAssertNil(persisted?["unknown"])
    }

    #if DEBUG
    func testDevelopmentNotificationRequestsAuthorizationAndSchedulesFiveSecondsAhead() async throws {
        let (service, center, _) = makeService(status: .notDetermined)

        try await service.sendTestNotification()

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.removedIdentifiers, [["quotapulse.test-notification"]])
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.identifier, "quotapulse.test-notification")
        XCTAssertEqual(request.title, "QuotaMew")
        XCTAssertEqual(request.body, "Local notifications are ready.")
        XCTAssertEqual(request.delay, 5)
    }

    func testLiveDevelopmentNotificationWhenExplicitlyEnabled() async throws {
        let debugBundleIdentifier = "dev.quotapulse.development.app"
        let isEnabled = ProcessInfo.processInfo.environment["QUOTAPULSE_RUN_LIVE_NOTIFICATION_TEST"] == "1"
            || UserDefaults.standard.bool(forKey: "runLiveNotificationTest")
        guard isEnabled else {
            throw XCTSkip("Set QUOTAPULSE_RUN_LIVE_NOTIFICATION_TEST=1 for the opt-in system notification check.")
        }
        XCTAssertEqual(Bundle.main.bundleIdentifier, debugBundleIdentifier)

        let identifier = "quotapulse.test-notification"
        let systemCenter = UNUserNotificationCenter.current()
        systemCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        systemCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        let service = NotificationService(
            center: UserNotificationCenterClient(center: systemCenter),
            stateStore: TestNotificationStateStore()
        )

        try await service.sendTestNotification()
        try await Task.sleep(for: .seconds(6))

        let delivered = await systemCenter.deliveredNotifications()
        XCTAssertTrue(delivered.contains { $0.request.identifier == identifier })
        systemCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    #endif

    private func makeService(
        status: NotificationAuthorizationStatus = .authorized
    ) -> (NotificationService, TestUserNotificationCenter, TestNotificationStateStore) {
        let center = TestUserNotificationCenter(status: status)
        let store = TestNotificationStateStore()
        return (
            NotificationService(
                center: center,
                stateStore: store,
                locale: Locale(identifier: "en")
            ),
            center,
            store
        )
    }

    private func makePreferencesWithRemindersDisabled() -> (SettingsStore, UserDefaults, String) {
        let suiteName = "dev.quotapulse.tests.local-reset-preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = SettingsStore(defaults: defaults)
        disableAllReminders(in: preferences)
        return (preferences, defaults, suiteName)
    }

    private func disableAllReminders(in preferences: SettingsStore) {
        preferences.setReminder(windowClass: .short, minutes: 60, enabled: false)
        preferences.setReminder(windowClass: .short, minutes: 30, enabled: false)
        preferences.setReminder(windowClass: .long, minutes: 24 * 60, enabled: false)
        preferences.setReminder(windowClass: .long, minutes: 6 * 60, enabled: false)
        preferences.setReminder(windowClass: .long, minutes: 60, enabled: false)
    }

    private func makeState(
        providerID: ProviderID = .codex,
        status: ProviderStatus = .available,
        windowID: String = "primary",
        resetAfter: TimeInterval,
        duration: Duration = .seconds(7 * 24 * 3_600),
        usedPercentage: Double? = 39,
        capturedAt: Date? = nil
    ) -> ProviderState {
        makeState(
            providerID: providerID,
            status: status,
            windowID: windowID,
            resetAt: now.addingTimeInterval(resetAfter),
            duration: duration,
            usedPercentage: usedPercentage,
            capturedAt: capturedAt ?? now
        )
    }

    private func makeState(
        providerID: ProviderID = .codex,
        status: ProviderStatus = .available,
        windowID: String = "primary",
        resetAt: Date?,
        duration: Duration = .seconds(7 * 24 * 3_600),
        usedPercentage: Double? = 39,
        capturedAt: Date
    ) -> ProviderState {
        ProviderState(
            providerID: providerID,
            status: status,
            snapshot: ProviderUsageSnapshot(
                providerID: providerID,
                windows: [
                    UsageWindow(
                        id: windowID,
                        label: "Quota window",
                        usedPercentage: usedPercentage,
                        resetAt: resetAt,
                        duration: duration
                    )
                ],
                capturedAt: capturedAt,
                source: UsageSource(
                    kind: providerID == .codex ? .codexAppServer : .claudeStatusLineSnapshot,
                    label: "Test provider",
                    documentationURL: nil
                )
            )
        )
    }
}

@MainActor
private final class TestUserNotificationCenter: UserNotificationCentering {
    private(set) var status: NotificationAuthorizationStatus
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [LocalNotificationRequest] = []
    private(set) var removedIdentifiers: [[String]] = []
    var authorizationResult = true
    var yieldsBeforeReturningAuthorizationStatus = false
    var onRequestAuthorization: (() -> Void)?
    var pendingIdentifiers: [String] = []
    var tracksRequestsAsPending = false
    var blocksPendingRequestLookups = false
    private(set) var pendingLookupCount = 0
    private var pendingLookupContinuations: [CheckedContinuation<Void, Never>] = []
    private var pendingLookupWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var removalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(status: NotificationAuthorizationStatus = .authorized) {
        self.status = status
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        if yieldsBeforeReturningAuthorizationStatus {
            await Task.yield()
        }
        return status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        onRequestAuthorization?()
        status = authorizationResult ? .authorized : .denied
        return authorizationResult
    }

    func add(_ request: LocalNotificationRequest) async throws {
        requests.append(request)
        if tracksRequestsAsPending {
            pendingIdentifiers.removeAll { $0 == request.identifier }
            pendingIdentifiers.append(request.identifier)
        }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(identifiers)
        if tracksRequestsAsPending {
            pendingIdentifiers.removeAll { identifiers.contains($0) }
        }
        resumeRemovalWaiters()
    }

    func pendingRequestIdentifiers() async -> [String] {
        pendingLookupCount += 1
        resumePendingLookupWaiters()
        if blocksPendingRequestLookups {
            await withCheckedContinuation { continuation in
                pendingLookupContinuations.append(continuation)
            }
        }
        return pendingIdentifiers
    }

    func waitForPendingLookupCount(_ count: Int) async {
        guard pendingLookupCount < count else { return }
        await withCheckedContinuation { continuation in
            pendingLookupWaiters.append((count, continuation))
        }
    }

    func waitForRemovalCount(_ count: Int) async {
        guard removedIdentifiers.count < count else { return }
        await withCheckedContinuation { continuation in
            removalWaiters.append((count, continuation))
        }
    }

    func resumePendingRequestLookups() {
        blocksPendingRequestLookups = false
        let continuations = pendingLookupContinuations
        pendingLookupContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumePendingLookupWaiters() {
        let ready = pendingLookupWaiters.filter { $0.0 <= pendingLookupCount }
        pendingLookupWaiters.removeAll { $0.0 <= pendingLookupCount }
        ready.forEach { $0.1.resume() }
    }

    private func resumeRemovalWaiters() {
        let ready = removalWaiters.filter { $0.0 <= removedIdentifiers.count }
        removalWaiters.removeAll { $0.0 <= removedIdentifiers.count }
        ready.forEach { $0.1.resume() }
    }
}

private final class TestDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}

@MainActor
private final class SharedNotificationState {
    var state = NotificationDeduplicationState()
    var localResetState = LocalResetDetectionState()
    var providerLifecycleGenerations: [ProviderID: UInt64] = [:]
}

@MainActor
private final class TestNotificationStateStore: NotificationStateStoring {
    private let sharedState: SharedNotificationState

    var state: NotificationDeduplicationState {
        sharedState.state
    }

    var localResetState: LocalResetDetectionState {
        sharedState.localResetState
    }

    init(sharedState: SharedNotificationState = SharedNotificationState()) {
        self.sharedState = sharedState
    }

    func load() -> NotificationDeduplicationState {
        sharedState.state
    }

    func save(_ state: NotificationDeduplicationState) {
        sharedState.state = state
    }

    func loadLocalResetDetectionState() -> LocalResetDetectionState {
        sharedState.localResetState
    }

    func saveLocalResetDetectionState(_ state: LocalResetDetectionState) {
        sharedState.localResetState = state
    }

    func loadProviderLifecycleGenerations() -> [ProviderID: UInt64] {
        sharedState.providerLifecycleGenerations
    }

    func saveProviderLifecycleGenerations(_ generations: [ProviderID: UInt64]) {
        sharedState.providerLifecycleGenerations = generations
    }
}

private actor StaticNotificationProvider: UsageProvider {
    nonisolated let id = ProviderID.codex
    private let snapshot: ProviderUsageSnapshot
    private(set) var fetchCount = 0

    init(snapshot: ProviderUsageSnapshot) {
        self.snapshot = snapshot
    }

    func fetchUsage() async throws -> ProviderUsageSnapshot {
        fetchCount += 1
        return snapshot
    }
}
