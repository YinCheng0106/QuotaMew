import Charts
import SwiftUI

struct ActivityWindowView: View {
    let model: ActivityModel
    let openSettings: @MainActor () -> Void
    @Environment(\.locale) private var locale
    @State private var period: ActivityPeriod = .latest

    init(model: ActivityModel, openSettings: @escaping @MainActor () -> Void,
         initialPeriod: ActivityPeriod = .latest) {
        self.model = model
        self.openSettings = openSettings
        _period = State(initialValue: initialPeriod)
    }

    var body: some View {
        let status = ActivityStatePresentation(state: model.state, locale: locale)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Provider-reported token activity")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Activity period", selection: $period) {
                    ForEach(ActivityPeriod.allCases) { value in
                        Text(verbatim: value.title(locale: locale)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Activity period")
                .accessibilityValue(period.title(locale: locale))

                switch model.state {
                case .available(let projection):
                    ActivityReportView(presentation: ActivityPresentation(projection: projection, period: period, locale: locale))
                default:
                    ActivityEmptyView(status: status, isLoading: model.state == .loading,
                                      openSettings: openSettings, refresh: refresh)
                    if case .noReportedBuckets(_, let capturedAt, _) = model.state {
                        Text(verbatim: ActivityFormatting.fetched(capturedAt, locale: locale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                Text("QuotaMew does not store this activity history on disk and does not read prompts, threads, source code, or credentials for this feature.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("About these values") {
                    Text("Activity values are reported by Codex and may not represent exact billing or subscription quota usage. Dates use the source-provided calendar buckets; the latest date is not necessarily your local today. History may be incomplete.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: ActivityWindowController.minimumSize.width,
               minHeight: ActivityWindowController.minimumSize.height)
        .navigationTitle("Codex Account Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!status.canRefresh)
                    .accessibilityLabel("Refresh Account Activity")
                    .help("Refresh Account Activity")
            }
        }
    }

    private func refresh() { Task { try? await model.refresh() } }
}

private struct ActivityEmptyView: View {
    let status: ActivityStatePresentation
    let isLoading: Bool
    let openSettings: @MainActor () -> Void
    let refresh: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isLoading { ProgressView().controlSize(.small) }
            else { Image(systemName: status.symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(verbatim: status.title).font(.title3.weight(.semibold))
            Text(verbatim: status.explanation).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.offersSettings {
                Button("Open Settings", action: openSettings)
            } else if status.canRefresh {
                Button(status.refreshTitle, action: refresh)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.title)
    }
}

private struct ActivityReportView: View {
    let presentation: ActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: presentation.metricLabel).font(.headline)
                Text(verbatim: presentation.sourceDates).foregroundStyle(.secondary).monospacedDigit()
                Text(verbatim: presentation.metricText).font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Provider-reported token activity")
                    .accessibilityValue(presentation.metricAccessibilityValue)
            }

            if let coverage = presentation.coverageText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coverage").font(.headline)
                    Text(verbatim: coverage)
                    if let missing = presentation.missingText {
                        Text(verbatim: missing).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                ActivityTrendView(points: presentation.points)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(presentation.summaryAccessibilityText)
                DisclosureGroup("Reported dates") {
                    VStack(spacing: 8) {
                        ForEach(presentation.points) { point in
                            HStack {
                                Text(verbatim: point.sourceDate)
                                Spacer()
                                Text(verbatim: point.valueText)
                            }
                            .monospacedDigit()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(point.accessibilityText)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            Text(verbatim: presentation.sourceText).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: presentation.fetchedText).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActivityTrendView: View {
    let points: [ActivityPointPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(points) { point in
                switch point.mark {
                case .positive:
                    BarMark(x: .value("Source date", point.sourceDate),
                            y: .value("Reported tokens", point.reportedTokens!))
                        .foregroundStyle(Color.accentColor)
                case .zero:
                    PointMark(x: .value("Source date", point.sourceDate), y: .value("Reported zero", 0))
                        .symbol(.circle).symbolSize(40).foregroundStyle(Color.primary)
                case .missing:
                    // The marker locates a missing date, not a numerical zero bucket.
                    PointMark(x: .value("Source date", point.sourceDate), y: .value("Not reported", 0))
                        .symbol(.cross).symbolSize(40).foregroundStyle(Color.secondary)
                }
            }
            .chartXScale(domain: points.map(\.sourceDate))
            .chartXAxis {
                AxisMarks(values: [points.first?.sourceDate, points.last?.sourceDate].compactMap { $0 }) {
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .frame(height: 160)
            .accessibilityHidden(true) // Exact, localized semantics live in the summary and date list.
            Text("Bars: reported activity · ●: reported zero · +: not reported")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
