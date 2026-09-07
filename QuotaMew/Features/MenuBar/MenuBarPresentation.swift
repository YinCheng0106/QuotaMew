import Foundation

/// Chooses one menu-bar metric from existing AppModel state without changing it.
struct MenuBarPresentation: Equatable {
    enum Availability: Equatable {
        case renderable
        case disabled
        case unavailable
        case empty
    }

    let persistedPinnedProviderRawValue: String?
    let persistedPinnedProvider: ProviderID?
    let selectedProvider: ProviderID?
    let currentlyRenderedProvider: ProviderID?
    let usage: UsagePresentation?
    let availability: Availability

    init(
        providerStates: [ProviderState],
        persistedPinnedProviderRawValue: String?,
        mode: UsagePresentationMode
    ) {
        self.persistedPinnedProviderRawValue = persistedPinnedProviderRawValue
        persistedPinnedProvider = persistedPinnedProviderRawValue.flatMap(ProviderID.init(rawValue:))

        let selectedState: ProviderState?
        if let persistedPinnedProvider {
            // A known explicit pin never falls back to a different provider.
            selectedState = providerStates.first { $0.providerID == persistedPinnedProvider }
            selectedProvider = persistedPinnedProvider
        } else if persistedPinnedProviderRawValue == nil {
            // Automatic is an unpersisted, deterministic view of the existing order.
            selectedState = providerStates.first(where: Self.isRenderable)
            selectedProvider = selectedState?.providerID
        } else {
            // Preserve an unknown future pin safely without impersonating an automatic choice.
            selectedState = nil
            selectedProvider = nil
        }

        guard let selectedState, let window = Self.renderableWindow(in: selectedState) else {
            currentlyRenderedProvider = nil
            usage = nil
            if selectedState?.status == .disabled {
                availability = .disabled
            } else if persistedPinnedProviderRawValue == nil,
                      !providerStates.isEmpty,
                      providerStates.allSatisfy({ $0.status == .disabled }) {
                availability = .empty
            } else {
                availability = .unavailable
            }
            return
        }

        currentlyRenderedProvider = selectedState.providerID
        usage = UsagePresentation(window: window, mode: mode)
        availability = .renderable
    }

    private static func isRenderable(_ state: ProviderState) -> Bool {
        renderableWindow(in: state) != nil
    }

    private static func renderableWindow(in state: ProviderState) -> UsageWindow? {
        switch state.status {
        case .disabled, .notConfigured, .notInstalled, .unsupportedAuthentication:
            return nil
        case .loading, .available, .stale, .failed:
            return ProviderWindowsPresentation(state: state).regularWindows.first {
                $0.displayUsedPercentage != nil
            }
        }
    }
}
