#if DEBUG
import SwiftUI

/// Synthetic-only acceptance fixtures; never access settings, processes or provider data.
@MainActor
private struct ActivityWindowPreview: View {
    @State private var model: ActivityModel
    let period: ActivityPeriod

    init(result: ActivityFetchResult, period: ActivityPeriod = .latest, enabled: Bool = true) {
        let service = ActivityService(sources: [PreviewActivitySource(result: result)],
                                      store: ActivitySnapshotStore(), consent: { _ in enabled })
        _model = State(initialValue: ActivityModel(service: service, providerID: .codex, initiallyEnabled: enabled))
        self.period = period
    }

    var body: some View {
        ActivityWindowView(model: model, openSettings: {}, initialPeriod: period)
            .task { if model.state == .idle { try? await model.refresh() } }
    }

    static func sample(complete: Bool = false) -> ActivityFetchResult {
        let anchor = try! ProviderCalendarDate("2026-10-02")
        let offsets = complete ? Array(0..<30) : [0, 1, 3, 4, 6, 14, 20]
        let buckets = offsets.map { offset in
            try! ActivityBucket(sourceDate: anchor.addingDays(-offset),
                                reportedTokens: offset.isMultiple(of: 3) ? 0 : Int64((offset + 1) * 1_250))
        }
        return .snapshot(try! ProviderActivitySnapshot(providerID: .codex, buckets: buckets,
                                                       capturedAt: Date(timeIntervalSince1970: 1_791_000_000),
                                                       source: .synthetic))
    }
}

private struct PreviewActivitySource: TokenActivitySource {
    let id = ProviderID.codex
    let result: ActivityFetchResult
    func fetchActivity() async throws -> ActivityFetchResult { result }
}

#Preview("Activity · Disabled") {
    ActivityWindowPreview(result: .disabled, enabled: false).frame(width: 560, height: 680)
}

#Preview("Activity · Latest") {
    ActivityWindowPreview(result: ActivityWindowPreview.sample()).frame(width: 560, height: 680)
}

#Preview("Activity · 7D · Zero and missing") {
    ActivityWindowPreview(result: ActivityWindowPreview.sample(), period: .sevenDays).frame(width: 560, height: 680)
}

#Preview("Activity · 30D · Complete") {
    ActivityWindowPreview(result: ActivityWindowPreview.sample(complete: true), period: .thirtyDays)
        .frame(width: 560, height: 680)
}

#Preview("Activity · 繁體中文 · Dark · Minimum width") {
    ActivityWindowPreview(result: ActivityWindowPreview.sample(), period: .thirtyDays)
        .environment(\.locale, Locale(identifier: "zh-Hant-TW"))
        .preferredColorScheme(.dark).frame(width: 420, height: 680)
}

#Preview("Activity · Unsupported") {
    ActivityWindowPreview(result: .unsupported).frame(width: 560, height: 680)
}

#Preview("Activity · Failed") {
    ActivityWindowPreview(result: .failed(.fetchFailed)).frame(width: 560, height: 680)
}
#endif
