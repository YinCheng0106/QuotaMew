actor UsageService {
    private let providers: [any UsageProvider]
    private let isProviderEnabled: @Sendable (ProviderID) async -> Bool

    init(
        providers: [any UsageProvider],
        preferences: (any AppPreferencesProviding)? = nil
    ) {
        self.providers = providers
        if let preferences {
            self.isProviderEnabled = { providerID in
                await preferences.isProviderEnabled(providerID)
            }
        } else {
            self.isProviderEnabled = { _ in true }
        }
    }

    func refresh(eligibleProviderIDs: Set<ProviderID>? = nil) async -> [ProviderState] {
        var states: [ProviderState] = []
        states.reserveCapacity(providers.count)

        for provider in providers {
            if Task.isCancelled {
                break
            }

            let wasEligibleWhenRefreshStarted = eligibleProviderIDs?.contains(provider.id) ?? true
            let isStillEnabled = await isProviderEnabled(provider.id)
            if !wasEligibleWhenRefreshStarted || !isStillEnabled {
                states.append(
                    ProviderState(
                        providerID: provider.id,
                        status: .disabled,
                        snapshot: nil
                    )
                )
                continue
            }

            guard let state = await refresh(provider) else {
                break
            }
            states.append(state)
        }

        return states
    }

    func providerDiagnostics() async -> [ProviderDiagnosticContext] {
        var diagnostics: [ProviderDiagnosticContext] = []
        diagnostics.reserveCapacity(providers.count)

        for provider in providers {
            diagnostics.append(
                ProviderDiagnosticContext(
                    providerID: provider.id,
                    isEnabled: await isProviderEnabled(provider.id),
                    runtime: await provider.runtimeDiagnostic()
                )
            )
        }

        return diagnostics
    }

    private func refresh(_ provider: any UsageProvider) async -> ProviderState? {
        #if DEBUG
        RuntimeDiagnostics.shared.providerRefreshStarted(provider.id)
        defer {
            RuntimeDiagnostics.shared.providerRefreshFinished(provider.id)
        }
        #endif

        do {
            let snapshot = try await provider.fetchUsage()

            guard snapshot.providerID == provider.id else {
                return ProviderState(
                    providerID: provider.id,
                    status: .failed(.refreshFailed),
                    snapshot: nil
                )
            }

            return ProviderState(
                providerID: provider.id,
                status: snapshot.validity == .stale ? .stale : .available,
                snapshot: snapshot
            )
        } catch is CancellationError {
            return nil
        } catch let error as any ProviderStatusProvidingError {
            return ProviderState(
                providerID: provider.id,
                status: error.providerStatus,
                snapshot: nil
            )
        } catch {
            return ProviderState(
                providerID: provider.id,
                status: .failed(.refreshFailed),
                snapshot: nil
            )
        }
    }
}
