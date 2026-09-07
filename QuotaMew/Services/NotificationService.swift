import Foundation
import UserNotifications

@MainActor
protocol NotificationServicing: AnyObject {
    func prepareForLaunch()
    func evaluate(_ providerStates: [ProviderState], now: Date) async
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func preferencesDidChange() async
    func providerEnablementDidChange(
        _ providerID: ProviderID,
        isEnabled: Bool
    )

    #if DEBUG
    func sendTestNotification() async throws
    func updateRuntimeDiagnostics() async
    #endif
}

extension NotificationServicing {
    func prepareForLaunch() {}
    func authorizationStatus() async -> NotificationAuthorizationStatus { .notDetermined }
    func preferencesDidChange() async {}
    func providerEnablementDidChange(
        _ providerID: ProviderID,
        isEnabled: Bool
    ) {}

    #if DEBUG
    func updateRuntimeDiagnostics() async {}
    #endif
}

#if DEBUG
enum NotificationServiceError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            String(localized: "Notification permission was not granted.")
        }
    }
}
#endif

enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct LocalNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let delay: TimeInterval
}

@MainActor
protocol UserNotificationCentering: AnyObject {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: LocalNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
    func pendingRequestIdentifiers() async -> [String]
}

extension UserNotificationCentering {
    func pendingRequestIdentifiers() async -> [String] { [] }
}

@MainActor
protocol NotificationStateStoring: AnyObject {
    func load() -> NotificationDeduplicationState
    func save(_ state: NotificationDeduplicationState)
    func loadLocalResetDetectionState() -> LocalResetDetectionState
    func saveLocalResetDetectionState(_ state: LocalResetDetectionState)
    func loadProviderLifecycleGenerations() -> [ProviderID: UInt64]
    func saveProviderLifecycleGenerations(_ generations: [ProviderID: UInt64])
}

extension NotificationStateStoring {
    func loadLocalResetDetectionState() -> LocalResetDetectionState {
        LocalResetDetectionState()
    }

    func saveLocalResetDetectionState(_ state: LocalResetDetectionState) {}

    func loadProviderLifecycleGenerations() -> [ProviderID: UInt64] { [:] }

    func saveProviderLifecycleGenerations(_ generations: [ProviderID: UInt64]) {}
}

@MainActor
final class NotificationService: NotificationServicing {
    private struct ProviderLifecycleState {
        var generation: UInt64 = 0
        var isEnabled: Bool
    }

    private let center: any UserNotificationCentering
    private let stateStore: any NotificationStateStoring
    private let policy: ResetNotificationPolicy
    private let localResetDetector: LocalResetDetector
    private let currentDate: @Sendable () -> Date
    private let locale: Locale
    private weak var preferences: (any AppPreferencesProviding)?
    private var evaluationGeneration: UInt64 = 0
    private var authorizationRequestTask: Task<Bool, Never>?
    private var providerLifecycleStates: [ProviderID: ProviderLifecycleState] = [:]
    private var providerCleanupTasks: [ProviderID: Task<Void, Never>] = [:]
    private var launchReconciliationTask: Task<Void, Never>?
    private var hasReconciledPendingRequestsForLaunch = false

    init(
        center: any UserNotificationCentering = UserNotificationCenterClient(),
        stateStore: any NotificationStateStoring = UserDefaultsNotificationStateStore(),
        policy: ResetNotificationPolicy = .v01,
        localResetDetector: LocalResetDetector = .standard,
        preferences: (any AppPreferencesProviding)? = nil,
        currentDate: @escaping @Sendable () -> Date = Date.init,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.center = center
        self.stateStore = stateStore
        self.policy = policy
        self.localResetDetector = localResetDetector
        self.preferences = preferences
        self.currentDate = currentDate
        self.locale = locale
        let persistedGenerations = stateStore.loadProviderLifecycleGenerations()
        self.providerLifecycleStates = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { providerID in
                (
                    providerID,
                    ProviderLifecycleState(
                        generation: persistedGenerations[providerID] ?? 0,
                        isEnabled: preferences?.isProviderEnabled(providerID) ?? true
                    )
                )
            }
        )
    }

    deinit {
        authorizationRequestTask?.cancel()
        providerCleanupTasks.values.forEach { $0.cancel() }
        launchReconciliationTask?.cancel()
    }

    func prepareForLaunch() {
        guard !hasReconciledPendingRequestsForLaunch,
              launchReconciliationTask == nil
        else { return }

        let center = center
        launchReconciliationTask = Task { @MainActor [weak self] in
            let identifiers = await center.pendingRequestIdentifiers()
            self?.completeLaunchReconciliation(identifiers: identifiers)
        }
    }

    func evaluate(_ providerStates: [ProviderState], now: Date) async {
        prepareForLaunch()
        await launchReconciliationTask?.value
        evaluationGeneration &+= 1
        let generation = evaluationGeneration
        let notificationPreferences = preferences?.notificationPreferences ?? .defaults
        let enabledStates = providerStates.filter {
            isProviderCurrentlyEnabled($0.providerID)
        }
        let providerGenerations = Dictionary(
            uniqueKeysWithValues: enabledStates.map {
                ($0.providerID, providerLifecycleGeneration(for: $0.providerID))
            }
        )

        let localResetEvaluation = localResetDetector.evaluate(
            enabledStates,
            state: stateStore.loadLocalResetDetectionState(),
            now: now
        )
        stateStore.saveLocalResetDetectionState(localResetEvaluation.state)

        // Keep the detector baseline current while notifications are disabled so
        // re-enabling cannot announce a reset that happened earlier.
        guard notificationPreferences.isEnabled else { return }

        let evaluationStartedAt = currentDate()
        let evaluation = policy.evaluate(
            enabledStates,
            state: stateStore.load(),
            now: now,
            enabledThresholdMinutes: notificationPreferences.enabledThresholdMinutes,
            locale: locale
        )
        stateStore.save(evaluation.state)

        let deliverableResets = localResetEvaluation.resets.filter {
            !UsageWindowPresentation(
                providerID: $0.identity.providerID,
                windowID: $0.identity.windowID,
                duration: $0.windowDuration
            ).isReserve
        }
        guard !evaluation.decisions.isEmpty || !deliverableResets.isEmpty else {
            return
        }
        guard (try? await isAuthorized(requestIfNeeded: true)) == true else { return }
        guard generation == evaluationGeneration, !Task.isCancelled else { return }

        // Authorization may leave the task suspended while the user decides. Re-run the
        // policy so a newer evaluation, a passed reset, or newly stale usage cannot send.
        let elapsed = max(currentDate().timeIntervalSince(evaluationStartedAt), 0)
        let deliveryNow = now.addingTimeInterval(elapsed)
        let validDeliveryStates = enabledStates.filter {
            isCurrentLifecycle(
                for: $0.providerID,
                generation: providerGenerations[$0.providerID]
            )
        }
        let deliveryEvaluation = policy.evaluate(
            validDeliveryStates,
            state: stateStore.load(),
            now: deliveryNow,
            enabledThresholdMinutes: notificationPreferences.enabledThresholdMinutes,
            locale: locale
        )
        stateStore.save(deliveryEvaluation.state)

        for reset in deliverableResets where localResetDetector.isFreshForDelivery(
            reset,
            now: deliveryNow
        ) {
            guard generation == evaluationGeneration, !Task.isCancelled else { return }
            guard isCurrentLifecycle(
                for: reset.identity.providerID,
                generation: providerGenerations[reset.identity.providerID]
            ) else { continue }
            let request = localResetRequest(
                for: reset,
                lifecycleGeneration: providerGenerations[reset.identity.providerID]
            )
            try? await center.add(request)
            removeIfStale(
                request,
                providerID: reset.identity.providerID,
                generation: providerGenerations[reset.identity.providerID]
            )
        }

        for decision in deliveryEvaluation.decisions {
            guard generation == evaluationGeneration, !Task.isCancelled else { return }
            guard isCurrentLifecycle(
                for: decision.providerID,
                generation: providerGenerations[decision.providerID]
            ) else { continue }

            var latestState = stateStore.load()
            // Claim before adding so an App restart cannot resend the same threshold.
            // A scheduling failure may drop this one reminder, but preserves at-most-once delivery.
            latestState.markEmitted(decision)
            stateStore.save(latestState)

            let request = LocalNotificationRequest(
                identifier: lifecycleScopedIdentifier(
                    decision.identifier,
                    providerID: decision.providerID,
                    generation: providerGenerations[decision.providerID]
                ),
                title: decision.title,
                body: decision.body,
                delay: 1
            )
            try? await center.add(request)
            removeIfStale(
                request,
                providerID: decision.providerID,
                generation: providerGenerations[decision.providerID]
            )
        }
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        await center.authorizationStatus()
    }

    func preferencesDidChange() async {
        evaluationGeneration &+= 1
        let notificationPreferences = preferences?.notificationPreferences ?? .defaults
        let identifiers = await center.pendingRequestIdentifiers().filter {
            $0.hasPrefix("quotapulse.reset.")
        }
        let identifiersToRemove: [String]
        if notificationPreferences.isEnabled {
            identifiersToRemove = identifiers.filter { identifier in
                guard identifier.hasPrefix("quotapulse.reset.") else { return false }
                guard let threshold = resetThreshold(from: identifier) else {
                    return isLegacyResetIdentifier(identifier)
                }
                return !notificationPreferences
                    .thresholds(for: threshold.windowClass)
                    .contains(threshold.minutes)
            }
        } else {
            identifiersToRemove = await center.pendingRequestIdentifiers().filter(
                isQuotaResetIdentifier
            )
        }
        if !identifiersToRemove.isEmpty {
            center.removePendingRequests(withIdentifiers: identifiersToRemove)
        }
    }

    func providerEnablementDidChange(
        _ providerID: ProviderID,
        isEnabled: Bool
    ) {
        var lifecycle = providerLifecycleStates[providerID]
            ?? ProviderLifecycleState(isEnabled: isEnabled)
        lifecycle.generation &+= 1
        lifecycle.isEnabled = isEnabled
        providerLifecycleStates[providerID] = lifecycle
        stateStore.saveProviderLifecycleGenerations(
            providerLifecycleStates.mapValues(\.generation)
        )

        // Enablement transitions always start this provider from a fresh detector baseline.
        // Reminder deduplication is retained so toggling a provider cannot duplicate an
        // already-delivered approaching-reset notification.
        var resetState = stateStore.loadLocalResetDetectionState()
        resetState.entries.removeAll { $0.providerID == providerID }
        stateStore.saveLocalResetDetectionState(resetState)

        guard !isEnabled, providerCleanupTasks[providerID] == nil else { return }
        let center = center
        providerCleanupTasks[providerID] = Task { @MainActor [weak self] in
            let identifiers = await center.pendingRequestIdentifiers()
            self?.completeProviderCleanup(providerID, identifiers: identifiers)
        }
    }

    #if DEBUG
    func sendTestNotification() async throws {
        guard try await isAuthorized(requestIfNeeded: true) else {
            throw NotificationServiceError.authorizationDenied
        }

        let request = LocalNotificationRequest(
            identifier: "quotapulse.test-notification",
            title: AppLocalization.string("QuotaMew", locale: locale),
            body: AppLocalization.string("Local notifications are ready.", locale: locale),
            delay: 5
        )
        center.removePendingRequests(withIdentifiers: [request.identifier])
        try await center.add(request)
    }

    func updateRuntimeDiagnostics() async {
        let pendingCount = await center.pendingRequestIdentifiers().count {
            $0.hasPrefix("quotapulse.")
        }
        RuntimeDiagnostics.shared.notificationsUpdated(
            pendingCount: pendingCount,
            deduplicationEntryCount: stateStore.load().entries.count
        )
    }

    func waitForProviderCleanupForTesting(_ providerID: ProviderID) async {
        await providerCleanupTasks[providerID]?.value
    }

    var providerCleanupTaskCountForTesting: Int {
        providerCleanupTasks.count
    }
    #endif

    private func isAuthorized(requestIfNeeded: Bool) async throws -> Bool {
        switch await center.authorizationStatus() {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard requestIfNeeded else { return false }
            if let authorizationRequestTask {
                return await authorizationRequestTask.value
            }

            let center = center
            let task = Task { @MainActor in
                (try? await center.requestAuthorization()) == true
            }
            authorizationRequestTask = task
            let isAuthorized = await task.value
            authorizationRequestTask = nil
            return isAuthorized
        }
    }

    private func completeLaunchReconciliation(identifiers: [String]) {
        launchReconciliationTask = nil
        hasReconciledPendingRequestsForLaunch = true

        let identifiersToRemove = identifiers.filter { identifier in
            guard let providerID = quotaResetProviderID(from: identifier) else {
                return false
            }
            guard isProviderCurrentlyEnabled(providerID) else { return true }
            return !isIdentifierFromCurrentLifecycle(identifier, providerID: providerID)
        }
        if !identifiersToRemove.isEmpty {
            center.removePendingRequests(withIdentifiers: identifiersToRemove)
        }
    }

    private func isLegacyResetIdentifier(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("quotapulse.reset.") else { return false }
        guard let suffix = identifier.split(separator: ".").last else { return false }
        return suffix.hasSuffix("h")
    }

    private func isQuotaResetIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("quotapulse.reset.")
            || identifier.hasPrefix("quotapulse.reset-completed.")
    }

    private func isQuotaResetIdentifier(
        _ identifier: String,
        for providerID: ProviderID
    ) -> Bool {
        identifier.hasPrefix("quotapulse.reset.\(providerID.rawValue).")
            || identifier.hasPrefix("quotapulse.reset-completed.\(providerID.rawValue).")
    }

    private func quotaResetProviderID(from identifier: String) -> ProviderID? {
        ProviderID.allCases.first { providerID in
            isQuotaResetIdentifier(identifier, for: providerID)
        }
    }

    private func providerLifecycleGeneration(for providerID: ProviderID) -> UInt64 {
        providerLifecycleStates[providerID]?.generation ?? 0
    }

    private func isProviderCurrentlyEnabled(_ providerID: ProviderID) -> Bool {
        providerLifecycleStates[providerID]?.isEnabled
            ?? preferences?.isProviderEnabled(providerID)
            ?? true
    }

    private func isCurrentLifecycle(
        for providerID: ProviderID,
        generation: UInt64?
    ) -> Bool {
        guard let generation else { return false }
        return isProviderCurrentlyEnabled(providerID)
            && providerLifecycleGeneration(for: providerID) == generation
    }

    private func completeProviderCleanup(
        _ providerID: ProviderID,
        identifiers: [String]
    ) {
        providerCleanupTasks[providerID] = nil

        let identifiersToRemove = identifiers.filter {
            guard isQuotaResetIdentifier($0, for: providerID) else { return false }
            guard isProviderCurrentlyEnabled(providerID) else { return true }
            return !isIdentifierFromCurrentLifecycle($0, providerID: providerID)
        }
        if !identifiersToRemove.isEmpty {
            center.removePendingRequests(withIdentifiers: identifiersToRemove)
        }
    }

    private func removeIfStale(
        _ request: LocalNotificationRequest,
        providerID: ProviderID,
        generation: UInt64?
    ) {
        guard !isCurrentLifecycle(for: providerID, generation: generation) else { return }
        center.removePendingRequests(withIdentifiers: [request.identifier])
    }

    private func isIdentifierFromCurrentLifecycle(
        _ identifier: String,
        providerID: ProviderID
    ) -> Bool {
        let generation = providerLifecycleGeneration(for: providerID)
        return identifier.hasPrefix(
            "quotapulse.reset.\(providerID.rawValue).lifecycle-\(generation)."
        ) || identifier.hasPrefix(
            "quotapulse.reset-completed.\(providerID.rawValue).lifecycle-\(generation)."
        )
    }

    private func lifecycleScopedIdentifier(
        _ identifier: String,
        providerID: ProviderID,
        generation: UInt64?
    ) -> String {
        guard let generation else { return identifier }
        let prefixes = [
            "quotapulse.reset.\(providerID.rawValue).",
            "quotapulse.reset-completed.\(providerID.rawValue).",
        ]
        guard let prefix = prefixes.first(where: { identifier.hasPrefix($0) }) else {
            return identifier
        }
        return prefix
            + "lifecycle-\(generation)."
            + identifier.dropFirst(prefix.count)
    }

    private func localResetRequest(
        for reset: DetectedQuotaReset,
        lifecycleGeneration: UInt64?
    ) -> LocalNotificationRequest {
        let identifier = [
            "quotapulse.reset-completed",
            reset.identity.providerID.rawValue,
            encodedIdentifierComponent(reset.identity.windowID),
            encodedIdentifierComponent(reset.identity.cycleIdentifier),
        ].joined(separator: ".")
        return LocalNotificationRequest(
            identifier: lifecycleScopedIdentifier(
                identifier,
                providerID: reset.identity.providerID,
                generation: lifecycleGeneration
            ),
            title: AppLocalization.resetCompletedTitle(
                providerName: reset.identity.providerID.displayName,
                locale: locale
            ),
            body: AppLocalization.resetCompletedBody(
                windowName: UsageWindowPresentation(
                    providerID: reset.identity.providerID,
                    windowID: reset.identity.windowID,
                    duration: reset.windowDuration
                ).displayName(locale: locale),
                locale: locale
            ),
            delay: 1
        )
    }

    private func encodedIdentifierComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func resetThreshold(
        from identifier: String
    ) -> (windowClass: NotificationWindowClass, minutes: Int)? {
        guard identifier.hasPrefix("quotapulse.reset.") else { return nil }
        let components = identifier.split(separator: ".")
        guard components.count >= 2 else { return nil }
        let minuteComponent = components[components.count - 1]
        let windowClassComponent = components[components.count - 2]
        guard
            minuteComponent.hasSuffix("m"),
            let minutes = Int(minuteComponent.dropLast()),
            let windowClass = NotificationWindowClass(rawValue: String(windowClassComponent))
        else {
            return nil
        }
        return (windowClass, minutes)
    }
}

private final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class UserNotificationCenterClient: UserNotificationCentering {
    private let center: UNUserNotificationCenter
    private let presentationDelegate: NotificationPresentationDelegate

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        let presentationDelegate = NotificationPresentationDelegate()
        self.presentationDelegate = presentationDelegate
        center.delegate = presentationDelegate
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(request.delay, 1),
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

@MainActor
final class UserDefaultsNotificationStateStore: NotificationStateStoring {
    private static let defaultKey = "notification.deduplication.v1"
    private static let maximumEncodedStateBytes = 64 * 1_024

    private let defaults: UserDefaults
    private let key: String
    private let localResetKey: String
    private let providerLifecycleKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
        self.localResetKey = "\(key).local-reset.v1"
        self.providerLifecycleKey = "\(key).provider-lifecycle.v1"
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> NotificationDeduplicationState {
        guard
            let data = defaults.data(forKey: key),
            data.count <= Self.maximumEncodedStateBytes,
            let state = try? decoder.decode(NotificationDeduplicationState.self, from: data),
            state.schemaVersion == NotificationDeduplicationState.currentSchemaVersion
        else {
            return NotificationDeduplicationState()
        }
        return state
    }

    func save(_ state: NotificationDeduplicationState) {
        var boundedState = state

        while let data = try? encoder.encode(boundedState) {
            if data.count <= Self.maximumEncodedStateBytes {
                defaults.set(data, forKey: key)
                return
            }

            guard !boundedState.entries.isEmpty else {
                defaults.removeObject(forKey: key)
                return
            }
            boundedState.entries.removeLast()
        }
    }

    func loadLocalResetDetectionState() -> LocalResetDetectionState {
        guard
            let data = defaults.data(forKey: localResetKey),
            data.count <= Self.maximumEncodedStateBytes,
            var state = try? decoder.decode(LocalResetDetectionState.self, from: data),
            state.schemaVersion == LocalResetDetectionState.currentSchemaVersion
        else {
            return LocalResetDetectionState()
        }
        state.entries = Array(state.entries.prefix(32))
        return state
    }

    func saveLocalResetDetectionState(_ state: LocalResetDetectionState) {
        var boundedState = state
        boundedState.entries = Array(boundedState.entries.prefix(32))

        while let data = try? encoder.encode(boundedState) {
            if data.count <= Self.maximumEncodedStateBytes {
                defaults.set(data, forKey: localResetKey)
                return
            }

            guard !boundedState.entries.isEmpty else {
                defaults.removeObject(forKey: localResetKey)
                return
            }
            boundedState.entries.removeLast()
        }
    }

    func loadProviderLifecycleGenerations() -> [ProviderID: UInt64] {
        guard let stored = defaults.dictionary(forKey: providerLifecycleKey) else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.compactMap { providerID in
                guard let generation = stored[providerID.rawValue] as? NSNumber else {
                    return nil
                }
                return (providerID, generation.uint64Value)
            }
        )
    }

    func saveProviderLifecycleGenerations(_ generations: [ProviderID: UInt64]) {
        let bounded = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.compactMap { providerID in
                generations[providerID].map { (providerID.rawValue, NSNumber(value: $0)) }
            }
        )
        defaults.set(bounded, forKey: providerLifecycleKey)
    }
}
