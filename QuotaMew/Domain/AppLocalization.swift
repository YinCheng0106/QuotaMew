import Foundation

enum AppLocalization {
    private static let englishBundle = localizedBundle(named: "en")
    private static let traditionalChineseBundle = localizedBundle(named: "zh-Hant")

    static func string(
        _ value: String.LocalizationValue,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        String(
            localized: value,
            table: nil,
            bundle: bundle(for: locale),
            locale: locale
        )
    }

    static func usedPercentage(_ percentage: Int, locale: Locale) -> String {
        string(
            "usage.percentage.used \(percentageText(percentage, locale: locale))",
            locale: locale
        )
    }

    static func remainingPercentage(_ percentage: Int, locale: Locale) -> String {
        string(
            "usage.percentage.remaining \(percentageText(percentage, locale: locale))",
            locale: locale
        )
    }

    static func menuBarDisabledLabel(providerName: String, locale: Locale) -> String {
        string("menu-bar.accessibility.disabled \(providerName)", locale: locale)
    }

    static func menuBarUnavailableLabel(providerName: String, locale: Locale) -> String {
        string("menu-bar.accessibility.unavailable \(providerName)", locale: locale)
    }

    static func menuBarMetricAccessibility(
        windowName: String,
        usageDescription: String,
        locale: Locale
    ) -> String {
        string(
            "menu-bar.accessibility.metric \(windowName) \(usageDescription)",
            locale: locale
        )
    }

    static func menuBarAccessibilitySeparator(locale: Locale) -> String {
        string("menu-bar.accessibility.separator", locale: locale)
    }

    static func resetCountdown(_ countdown: String, locale: Locale) -> String {
        string("reset.countdown \(countdown)", locale: locale)
    }

    static func notificationTitle(
        providerName: String,
        windowName: String,
        thresholdMinutes: Int,
        locale: Locale
    ) -> String {
        string(
            "notification.reset.title \(providerName) \(windowName) \(thresholdLabel(minutes: thresholdMinutes, locale: locale))",
            locale: locale
        )
    }

    static func notificationRemainingBody(_ percentage: Int, locale: Locale) -> String {
        string(
            "notification.reset.remaining \(percentageText(percentage, locale: locale))",
            locale: locale
        )
    }

    static func resetCompletedTitle(providerName: String, locale: Locale) -> String {
        string("notification.reset.completed.title \(providerName)", locale: locale)
    }

    static func resetCompletedBody(
        windowName: String,
        locale: Locale
    ) -> String {
        string("notification.reset.completed.body \(windowName)", locale: locale)
    }

    static func thresholdLabel(minutes: Int, locale: Locale) -> String {
        switch minutes {
        case 30:
            return string("duration.30-minutes", locale: locale)
        case 60:
            return string("duration.1-hour", locale: locale)
        case 6 * 60:
            return string("duration.6-hours", locale: locale)
        case 24 * 60:
            return string("duration.24-hours", locale: locale)
        default:
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 1
            formatter.zeroFormattingBehavior = .dropAll
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            formatter.calendar = calendar
            return formatter.string(from: TimeInterval(minutes * 60))
                ?? string("duration.unavailable", locale: locale)
        }
    }

    static func countdownDuration(totalMinutes: Int, locale: Locale) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(totalMinutes * 60))
    }

    private static func percentageText(_ percentage: Int, locale: Locale) -> String {
        (Double(percentage) / 100).formatted(
            .percent
                .precision(.fractionLength(0))
                .locale(locale)
        )
    }

    private static func bundle(for locale: Locale) -> Bundle {
        locale.language.languageCode == .chinese && locale.language.script?.identifier == "Hant"
            ? traditionalChineseBundle
            : englishBundle
    }

    private static func localizedBundle(named localization: String) -> Bundle {
        guard
            let url = Bundle.main.url(forResource: localization, withExtension: "lproj"),
            let bundle = Bundle(url: url)
        else {
            return .main
        }
        return bundle
    }
}
