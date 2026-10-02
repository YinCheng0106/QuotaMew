import Foundation

/// Current normalized values only. No history, errors, identity, or persistence.
actor ActivitySnapshotStore {
    private var snapshots: [ProviderID: ProviderActivitySnapshot] = [:]
    private var generations: [ProviderID: UUID] = [:]

    func snapshot(for provider: ProviderID) -> ProviderActivitySnapshot? { snapshots[provider] }

    func replace(snapshot: ProviderActivitySnapshot) {
        generations[snapshot.providerID] = nil
        snapshots[snapshot.providerID] = snapshot
    }

    func clear(provider: ProviderID) {
        generations[provider] = nil
        snapshots[provider] = nil
    }

    func clearAll() {
        generations.removeAll()
        snapshots.removeAll()
    }

    // Publication fencing lives on the same actor as the values, so service
    // reentrancy across a store hop cannot resurrect an invalidated candidate.
    func beginRefresh(provider: ProviderID, generation: UUID) {
        snapshots[provider] = nil
        generations[provider] = generation
    }

    func finishRefresh(provider: ProviderID, generation: UUID,
                       snapshot: ProviderActivitySnapshot?) -> Bool {
        guard generations[provider] == generation else { return false }
        snapshots[provider] = snapshot
        generations[provider] = nil
        return true
    }
}
