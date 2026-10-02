import Foundation

/// On-demand acquisition, isolated from quota, UI, notifications and transport ownership.
actor ActivityService {
    typealias Consent = @Sendable (ProviderID) async -> Bool

    private struct Refresh {
        let generation: UUID
        let task: Task<ActivityFetchResult, Error>
    }

    private let sources: [ProviderID: any TokenActivitySource]
    private let store: ActivitySnapshotStore
    private let consent: Consent
    private let settings: SettingsStore?
    private var refreshes: [ProviderID: Refresh] = [:]
    private var isShutdown = false
    #if DEBUG
    private var waitingCallers = 0
    func refreshCallerCount() -> Int { waitingCallers }
    #endif

    init(sources: [any TokenActivitySource], store: ActivitySnapshotStore,
         settings: SettingsStore) {
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.store = store
        self.settings = settings
        self.consent = { await settings.isActivityEnabled($0) }
    }

    // Synthetic sources can exercise future provider isolation without enabling
    // unimplemented providers in persisted production settings.
    init(sources: [any TokenActivitySource], store: ActivitySnapshotStore,
         consent: @escaping Consent) {
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.store = store
        self.settings = nil
        self.consent = consent
    }

    func setCodexAccountActivityEnabled(_ enabled: Bool) async {
        _ = await setEnabled(enabled, provider: .codex)
    }

    func isEnabled(provider: ProviderID) async -> Bool {
        guard !isShutdown else { return false }
        return await consent(provider)
    }

    /// Settings remain the consent owner; only the implemented provider has a setter.
    func setEnabled(_ enabled: Bool, provider: ProviderID) async -> Bool {
        guard !isShutdown else { return false }
        if provider == .codex { await settings?.setCodexAccountActivityEnabled(enabled) }
        if !enabled { await invalidate(provider: provider) }
        // Enablement never starts work. Only an explicit refresh does.
        return await isEnabled(provider: provider)
    }

    func refresh(provider: ProviderID) async throws -> ActivityFetchResult {
        try Task.checkCancellation()
        #if DEBUG
        waitingCallers += 1
        defer { waitingCallers -= 1 }
        #endif
        guard !isShutdown else { return .unavailable(.providerUnavailable) }
        if let refresh = refreshes[provider] {
            let result = try await refresh.task.value
            try Task.checkCancellation()
            return result
        }
        let generation = UUID()
        let task = Task { try await self.acquire(provider: provider, generation: generation) }
        refreshes[provider] = Refresh(generation: generation, task: task)
        // Caller cancellation does not cancel shared source work. The caller
        // receives CancellationError after the bounded shared operation settles.
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    func invalidate(provider: ProviderID) async {
        let refresh = refreshes.removeValue(forKey: provider)
        refresh?.task.cancel()
        await store.clear(provider: provider)
    }

    func shutdown() async {
        isShutdown = true
        let tasks = refreshes.values.map(\.task)
        refreshes.removeAll()
        tasks.forEach { $0.cancel() }
        await store.clearAll()
        for task in tasks { _ = try? await task.value }
        // The shared Codex client keeps its existing sole lifecycle owner.
    }

    private func acquire(provider: ProviderID, generation: UUID) async throws -> ActivityFetchResult {
        defer {
            if isCurrent(provider, generation) { refreshes[provider] = nil }
        }
        guard isCurrent(provider, generation) else { return await invalidatedResult(provider) }
        await store.beginRefresh(provider: provider, generation: generation)
        // Final eligibility check, after queued service/store work, before source I/O.
        let enabled = await consent(provider)
        guard isCurrent(provider, generation), !Task.isCancelled else { return await invalidatedResult(provider) }
        guard enabled else {
            _ = await store.finishRefresh(provider: provider, generation: generation, snapshot: nil)
            return .disabled
        }
        let result: ActivityFetchResult
        do {
            if let source = sources[provider] {
                result = try await source.fetchActivity()
            } else {
                result = .unsupported
            }
        } catch is CancellationError {
            _ = await store.finishRefresh(provider: provider, generation: generation, snapshot: nil)
            throw CancellationError()
        } catch let error as ActivityFetchError {
            result = error == .providerUnavailable ? .unavailable(error) : .failed(error)
        } catch {
            result = .failed(.fetchFailed)
        }
        let stillEnabled = await consent(provider)
        guard isCurrent(provider, generation), !Task.isCancelled else { return await invalidatedResult(provider) }
        guard stillEnabled else {
            _ = await store.finishRefresh(provider: provider, generation: generation, snapshot: nil)
            return .disabled
        }
        let normalized: ActivityFetchResult
        let snapshot: ProviderActivitySnapshot?
        if case .snapshot(let candidate) = result {
            if candidate.providerID == provider {
                normalized = result
                snapshot = candidate
            } else {
                normalized = .failed(.invalidData)
                snapshot = nil
            }
        } else {
            normalized = result
            snapshot = nil
        }
        guard await store.finishRefresh(provider: provider, generation: generation, snapshot: snapshot),
              isCurrent(provider, generation) else { return await invalidatedResult(provider) }
        return normalized
    }

    private func isCurrent(_ provider: ProviderID, _ generation: UUID) -> Bool {
        !isShutdown && refreshes[provider]?.generation == generation
    }

    private func invalidatedResult(_ provider: ProviderID) async -> ActivityFetchResult {
        await consent(provider) ? .unavailable(.providerUnavailable) : .disabled
    }
}
