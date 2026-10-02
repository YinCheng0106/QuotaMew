import Foundation

enum ActivityPeriod: String, CaseIterable, Identifiable {
    case latest, sevenDays, thirtyDays
    var id: Self { self }

    func title(locale: Locale) -> String {
        switch self {
        case .latest: AppLocalization.string("Latest", locale: locale)
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        }
    }
}

enum ActivityFormatting {
    static func compact(_ value: Int64, locale: Locale) -> String {
        if value < 1_000 { return full(value, locale: locale) }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    static func full(_ value: Int64, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }

    // Source dates are calendar values, never local midnight instants.
    static func sourceDate(_ value: ProviderCalendarDate) -> String { value.rawValue }

    static func coverage(_ value: ActivityCoverage, locale: Locale) -> String {
        AppLocalization.string("activity.coverage \(value.reportedDays) \(value.expectedDays)", locale: locale)
    }

    static func missing(_ count: Int, locale: Locale) -> String {
        AppLocalization.string("activity.missing \(count)", locale: locale)
    }

    static func fetched(_ date: Date, locale: Locale) -> String {
        let timestamp = date.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
        return AppLocalization.string("activity.fetched \(timestamp)", locale: locale)
    }
}

struct ActivityPointPresentation: Identifiable, Equatable {
    enum Mark: Equatable { case positive, zero, missing }
    let sourceDate: String
    let reportedTokens: Int64?
    let mark: Mark
    let valueText: String
    let accessibilityText: String
    var id: String { sourceDate }

    init(_ point: ActivityPresentationPoint, locale: Locale) {
        sourceDate = ActivityFormatting.sourceDate(point.sourceDate)
        switch point {
        case .reported(let bucket):
            reportedTokens = bucket.reportedTokens
            mark = bucket.reportedTokens == 0 ? .zero : .positive
            valueText = ActivityFormatting.full(bucket.reportedTokens, locale: locale)
            accessibilityText = AppLocalization.string("activity.date.tokens \(sourceDate) \(valueText)", locale: locale)
        case .missing:
            reportedTokens = nil
            mark = .missing
            valueText = AppLocalization.string("Not reported", locale: locale)
            accessibilityText = AppLocalization.string("activity.date.missing \(sourceDate)", locale: locale)
        }
    }
}

/// Bounded, deterministic presentation shared by the view and semantic tests.
struct ActivityPresentation {
    let metricLabel: String
    let metricText: String
    let metricAccessibilityValue: String
    let sourceDates: String
    let coverageText: String?
    let missingText: String?
    let fetchedText: String
    let sourceText: String
    let summaryAccessibilityText: String
    let points: [ActivityPointPresentation]

    init(projection: ActivityProjection, period: ActivityPeriod, locale: Locale) {
        let value: Int64
        switch period {
        case .latest:
            metricLabel = AppLocalization.string("Latest reported", locale: locale)
            value = projection.latestReported.reportedTokens
            sourceDates = ActivityFormatting.sourceDate(projection.latestReported.sourceDate)
            coverageText = nil
            missingText = nil
            points = []
        case .sevenDays, .thirtyDays:
            let window = period == .sevenDays ? projection.sevenDays : projection.thirtyDays
            metricLabel = AppLocalization.string("Reported total", locale: locale)
            value = window.reportedTotal
            sourceDates = "\(ActivityFormatting.sourceDate(window.startSourceDate)) – \(ActivityFormatting.sourceDate(window.endSourceDate))"
            coverageText = ActivityFormatting.coverage(window.coverage, locale: locale)
            missingText = window.coverage.isComplete ? nil : ActivityFormatting.missing(window.coverage.missingDays, locale: locale)
            points = window.points.map { ActivityPointPresentation($0, locale: locale) }
        }
        metricText = ActivityFormatting.compact(value, locale: locale)
        metricAccessibilityValue = ActivityFormatting.full(value, locale: locale)
        fetchedText = ActivityFormatting.fetched(projection.capturedAt, locale: locale)
        sourceText = AppLocalization.string(
            projection.source == .synthetic ? "Sample activity" : "Based on dates reported by Codex.", locale: locale
        )
        summaryAccessibilityText = [period.title(locale: locale), sourceDates, metricLabel,
                                    metricAccessibilityValue, coverageText, missingText].compactMap { $0 }.joined(separator: ", ")
    }
}

struct ActivityStatePresentation {
    let title: String
    let explanation: String
    let symbol: String
    let canRefresh: Bool
    let offersSettings: Bool
    let refreshTitle: String

    init(state: ActivityModelState, locale: Locale) {
        let titleKey: String.LocalizationValue
        let explanationKey: String.LocalizationValue
        offersSettings = state == .disabled
        switch state {
        case .failed, .unavailable: refreshTitle = AppLocalization.string("Retry", locale: locale)
        default: refreshTitle = AppLocalization.string("Refresh", locale: locale)
        }
        switch state {
        case .disabled:
            titleKey = "Account Activity is opt-in"
            explanationKey = "Enable Account Activity in Settings to fetch provider-reported Codex token activity. Values stay in memory for this app session."
            symbol = "hand.raised"
            canRefresh = false
        case .idle:
            titleKey = "Ready to fetch Account Activity"
            explanationKey = "Open or refresh this window to request activity from Codex."
            symbol = "chart.bar"
            canRefresh = true
        case .loading:
            titleKey = "Fetching Account Activity…"
            explanationKey = "Requesting provider-reported token activity from Codex."
            symbol = "arrow.clockwise"
            canRefresh = false
        case .noReportedBuckets:
            titleKey = "No reported activity dates"
            explanationKey = "Codex did not report daily activity for this account."
            symbol = "calendar.badge.exclamationmark"
            canRefresh = true
        case .unsupported:
            titleKey = "Account Activity isn't available with this Codex runtime."
            explanationKey = "Quota monitoring is unaffected."
            symbol = "chart.bar"
            canRefresh = false
        case .unavailable:
            titleKey = "Codex activity is currently unavailable."
            explanationKey = "Try refreshing when Codex is available. Quota monitoring is unaffected."
            symbol = "exclamationmark.triangle"
            canRefresh = true
        case .failed:
            titleKey = "Couldn't refresh Account Activity."
            explanationKey = "Try again. Quota monitoring is unaffected."
            symbol = "exclamationmark.triangle"
            canRefresh = true
        case .available:
            titleKey = "Codex Account Activity"
            explanationKey = "Provider-reported token activity"
            symbol = "chart.bar"
            canRefresh = true
        }
        title = AppLocalization.string(titleKey, locale: locale)
        explanation = AppLocalization.string(explanationKey, locale: locale)
    }
}
