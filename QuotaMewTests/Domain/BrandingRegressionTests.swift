import Foundation
import XCTest
@testable import QuotaMew

final class BrandingRegressionTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCurrentStringCatalogContainsNoOldApplicationBranding() throws {
        let data = try Data(contentsOf: repository.appending(path: "QuotaMew/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertNotNil(strings["QuotaMew"])
        XCTAssertNotNil(strings["Quit QuotaMew"])
        XCTAssertNotNil(strings["QuotaMew is hidden"])
        let content = String(decoding: data, as: UTF8.self)
        for oldName in ["QuotaPulse", "quotaPulse", "quotapulse", "Quota Pulse"] {
            XCTAssertFalse(content.contains(oldName))
        }
        for key in ["5-hour", "Weekly", "Luna Reserve", "Refresh Now", "Settings…", "Quit QuotaMew"] {
            XCTAssertNotNil(strings[key])
        }
    }

    func testCurrentReadmeLinksAndHistoricalBetaOneRecordRemainCorrect() throws {
        for path in ["README.md", "README.zh-TW.md"] {
            let content = try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            XCTAssertTrue(content.contains("https://github.com/YinCheng0106/QuotaMew/releases"))
            XCTAssertFalse(content.contains("https://github.com/YinCheng0106/QuotaPulse/releases"))
            XCTAssertTrue(content.contains("v0.2.0 Beta 3"))
        }
        let changelog = try String(contentsOf: repository.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let betaOne = try XCTUnwrap(changelog.components(separatedBy: "## [0.2.0-beta.1]").last)
            .components(separatedBy: "## [0.1.1]")[0]
        XCTAssertTrue(betaOne.contains("First publicly downloadable QuotaPulse beta distributed as a DMG."))
    }

    func testCompatibilityIdentifiersAndCurrentExecutableNameRemainStable() throws {
        let project = try String(contentsOf: repository.appending(path: "QuotaMew.xcodeproj/project.pbxproj"), encoding: .utf8)
        for identifier in ["dev.quotapulse.app", "dev.quotapulse.development.app", "dev.quotapulse.appTests"] {
            XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \(identifier);"))
        }
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.quotapulse.development.app")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "QuotaMew")
        let reader = try String(contentsOf: repository.appending(path: "QuotaMew/Providers/Claude/ClaudeSnapshotReader.swift"), encoding: .utf8)
        XCTAssertTrue(reader.contains("QuotaPulse/Providers/Claude/usage-v1.json"))
        let store = try String(contentsOf: repository.appending(path: "QuotaMew/Services/SettingsStore.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("presentation.menu-bar-extra.requested"))
    }
}
