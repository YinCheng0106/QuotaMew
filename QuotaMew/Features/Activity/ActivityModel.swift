import Foundation
import Observation

enum ActivityModelState: Equatable, Sendable {
    case disabled
    case idle
    case loading
    case available(ActivityProjection)
    case noReportedBuckets(source: ActivitySource, capturedAt: Date, reason: NoDailyBucketsReason)
    case unsupported
    case unavailable(ActivityFetchError)
    case failed(ActivityFetchError)
}

@Observable
@MainActor
final class ActivityModel {
    private(set) var state: ActivityModelState
    let providerID: ProviderID
    @ObservationIgnored private let service: ActivityService
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    // Serialize user intents across actor hops, including rapid disable/re-enable.
    @ObservationIgnored private var transitionTask: Task<Bool, Never>?
    #if DEBUG
    @ObservationIgnored private(set) var refreshCallerCount = 0
    #endif

    init(service: ActivityService, providerID: ProviderID, initiallyEnabled: Bool) {
        self.service = service
        self.providerID = providerID
        state = initiallyEnabled ? .idle : .disabled
        // Construction does not create a task or perform source I/O.
    }

    func refresh() async throws {
        try Task.checkCancellation()
        #if DEBUG
        refreshCallerCount += 1
        defer { refreshCallerCount -= 1 }
        #endif
        let current = generation
        if let transitionTask { _ = await transitionTask.value }
        try Task.checkCancellation()
        guard generation == current, state != .disabled else { return }
        if let refreshTask {
            await refreshTask.value
        } else {
            state = .loading // Clears all old numbers before acquisition.
            let task = Task { [self] in
                let result: ActivityFetchResult
                do { result = try await service.refresh(provider: providerID) }
                catch is CancellationError { result = .unavailable(.providerUnavailable) }
                catch { result = .failed(.fetchFailed) }
                guard generation == current else { return }
                state = Self.project(result)
                refreshTask = nil
            }
            refreshTask = task
            await task.value
        }
        // A canceled waiter never cancels the shared cycle or alters its publication.
        try Task.checkCancellation()
    }

    func setEnabled(_ enabled: Bool) async {
        clearCycle(state: enabled ? .idle : .disabled)
        let current = generation
        let previous = transitionTask
        let task = Task { [self] in
            if let previous { _ = await previous.value }
            await service.invalidate(provider: providerID)
            let eligible = await service.setEnabled(enabled, provider: providerID)
            if generation == current {
                state = eligible && enabled ? .idle : .disabled
                transitionTask = nil
            }
            return eligible
        }
        transitionTask = task
        _ = await task.value
    }

    /// Future display/account lifecycle callers clear values before the service hop.
    func invalidate() async {
        let wasDisabled = state == .disabled
        clearCycle(state: wasDisabled ? .disabled : .idle)
        let current = generation
        let previous = transitionTask
        let task = Task { [self] in
            if let previous { _ = await previous.value }
            await service.invalidate(provider: providerID)
            let eligible = await service.isEnabled(provider: providerID)
            if generation == current {
                state = eligible ? .idle : .disabled
                transitionTask = nil
            }
            return eligible
        }
        transitionTask = task
        _ = await task.value
    }

    private func clearCycle(state: ActivityModelState) {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        self.state = state
    }

    private static func project(_ result: ActivityFetchResult) -> ActivityModelState {
        switch result {
        case .snapshot(let snapshot):
            do {
                if let projection = try ActivityProjection.query(snapshot) { return .available(projection) }
                return .noReportedBuckets(source: snapshot.source, capturedAt: snapshot.capturedAt,
                                          reason: .emptyCollection)
            } catch { return .failed(.invalidData) }
        case .noDailyBuckets(let source, let capturedAt, let reason):
            return .noReportedBuckets(source: source, capturedAt: capturedAt, reason: reason)
        case .disabled: return .disabled
        case .unsupported: return .unsupported
        case .unavailable(let error): return .unavailable(error)
        case .failed(let error): return .failed(error)
        }
    }
}
