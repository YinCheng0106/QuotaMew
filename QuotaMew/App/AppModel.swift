import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    private struct RefreshCompletion {
        let notificationStates: [ProviderState]
        let nextRefreshDeadline: Date?
    }

    private(set) var providerStates: [ProviderState]
    private(set) var isRefreshing = false
    private(set) var lastUpdatedAt: Date?

    var activeProviderStates: [ProviderState] {
        providerStates.filter {
            enabledProviderIDs.contains($0.providerID) && $0.status != .disabled
        }
    }

    var hasEnabledProviders: Bool {
        !enabledProviderIDs.isEmpty
    }

    #if DEBUG
    private(set) var notificationFeedback: String?
    private(set) var runtimeDiagnosticsFeedback: String?
    #endif

    @ObservationIgnored private let refreshCoordinator: RefreshCoordinator
    @ObservationIgnored private let notificationService: any NotificationServicing
    @ObservationIgnored private let refreshPolicy: RefreshPolicy
    @ObservationIgnored private let refreshSleeper: any RefreshSleeping
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let diagnosticEnvironment: CompatibilityDiagnosticEnvironment
    @ObservationIgnored private let lifecycleObservers: AppLifecycleObserverBag
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var coordinatorCancellationTask: Task<Void, Never>?
    @ObservationIgnored private var providerIDsAwaitingRefresh: Set<ProviderID> = []
    @ObservationIgnored private var lastRefreshAttemptAt: Date?

    private let providerIDs: [ProviderID]
    private var enabledProviderIDs: Set<ProviderID>
    private var providerLifecycleGenerations: [ProviderID: UInt64]
    private var didStart = false
    private var isSleeping = false
    private var isTerminating = false
    private var refreshGeneration: UInt64 = 0
    private var scheduleGeneration: UInt64 = 0
    private var consecutiveFailureCount = 0
    private var lastRefreshCompletedAt: Date?
    private var nextRefreshAt: Date?

    init(
        providerIDs: [ProviderID],
        enabledProviderIDs: Set<ProviderID>? = nil,
        refreshCoordinator: RefreshCoordinator,
        notificationService: any NotificationServicing,
        refreshPolicy: RefreshPolicy = .v01,
        refreshSleeper: any RefreshSleeping = ContinuousRefreshSleeper(),
        now: @escaping @Sendable () -> Date = Date.init,
        diagnosticEnvironment: CompatibilityDiagnosticEnvironment = .current(),
        applicationNotificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observesLifecycle: Bool = true
    ) {
        let initialEnabledProviderIDs = (enabledProviderIDs ?? Set(providerIDs))
            .intersection(Set(providerIDs))
        self.providerIDs = providerIDs
        self.enabledProviderIDs = initialEnabledProviderIDs
        self.providerLifecycleGenerations = Dictionary(
            uniqueKeysWithValues: providerIDs.map { ($0, 0) }
        )
        self.providerStates = providerIDs.map { providerID in
            if initialEnabledProviderIDs.contains(providerID) {
                return ProviderState.loading(providerID)
            }
            return ProviderState(providerID: providerID, status: .disabled, snapshot: nil)
        }
        self.refreshCoordinator = refreshCoordinator
        self.notificationService = notificationService
        self.refreshPolicy = refreshPolicy
        self.refreshSleeper = refreshSleeper
        self.now = now
        self.diagnosticEnvironment = diagnosticEnvironment
        self.lifecycleObservers = AppLifecycleObserverBag(
            applicationNotificationCenter: applicationNotificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        if observesLifecycle {
            installLifecycleObservers()
        }
    }

    deinit {
        refreshTask?.cancel()
        scheduledRefreshTask?.cancel()
        coordinatorCancellationTask?.cancel()
    }

    func start() {
        guard !didStart, !isTerminating else { return }
        didStart = true
        requestRefresh()
    }

    func menuDidOpen() {
        guard didStart else {
            start()
            return
        }

        let currentDate = now()
        if consecutiveFailureCount > 0, let nextRefreshAt, currentDate < nextRefreshAt {
            return
        }
        if let lastRefreshCompletedAt,
           currentDate.timeIntervalSince(lastRefreshCompletedAt) < refreshPolicy.menuStaleThreshold {
            return
        }
        let hasStaleSnapshot = activeProviderStates.contains { state in
            guard let capturedAt = state.snapshot?.capturedAt else { return false }
            return currentDate.timeIntervalSince(capturedAt) >= refreshPolicy.menuStaleThreshold
        }

        if hasStaleSnapshot {
            requestRefresh()
        }
    }

    func refreshManually() {
        guard !isTerminating else { return }
        if !didStart {
            didStart = true
        }
        requestRefresh()
    }

    func applyProviderEligibilityChange(_ providerID: ProviderID, isEnabled: Bool) {
        guard providerIDs.contains(providerID), !isTerminating else { return }
        guard enabledProviderIDs.contains(providerID) != isEnabled else { return }

        providerLifecycleGenerations[providerID, default: 0] &+= 1

        if isEnabled {
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
            providerIDsAwaitingRefresh.remove(providerID)
        }

        if let index = providerStates.firstIndex(where: { $0.providerID == providerID }) {
            let snapshot = providerID.capabilities.retainsUnavailableQuotaSample
                ? providerStates[index].snapshot : nil
            providerStates[index] = isEnabled
                ? .loading(providerID)
                : ProviderState(providerID: providerID, status: .disabled, snapshot: snapshot)
        }
        updateLastUpdatedAt()

        if !isEnabled, enabledProviderIDs.isEmpty {
            cancelScheduledRefresh(clearDeadline: true)
        }
    }

    func refreshAfterProviderEnablement(_ providerID: ProviderID) {
        guard enabledProviderIDs.contains(providerID), !isTerminating else { return }
        if refreshTask != nil {
            providerIDsAwaitingRefresh.insert(providerID)
        } else {
            refreshManually()
        }
    }

    func refresh() async {
        refreshManually()
        await refreshTask?.value
    }

    func compatibilityDiagnostics() async -> CompatibilityDiagnosticsSnapshot {
        let contexts = await refreshCoordinator.providerDiagnostics()
        return CompatibilityDiagnosticsSnapshot(
            environment: diagnosticEnvironment,
            providerStates: providerStates,
            providerContexts: contexts,
            lastRefreshAttemptAt: lastRefreshAttemptAt
        )
    }

    func applicationDidBecomeActive() {
        guard !isTerminating else { return }
        guard didStart else {
            start()
            return
        }
        resumeScheduleIfNeeded()
    }

    func systemWillSleep() {
        guard !isTerminating else { return }
        isSleeping = true
        cancelScheduledRefresh(clearDeadline: false)
        #if DEBUG
        RuntimeDiagnostics.shared.schedulerUpdated(
            .suspendedForSleep,
            nextRefreshAt: nextRefreshAt,
            consecutiveFailureCount: consecutiveFailureCount
        )
        #endif
    }

    func systemDidWake() {
        guard !isTerminating else { return }
        isSleeping = false
        guard didStart else {
            start()
            return
        }
        resumeScheduleIfNeeded()
    }

    private func requestRefresh() {
        guard refreshTask == nil,
              !enabledProviderIDs.isEmpty,
              !isSleeping,
              !isTerminating
        else { return }

        cancelScheduledRefresh(clearDeadline: true)
        isRefreshing = true
        lastRefreshAttemptAt = now()
        #if DEBUG
        RuntimeDiagnostics.shared.refreshStarted(at: lastRefreshAttemptAt ?? now())
        if RuntimeDiagnostics.shouldLogAutomaticSnapshots {
            RuntimeDiagnostics.shared.logSnapshot(reason: "refresh_started")
        }
        #endif

        let loadingStates = providerStates.map { state in
            guard enabledProviderIDs.contains(state.providerID) else {
                return ProviderState(
                    providerID: state.providerID,
                    status: .disabled,
                    snapshot: state.snapshot
                )
            }
            return ProviderState.loading(state.providerID, snapshot: state.snapshot)
        }
        if providerStates != loadingStates {
            providerStates = loadingStates
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let eligibleProviderIDs = enabledProviderIDs
        let lifecycleGenerations = providerLifecycleGenerations
        let refreshCoordinator = refreshCoordinator
        refreshTask = Task { [weak self] in
            let states = await refreshCoordinator.refresh(
                eligibleProviderIDs: eligibleProviderIDs
            )
            guard let self else { return }
            guard let completion = self.finishRefresh(
                states,
                generation: generation,
                eligibleProviderIDs: eligibleProviderIDs,
                lifecycleGenerations: lifecycleGenerations
            ) else { return }
            let evaluationDate = self.now()
            await self.notificationService.evaluate(
                completion.notificationStates,
                now: evaluationDate
            )
            self.completeRefreshCycle(
                generation: generation,
                nextRefreshDeadline: completion.nextRefreshDeadline
            )
        }
    }

    private func finishRefresh(
        _ states: [ProviderState],
        generation: UInt64,
        eligibleProviderIDs: Set<ProviderID>,
        lifecycleGenerations: [ProviderID: UInt64]
    ) -> RefreshCompletion? {
        guard generation == refreshGeneration else { return nil }

        let completedAt = now()
        lastRefreshCompletedAt = completedAt
        let cachedSnapshots = Dictionary(
            uniqueKeysWithValues: providerStates.compactMap { state in
                state.snapshot.map { (state.providerID, $0) }
            }
        )
        var notificationStates: [ProviderState] = []
        let eligibleStates = states.map { state in
            guard enabledProviderIDs.contains(state.providerID) else {
                return ProviderState(
                    providerID: state.providerID,
                    status: .disabled,
                    snapshot: cachedSnapshots[state.providerID]
                )
            }

            guard eligibleProviderIDs.contains(state.providerID),
                  lifecycleGenerations[state.providerID]
                    == providerLifecycleGenerations[state.providerID]
            else {
                return ProviderState.loading(state.providerID)
            }
            notificationStates.append(state)
            return state
        }
        let displayStates = eligibleStates.map { state in
            guard state.snapshot == nil,
                  state.providerID.capabilities.retainsUnavailableQuotaSample,
                  let cachedSnapshot = cachedSnapshots[state.providerID]
            else {
                return state
            }

            switch state.status {
            case .disabled, .failed:
                break
            default:
                return state
            }

            return ProviderState(
                providerID: state.providerID,
                status: state.status,
                snapshot: cachedSnapshot
            )
        }
        if providerStates != displayStates {
            providerStates = displayStates
        }
        updateLastUpdatedAt()

        if refreshPolicy.hasRetryableFailure(in: eligibleStates) {
            consecutiveFailureCount += 1
        } else {
            consecutiveFailureCount = 0
        }

        let delay = refreshPolicy.nextRefreshDelay(
            consecutiveFailureCount: consecutiveFailureCount
        )
        let nextRefreshDeadline: Date?
        if enabledProviderIDs.isEmpty {
            cancelScheduledRefresh(clearDeadline: true)
            nextRefreshDeadline = nil
        } else {
            nextRefreshDeadline = completedAt.addingTimeInterval(max(delay, 0))
        }
        #if DEBUG
        RuntimeDiagnostics.shared.refreshFinished(states: states, at: completedAt)
        if RuntimeDiagnostics.shouldLogAutomaticSnapshots {
            RuntimeDiagnostics.shared.logSnapshot(reason: "refresh_completed")
        }
        #endif
        return RefreshCompletion(
            notificationStates: notificationStates,
            nextRefreshDeadline: nextRefreshDeadline
        )
    }

    private func completeRefreshCycle(
        generation: UInt64,
        nextRefreshDeadline: Date?
    ) {
        guard generation == refreshGeneration else { return }
        refreshTask = nil
        isRefreshing = false
        guard !isTerminating else { return }

        let shouldRefreshAfterCompletion = !providerIDsAwaitingRefresh
            .isDisjoint(with: enabledProviderIDs)
        providerIDsAwaitingRefresh.removeAll()
        if shouldRefreshAfterCompletion {
            refreshManually()
        } else if let nextRefreshDeadline {
            scheduleRefresh(
                after: max(nextRefreshDeadline.timeIntervalSince(now()), 0)
            )
        } else {
            cancelScheduledRefresh(clearDeadline: true)
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard !enabledProviderIDs.isEmpty else {
            cancelScheduledRefresh(clearDeadline: true)
            return
        }
        let deadline = now().addingTimeInterval(max(delay, 0))
        nextRefreshAt = deadline

        #if DEBUG
        RuntimeDiagnostics.shared.schedulerUpdated(
            isSleeping ? .suspendedForSleep : .scheduled,
            nextRefreshAt: deadline,
            consecutiveFailureCount: consecutiveFailureCount
        )
        #endif

        guard !isSleeping, !isTerminating else { return }
        installScheduledRefresh(deadline: deadline)
    }

    private func installScheduledRefresh(deadline: Date) {
        cancelScheduledRefresh(clearDeadline: false)

        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let delay = max(deadline.timeIntervalSince(now()), 0)
        let refreshSleeper = refreshSleeper
        scheduledRefreshTask = Task { [weak self] in
            do {
                try await refreshSleeper.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard let self else { return }
            self.scheduledRefreshDidFire(generation: generation)
        }
    }

    private func scheduledRefreshDidFire(generation: UInt64) {
        guard generation == scheduleGeneration, !isSleeping, !isTerminating else { return }
        scheduledRefreshTask = nil
        nextRefreshAt = nil
        requestRefresh()
    }

    private func resumeScheduleIfNeeded() {
        guard refreshTask == nil, scheduledRefreshTask == nil, !isSleeping else { return }

        guard let nextRefreshAt else {
            scheduleRefresh(after: refreshPolicy.normalBackgroundInterval)
            return
        }

        if nextRefreshAt <= now() {
            requestRefresh()
        } else {
            installScheduledRefresh(deadline: nextRefreshAt)
        }
    }

    private func cancelScheduledRefresh(clearDeadline: Bool) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        scheduleGeneration &+= 1
        if clearDeadline {
            nextRefreshAt = nil
        }
    }

    private func updateLastUpdatedAt() {
        lastUpdatedAt = activeProviderStates.compactMap(\.lastUpdatedAt).max()
    }

    private func terminate() {
        guard !isTerminating else { return }
        isTerminating = true
        cancelScheduledRefresh(clearDeadline: true)
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false

        #if DEBUG
        RuntimeDiagnostics.shared.refreshCancelled()
        RuntimeDiagnostics.shared.schedulerUpdated(
            .terminating,
            nextRefreshAt: nil,
            consecutiveFailureCount: consecutiveFailureCount
        )
        #endif

        let refreshCoordinator = refreshCoordinator
        coordinatorCancellationTask = Task {
            await refreshCoordinator.cancel()
        }
    }

    private func installLifecycleObservers() {
        lifecycleObservers.observeApplication(
            name: NSApplication.didBecomeActiveNotification
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.applicationDidBecomeActive()
            }
        }
        lifecycleObservers.observeApplication(
            name: NSApplication.willTerminateNotification
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.terminate()
            }
        }
        lifecycleObservers.observeWorkspace(
            name: NSWorkspace.willSleepNotification
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.systemWillSleep()
            }
        }
        lifecycleObservers.observeWorkspace(
            name: NSWorkspace.didWakeNotification
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.systemDidWake()
            }
        }
    }

    #if DEBUG
    func sendTestNotification() async {
        do {
            try await notificationService.sendTestNotification()
            notificationFeedback = String(localized: "Test notification scheduled for about 5 seconds from now.")
        } catch {
            notificationFeedback = String(localized: "Notifications are unavailable.")
        }
    }

    func logRuntimeDiagnosticsSnapshot() async {
        await notificationService.updateRuntimeDiagnostics()
        RuntimeDiagnostics.shared.logSnapshot(reason: "manual_checkpoint")
        runtimeDiagnosticsFeedback = String(localized: "Runtime snapshot written to Console.")
    }
    #endif
}

private final class AppLifecycleObserverBag: @unchecked Sendable {
    private let applicationNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        applicationNotificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter
    ) {
        self.applicationNotificationCenter = applicationNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    deinit {
        applicationObservers.forEach(applicationNotificationCenter.removeObserver)
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver)
    }

    func observeApplication(
        name: Notification.Name,
        action: @escaping @Sendable () -> Void
    ) {
        applicationObservers.append(
            applicationNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                action()
            }
        )
    }

    func observeWorkspace(
        name: Notification.Name,
        action: @escaping @Sendable () -> Void
    ) {
        workspaceObservers.append(
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                action()
            }
        )
    }
}
