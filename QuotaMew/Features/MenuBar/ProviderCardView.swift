import SwiftUI

struct ProviderCardView: View {
    @Environment(\.locale) private var locale

    let state: ProviderState
    let usagePresentationMode: UsagePresentationMode

    private var presentation: ProviderStatePresentation {
        ProviderStatePresentation(state: state, locale: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderHeaderView(
                providerID: state.providerID,
                presentation: presentation,
                lastUpdatedAt: state.lastUpdatedAt
            )

            let windows = ProviderWindowsPresentation(state: state)
            ForEach(windows.regularWindows) { window in
                UsageWindowRow(window: window, mode: usagePresentationMode, providerID: state.providerID)
            }
            ForEach(windows.reserveWindows) { window in
                UsageWindowRow(
                    window: window,
                    mode: usagePresentationMode,
                    providerID: state.providerID,
                    isCompact: !windows.showsReserveProminently
                )
                .foregroundStyle(windows.showsReserveProminently ? .primary : .secondary)
            }

            if presentation.showsStatusMessage {
                ProviderStateView(presentation: presentation)
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.providerID.displayName)
    }
}

private struct ProviderHeaderView: View {
    let providerID: ProviderID
    let presentation: ProviderStatePresentation
    let lastUpdatedAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: providerID.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(providerID.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if let supportLabel = presentation.supportLabel {
                        Text(supportLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quinary, in: .capsule)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .layoutPriority(1)

                if let lastUpdatedAt {
                    Text("Last updated \(lastUpdatedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(Text("Updated \(lastUpdatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())"))
                } else {
                    Text("Not updated yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 5) {
                if presentation.kind == .loading {
                    ProgressView()
                        .controlSize(.mini)
                }

                Text(presentation.badgeLabel)
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(presentation.kind.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(presentation.kind.tint.opacity(0.1), in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}

extension ProviderStatePresentation.Kind {
    var tint: Color {
        switch self {
        case .loading, .unavailable:
            .secondary
        case .available:
            .green
        case .stale:
            .orange
        case .error:
            .red
        }
    }
}

#Preview("Provider states") {
    VStack(spacing: 10) {
        ProviderCardView(state: .loading(.codex), usagePresentationMode: .remaining)
        ProviderCardView(
            state: ProviderState(
                providerID: .claude,
                status: .notConfigured,
                snapshot: nil
            ),
            usagePresentationMode: .remaining
        )
        ProviderCardView(
            state: ProviderState(
                providerID: .codex,
                status: .failed(.refreshFailed),
                snapshot: nil
            ),
            usagePresentationMode: .remaining
        )
    }
    .padding(12)
    .frame(width: 348)
}

#Preview("Narrow provider") {
    ProviderCardView(
        state: ProviderState(
            providerID: .claude,
            status: .available,
            snapshot: ProviderUsageSnapshot(
                providerID: .claude,
                windows: [
                    UsageWindow(
                        id: "preview-window",
                        label: "5-hour window",
                        usedPercentage: 63,
                        resetAt: .now.addingTimeInterval(14 * 3_600 + 23 * 60),
                        duration: .seconds(18_000)
                    ),
                ],
                capturedAt: .now,
                source: UsageSource(kind: .mock, label: "Preview", documentationURL: nil)
            )
        ),
        usagePresentationMode: .remaining
    )
    .padding(12)
    .frame(width: 300)
}
