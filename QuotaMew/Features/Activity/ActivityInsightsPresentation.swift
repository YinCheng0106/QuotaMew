import Foundation

/// Localized, exact text shared by the native UI and accessibility tests.
struct ActivityInsightsPresentation {
    let averageText: String
    let highestText: String
    let highestTieText: String?
    let previousDatesText: String?
    let comparisonText: String

    init(query: ActivityInsightsQuery, locale: Locale) {
        guard case .available(let insights) = query else {
            let explanation = AppLocalization.string(
                query == .noReportedData ? "No reported activity dates" : "Source dates are outside the supported range.",
                locale: locale)
            averageText = explanation
            highestText = explanation
            comparisonText = explanation
            highestTieText = nil
            previousDatesText = nil
            return
        }
        switch insights.current.dailyReportedAverage {
        case .available(let average):
            let value = ActivityFormatting.full(average.roundedTokens, locale: locale)
            averageText = AppLocalization.string("activity.insights.average \(value) \(average.reportedDays)", locale: locale)
        case .noReportedData:
            averageText = AppLocalization.string("No reported activity dates", locale: locale)
        case .overflow:
            averageText = AppLocalization.string("Reported values are too large to summarize.", locale: locale)
        }
        switch insights.current.highestReportedDay {
        case .available(let highest):
            let date = ActivityFormatting.sourceDate(highest.bucket.sourceDate)
            let value = ActivityFormatting.full(highest.bucket.reportedTokens, locale: locale)
            highestText = AppLocalization.string("activity.insights.highest \(date) \(value)", locale: locale)
            highestTieText = highest.tiedReportedDays > 1
                ? AppLocalization.string("activity.insights.tied \(highest.tiedReportedDays)", locale: locale) : nil
        case .noReportedData:
            highestText = AppLocalization.string("No reported activity dates", locale: locale)
            highestTieText = nil
        case .overflow:
            highestText = AppLocalization.string("Reported values are too large to summarize.", locale: locale)
            highestTieText = nil
        }
        if let previous = insights.previous {
            let start = previous.startSourceDate.rawValue
            let end = previous.endSourceDate.rawValue
            previousDatesText = AppLocalization.string("activity.insights.previous-dates \(start) \(end)", locale: locale)
        } else {
            previousDatesText = nil
        }
        comparisonText = Self.comparison(insights.comparison, locale: locale)
    }

    private static func comparison(_ value: ActivityPeriodComparison, locale: Locale) -> String {
        switch value {
        case .noReportedData:
            return AppLocalization.string("No reported activity dates", locale: locale)
        case .sourceDateOutOfRange:
            return AppLocalization.string("Source dates are outside the supported range.", locale: locale)
        case .overflow:
            return AppLocalization.string("Reported values are too large to compare.", locale: locale)
        case .insufficientCoverage(let current, let previous):
            return AppLocalization.string(
                "activity.insights.insufficient \(current.reportedDays) \(current.expectedDays) \(previous.reportedDays) \(previous.expectedDays)",
                locale: locale)
        case .available(let change):
            switch change.percentage {
            case .roundedWholePercent(let percent):
                let amount = ActivityFormatting.full(percent, locale: locale)
                switch change.direction {
                case .increased:
                    return AppLocalization.string("activity.insights.increased-percent \(amount)", locale: locale)
                case .decreased:
                    return AppLocalization.string("activity.insights.decreased-percent \(amount)", locale: locale)
                case .unchanged:
                    return AppLocalization.string("Reported total is unchanged from the previous period.", locale: locale)
                }
            case .lessThanOnePercent:
                return AppLocalization.string(change.direction == .increased
                    ? "Reported total increased by less than 1% compared with the previous period."
                    : "Reported total decreased by less than 1% compared with the previous period.", locale: locale)
            case .zeroBaseline:
                let amount = ActivityFormatting.full(change.delta, locale: locale)
                return AppLocalization.string("activity.insights.zero-baseline \(amount)", locale: locale)
            case .overflow:
                let amount = ActivityFormatting.full(Int64(change.delta.magnitude), locale: locale)
                return AppLocalization.string("activity.insights.percentage-unavailable \(amount)", locale: locale)
            }
        }
    }
}
