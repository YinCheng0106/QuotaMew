import Foundation
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityConsentTests: XCTestCase {
    func testDefaultAndExistingInstallDisabledStrictBoolAndUnknownValuesPreserved() {
        let name = "ActivityConsent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "activity.codex.account.enabled"
        XCTAssertFalse(SettingsStore(defaults: defaults).isCodexAccountActivityEnabled)
        defaults.set(true, forKey: "providers.codex.enabled")
        XCTAssertFalse(SettingsStore(defaults: defaults).isCodexAccountActivityEnabled)
        for corrupt in ["true", "YES", 1, 0, [true], ["enabled": true]] as [Any] {
            defaults.set(corrupt, forKey: key)
            XCTAssertFalse(SettingsStore(defaults: defaults).isCodexAccountActivityEnabled)
            XCTAssertNotNil(defaults.object(forKey: key), "Unknown setting is not overwritten")
        }
        defaults.removeObject(forKey: key)
        let first = SettingsStore(defaults: defaults)
        let before = defaults.persistentDomain(forName: name)! as NSDictionary
        first.setCodexAccountActivityEnabled(true)
        let after = defaults.persistentDomain(forName: name)!
        let changed = Set(after.keys.filter { !NSObject.isEqualValue(before[$0], after[$0]) })
        XCTAssertEqual(changed, [key], "Only consent is persisted")
        XCTAssertTrue(SettingsStore(defaults: defaults).isCodexAccountActivityEnabled)
        first.setCodexAccountActivityEnabled(false)
        XCTAssertFalse(SettingsStore(defaults: defaults).isCodexAccountActivityEnabled)
    }

    func testSnapshotNeverEntersSettingsPersistence() async throws {
        let name = "ActivityPrivacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setCodexAccountActivityEnabled(true)
        let before = defaults.persistentDomain(forName: name)! as NSDictionary
        let store = ActivitySnapshotStore()
        let source = ImmediateActivitySource(snapshot: try activitySnapshot())
        let service = ActivityService(sources: [source], store: store, settings: settings)
        _ = try await service.refresh(provider: .codex)
        XCTAssertEqual(before, defaults.persistentDomain(forName: name)! as NSDictionary)
        await service.shutdown()
    }
}

private struct ImmediateActivitySource: TokenActivitySource {
    let id = ProviderID.codex
    let snapshot: ProviderActivitySnapshot
    func fetchActivity() async throws -> ActivityFetchResult { .snapshot(snapshot) }
}

private extension NSObject {
    static func isEqualValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return lhs == nil && rhs == nil }
        return lhs.isEqual(rhs)
    }
}
