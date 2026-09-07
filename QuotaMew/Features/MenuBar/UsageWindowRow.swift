import SwiftUI

struct UsageWindowRow: View {
    @Environment(\.locale) private var locale

    let window: UsageWindow
    let mode: UsagePresentationMode
    let providerID: ProviderID
    var isCompact = false

    var windowPresentation: UsageWindowPresentation {
        UsageWindowPresentation(providerID: providerID, window: window)
    }

    private var usage: UsagePresentation {
        UsagePresentation(window: window, mode: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack {
                Text(windowPresentation.displayName(locale: locale))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let text = usage.text(locale: locale) {
                    Text(text)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .accessibilityLabel(text)
                } else {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(windowPresentation.accessibilityLabel(locale: locale))
            .accessibilityValue(
                usage.text(locale: locale) ?? AppLocalization.string("Usage unavailable", locale: locale)
            )

            if !isCompact, let progress = window.progress {
                ProgressView(value: progress)
                    .tint(window.progressTint)
                    .accessibilityHidden(true)
            }

            if !isCompact {
                HStack {
                    Spacer()
                    if let resetAt = window.resetAt {
                        ResetCountdownView(resetAt: resetAt)
                    } else {
                        Text("Reset time unavailable")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ResetCountdownView: View {
    @Environment(\.locale) private var locale

    let resetAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let countdown = ResetCountdown.text(
                until: resetAt,
                now: context.date,
                locale: locale
            )
            Text(
                resetAt > context.date
                    ? AppLocalization.resetCountdown(countdown, locale: locale)
                    : countdown
            )
                .monospacedDigit()
                .help(Text("Resets \(resetAt, format: .dateTime.month(.abbreviated).day().hour().minute())"))
        }
    }
}

private extension UsageWindow {
    var progressTint: Color {
        switch displayUsedPercentage ?? 0 {
        case 85...:
            .red
        case 65...:
            .orange
        default:
            .accentColor
        }
    }
}
