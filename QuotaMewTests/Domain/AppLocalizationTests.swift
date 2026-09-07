import Foundation
import XCTest
@testable import QuotaMew

final class AppLocalizationTests: XCTestCase {
    func testDynamicPercentageFormattingInSupportedLanguages() {
        for percentage in [0, 1, 61, 100] {
            XCTAssertEqual(
                AppLocalization.usedPercentage(percentage, locale: Locale(identifier: "en")),
                "\(percentage)% used"
            )
            XCTAssertEqual(
                AppLocalization.remainingPercentage(percentage, locale: Locale(identifier: "en")),
                "\(percentage)% remaining"
            )
            XCTAssertEqual(
                AppLocalization.usedPercentage(
                    percentage,
                    locale: Locale(identifier: "zh-Hant-TW")
                ),
                "已使用 \(percentage)%"
            )
            XCTAssertEqual(
                AppLocalization.remainingPercentage(
                    percentage,
                    locale: Locale(identifier: "zh-Hant-TW")
                ),
                "剩餘 \(percentage)%"
            )
        }
    }

    func testDisplayAndMenuBarLocalizationKeysExist() {
        XCTAssertEqual(AppLocalization.string("Remaining", locale: Locale(identifier: "zh-Hant-TW")), "剩餘")
        XCTAssertEqual(AppLocalization.string("Used", locale: Locale(identifier: "zh-Hant-TW")), "已使用")
        XCTAssertEqual(AppLocalization.string("Menu Bar Provider", locale: Locale(identifier: "zh-Hant-TW")), "選單列提供者")
        XCTAssertEqual(AppLocalization.string("Automatic", locale: Locale(identifier: "zh-Hant-TW")), "自動")
    }

    func testNotificationPercentageFormattingInSupportedLanguages() {
        for percentage in [0, 1, 61, 100] {
            XCTAssertEqual(
                AppLocalization.notificationRemainingBody(
                    percentage,
                    locale: Locale(identifier: "en")
                ),
                "You still have \(percentage)% of your quota remaining."
            )
            XCTAssertEqual(
                AppLocalization.notificationRemainingBody(
                    percentage,
                    locale: Locale(identifier: "zh-Hant-TW")
                ),
                "你還有 \(percentage)% 的配額尚未使用。"
            )
        }
    }

    func testThresholdLabelsInSupportedLanguages() {
        XCTAssertEqual(
            AppLocalization.thresholdLabel(minutes: 30, locale: Locale(identifier: "en")),
            "30 minutes"
        )
        XCTAssertEqual(
            AppLocalization.thresholdLabel(minutes: 60, locale: Locale(identifier: "en")),
            "1 hour"
        )
        XCTAssertEqual(
            AppLocalization.thresholdLabel(
                minutes: 24 * 60,
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "24 小時"
        )
    }

    func testCompletedResetNotificationUsesLocalizedProviderAndWindowData() {
        XCTAssertEqual(
            AppLocalization.resetCompletedTitle(
                providerName: "Codex",
                locale: Locale(identifier: "en")
            ),
            "Codex quota reset"
        )
        XCTAssertEqual(
            AppLocalization.resetCompletedBody(
                windowName: "5-hour",
                locale: Locale(identifier: "en")
            ),
            "Your 5-hour quota has refreshed."
        )
        XCTAssertEqual(
            AppLocalization.resetCompletedBody(
                windowName: "每週",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "你的「每週」額度已重置。"
        )
    }

    func testUnsupportedSimplifiedChineseFallsBackToEnglish() {
        XCTAssertEqual(
            AppLocalization.string("Settings", locale: Locale(identifier: "zh-Hans-CN")),
            "Settings"
        )
    }

    func testAllProvidersDisabledEmptyStateUsesSupportedLanguages() {
        XCTAssertEqual(
            AppLocalization.string("No providers enabled", locale: Locale(identifier: "en")),
            "No providers enabled"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "No providers enabled",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "沒有啟用任何提供者"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Enable a provider in Settings to start monitoring usage.",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "請在「設定」中啟用提供者，以開始監看使用量。"
        )
        XCTAssertEqual(
            AppLocalization.string("Open Settings", locale: Locale(identifier: "zh-Hant-TW")),
            "開啟設定"
        )
    }

    func testMenuBarRecoveryUsesSupportedLanguages() {
        XCTAssertEqual(
            AppLocalization.string(
                "Show QuotaMew in Menu Bar",
                locale: Locale(identifier: "en")
            ),
            "Show QuotaMew in Menu Bar"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Show QuotaMew in Menu Bar",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "在選單列顯示 QuotaMew"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "QuotaMew is hidden",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "QuotaMew 已隱藏"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Show in Menu Bar",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "顯示於選單列"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Menu bar status",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "選單列狀態"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Hidden by QuotaMew",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "由 QuotaMew 隱藏"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Insertion requested",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "已向 macOS 要求顯示"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Not inserted by macOS",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "macOS 目前未插入"
        )
    }

    func testDiagnosticsUIUsesSupportedLanguages() {
        XCTAssertEqual(
            AppLocalization.string("Diagnostics", locale: Locale(identifier: "en")),
            "Diagnostics"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Diagnostics",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "診斷"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "App Server connection failed",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "App Server 連線失敗"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "Diagnostics copied.",
                locale: Locale(identifier: "zh-Hant-TW")
            ),
            "已複製診斷資訊。"
        )
    }
}
