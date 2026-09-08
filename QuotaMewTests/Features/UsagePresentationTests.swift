import Foundation
import XCTest
@testable import QuotaMew

final class UsagePresentationTests: XCTestCase {
    private let english = Locale(identifier: "en")

    func testRemainingIsTheDefaultPresentationSemantic() {
        let presentation = UsagePresentation(window: makeWindow(used: 39), mode: .remaining)

        XCTAssertEqual(presentation.percentage, 61)
        XCTAssertEqual(presentation.text(locale: english), "61% remaining")
    }

    func testUsedPresentationDerivesFromTheSameNormalizedWindow() {
        let window = makeWindow(used: 39)
        let presentation = UsagePresentation(window: window, mode: .used)

        XCTAssertEqual(presentation.percentage, 39)
        XCTAssertEqual(presentation.text(locale: english), "39% used")
        XCTAssertEqual(window.usedPercentage, 39)
        XCTAssertEqual(window.remainingPercentage, 61)
    }

    func testCompactMenuBarTextIsOnlyOneRoundedIntegerPercentage() {
        let remaining = UsagePresentation(window: makeWindow(used: 39.4), mode: .remaining)
        let used = UsagePresentation(window: makeWindow(used: 39.4), mode: .used)

        XCTAssertEqual(remaining.compactText(locale: english), "61%")
        XCTAssertEqual(used.compactText(locale: english), "39%")
    }

    func testCompactMenuBarTextIsNilWithoutRenderableUsage() {
        let window = UsageWindow(
            id: "primary",
            label: "Primary window",
            usedPercentage: nil,
            resetAt: nil,
            duration: nil
        )

        XCTAssertNil(UsagePresentation(window: window, mode: .remaining).compactText(locale: english))
        XCTAssertNil(UsagePresentation(window: window, mode: .used).compactText(locale: english))
    }

    func testPresentationDoesNotChangeResetEvidenceInputs() {
        let window = makeWindow(used: 82)
        let remaining = UsagePresentation(window: window, mode: .remaining)
        let used = UsagePresentation(window: window, mode: .used)

        XCTAssertEqual(window.usedPercentage, 82)
        XCTAssertEqual(window.resetAt, Date(timeIntervalSince1970: 2_000_003_600))
        XCTAssertEqual(remaining.percentage, 18)
        XCTAssertEqual(used.percentage, 82)
    }

    private func makeWindow(used: Double) -> UsageWindow {
        UsageWindow(
            id: "primary",
            label: "Primary window",
            usedPercentage: used,
            resetAt: Date(timeIntervalSince1970: 2_000_003_600),
            duration: .seconds(18_000)
        )
    }

}
