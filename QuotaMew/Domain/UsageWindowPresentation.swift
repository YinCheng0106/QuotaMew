import Foundation

/// Shared display identity. Never displays provider-supplied labels or changes domain identity.
struct UsageWindowPresentation: Equatable, Sendable {
    let providerID: ProviderID
    let windowID: String
    let duration: Duration?

    init(providerID: ProviderID, window: UsageWindow) {
        self.init(providerID: providerID, windowID: window.id, duration: window.duration)
    }

    init(providerID: ProviderID, windowID: String, duration: Duration?) {
        self.providerID = providerID
        self.windowID = windowID
        self.duration = duration
    }

    var isReserve: Bool {
        guard providerID == .codex else { return false }
        // Existing Codex mapper emits codex.<dictionary-key-or-limitId>.<role>.
        // base_model_inference is observed runtime metadata; gpt-reserve is a known alias.
        return [
            "codex.base_model_inference.primary", "codex.base_model_inference.secondary",
            "codex.gpt-reserve.primary", "codex.gpt-reserve.secondary",
        ].contains(windowID)
    }

    var isRegularCodex: Bool {
        providerID == .codex
            && ["codex.codex.primary", "codex.codex.secondary"].contains(windowID)
            && (duration == .seconds(18_000) || duration == .seconds(604_800))
    }

    var menuBarQuotaSelection: MenuBarQuotaSelection? {
        if isReserve { return .lunaReserve }
        return switch duration {
        case .seconds(18_000): .fiveHour
        case .seconds(604_800): .weekly
        default: nil
        }
    }

    func displayName(locale: Locale) -> String {
        if isReserve { return AppLocalization.string("Luna Reserve", locale: locale) }
        switch duration {
        case .seconds(18_000):
            return AppLocalization.string("5-hour", locale: locale)
        case .seconds(604_800):
            return AppLocalization.string("Weekly", locale: locale)
        default:
            return AppLocalization.string("window.description.generic", locale: locale)
        }
    }

    func accessibilityLabel(locale: Locale) -> String {
        "\(providerID.displayName), \(displayName(locale: locale))"
    }
}

/// Pure current-snapshot projection; reserve never replaces the regular menu-bar metric.
struct ProviderWindowsPresentation: Equatable, Sendable {
    let regularWindows: [UsageWindow]
    let reserveWindows: [UsageWindow]
    let showsReserveProminently: Bool

    init(state: ProviderState, now: Date = .now) {
        let windows = state.snapshot?.windows ?? []
        regularWindows = windows.filter {
            !UsageWindowPresentation(providerID: state.providerID, window: $0).isReserve
        }
        reserveWindows = windows.filter {
            UsageWindowPresentation(providerID: state.providerID, window: $0).isReserve
        }
        // A full regular limit is evidence to make fallback information easier to find,
        // not evidence of activation, eligibility, billing, or a guaranteed successful request.
        let age = state.snapshot.map { now.timeIntervalSince($0.capturedAt) }
        let isFresh = age.map { (0..<15 * 60).contains($0) } == true
        showsReserveProminently = state.status == .available && isFresh && regularWindows.contains { window in
            UsageWindowPresentation(providerID: state.providerID, window: window).isRegularCodex
                && window.usedPercentage == 100
                && window.resetAt.map { $0 > now } == true
        }
    }
}
