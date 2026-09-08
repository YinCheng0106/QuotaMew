import Foundation

struct MenuBarMetricPresentation: Equatable, Sendable {
    let quotaSelection: MenuBarQuotaSelection
    let usage: UsagePresentation?
    let windowPresentation: UsageWindowPresentation?

    func compactText(locale: Locale) -> String {
        let percentage = usage?.compactText(locale: locale) ?? "—"
        return "\(quotaSelection.compactIdentifier) \(percentage)"
    }

    func accessibilityDescription(locale: Locale) -> String {
        let windowName = windowPresentation?.displayName(locale: locale)
            ?? quotaSelection.displayName(locale: locale)
        let usageDescription = usage?.text(locale: locale)
            ?? AppLocalization.string("Unavailable", locale: locale)
        return AppLocalization.menuBarMetricAccessibility(
            windowName: windowName,
            usageDescription: usageDescription,
            locale: locale
        )
    }
}

/// Chooses semantic menu-bar metrics from existing AppModel state without changing it.
struct MenuBarPresentation: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case renderable
        case disabled
        case unavailable
        case empty
    }

    let persistedPinnedProviderRawValue: String?
    let persistedPinnedProvider: ProviderID?
    let selectedProvider: ProviderID?
    let currentlyRenderedProvider: ProviderID?
    let displayStyle: MenuBarDisplayStyle
    let quotaSelection: MenuBarQuotaSelection
    let metrics: [MenuBarMetricPresentation]
    let availability: Availability

    init(
        providerStates: [ProviderState],
        persistedPinnedProviderRawValue: String?,
        displayStyle: MenuBarDisplayStyle,
        quotaSelection: MenuBarQuotaSelection,
        mode: UsagePresentationMode,
        now: Date = .now
    ) {
        self.persistedPinnedProviderRawValue = persistedPinnedProviderRawValue
        persistedPinnedProvider = persistedPinnedProviderRawValue.flatMap(ProviderID.init(rawValue:))
        self.displayStyle = displayStyle
        self.quotaSelection = quotaSelection

        let selectedState: ProviderState?
        if let persistedPinnedProvider {
            // A known explicit pin never falls back to a different provider.
            selectedState = providerStates.first { $0.providerID == persistedPinnedProvider }
            selectedProvider = persistedPinnedProvider
        } else if persistedPinnedProviderRawValue == nil {
            // Automatic remains an unpersisted, deterministic view of the existing order.
            selectedState = providerStates.first {
                Self.isRenderable(
                    $0,
                    displayStyle: displayStyle,
                    quotaSelection: quotaSelection
                )
            }
            selectedProvider = selectedState?.providerID
        } else {
            // Preserve an unknown future pin safely without impersonating an automatic choice.
            selectedState = nil
            selectedProvider = nil
        }

        guard let selectedState else {
            currentlyRenderedProvider = nil
            metrics = selectedProvider == nil
                ? []
                : Self.metricSelections(
                    displayStyle: displayStyle,
                    quotaSelection: quotaSelection,
                    state: nil,
                    now: now
                ).map {
                    MenuBarMetricPresentation(
                        quotaSelection: $0,
                        usage: nil,
                        windowPresentation: nil
                    )
                }
            if persistedPinnedProviderRawValue == nil,
               !providerStates.isEmpty,
               providerStates.allSatisfy({ $0.status == .disabled }) {
                availability = .empty
            } else {
                availability = .unavailable
            }
            return
        }

        let canUseSnapshot = Self.canUseSnapshot(selectedState)
        let selections = Self.metricSelections(
            displayStyle: displayStyle,
            quotaSelection: quotaSelection,
            state: selectedState,
            now: now
        )
        metrics = selections.map { selection in
            let window = canUseSnapshot
                ? Self.renderableWindow(for: selection, in: selectedState)
                : nil
            return MenuBarMetricPresentation(
                quotaSelection: selection,
                usage: window.map { UsagePresentation(window: $0, mode: mode) },
                windowPresentation: window.map {
                    UsageWindowPresentation(providerID: selectedState.providerID, window: $0)
                }
            )
        }

        let hasRenderableMetric = metrics.contains { $0.usage?.percentage != nil }
        currentlyRenderedProvider = hasRenderableMetric ? selectedState.providerID : nil
        if hasRenderableMetric {
            availability = .renderable
        } else if selectedState.status == .disabled {
            availability = .disabled
        } else {
            availability = .unavailable
        }
    }

    func compactText(locale: Locale) -> String? {
        guard !metrics.isEmpty else { return nil }
        return metrics.map { $0.compactText(locale: locale) }.joined(separator: " · ")
    }

    func accessibilityValue(locale: Locale) -> String? {
        guard !metrics.isEmpty else { return nil }
        return metrics
            .map { $0.accessibilityDescription(locale: locale) }
            .joined(separator: AppLocalization.menuBarAccessibilitySeparator(locale: locale))
    }

    private static func metricSelections(
        displayStyle: MenuBarDisplayStyle,
        quotaSelection: MenuBarQuotaSelection,
        state: ProviderState?,
        now: Date
    ) -> [MenuBarQuotaSelection] {
        switch displayStyle {
        case .single:
            return [quotaSelection]
        case .overview:
            var selections: [MenuBarQuotaSelection] = [.fiveHour, .weekly]
            if let state,
               ProviderWindowsPresentation(state: state, now: now).showsReserveProminently,
               renderableWindow(for: .lunaReserve, in: state) != nil {
                selections.append(.lunaReserve)
            }
            return selections
        }
    }

    private static func isRenderable(
        _ state: ProviderState,
        displayStyle: MenuBarDisplayStyle,
        quotaSelection: MenuBarQuotaSelection
    ) -> Bool {
        guard canUseSnapshot(state) else { return false }
        switch displayStyle {
        case .single:
            return renderableWindow(for: quotaSelection, in: state) != nil
        case .overview:
            return renderableWindow(for: .fiveHour, in: state) != nil
                || renderableWindow(for: .weekly, in: state) != nil
        }
    }

    private static func canUseSnapshot(_ state: ProviderState) -> Bool {
        switch state.status {
        case .disabled, .notConfigured, .notInstalled, .unsupportedAuthentication:
            false
        case .loading, .available, .stale, .failed:
            true
        }
    }

    private static func renderableWindow(
        for selection: MenuBarQuotaSelection,
        in state: ProviderState
    ) -> UsageWindow? {
        state.snapshot?.windows
            .filter { window in
                window.displayUsedPercentage != nil
                    && UsageWindowPresentation(
                        providerID: state.providerID,
                        window: window
                    ).menuBarQuotaSelection == selection
            }
            .min { $0.id < $1.id }
    }
}
