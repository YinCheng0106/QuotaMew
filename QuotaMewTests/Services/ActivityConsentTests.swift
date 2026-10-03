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

    func testRelaunchRetainsOnlyConsentAndStartsWithEmptyIdleMemory() async throws {
        let f = try M4ActivityFixture(enabled: true)
        let before = f.defaults.persistentDomain(forName: f.name)! as NSDictionary
        try await f.model.refresh()
        let populated = await f.store.snapshot(for: .codex)
        XCTAssertNotNil(populated)
        XCTAssertEqual(before, f.defaults.persistentDomain(forName: f.name)! as NSDictionary)
        await f.service.shutdown()
        let cleared = await f.store.snapshot(for: .codex)
        XCTAssertNil(cleared)

        let restoredSettings = SettingsStore(defaults: f.defaults)
        let restoredStore = ActivitySnapshotStore()
        let restoredSource = M4ActivitySource(result: .snapshot(try activitySnapshot()))
        let restoredService = ActivityService(sources: [restoredSource], store: restoredStore,
                                              settings: restoredSettings)
        let restoredModel = ActivityModel(service: restoredService, providerID: .codex,
                                          initiallyEnabled: restoredSettings.isActivityEnabled(.codex))
        XCTAssertTrue(restoredSettings.isCodexAccountActivityEnabled)
        XCTAssertEqual(restoredModel.state, .idle)
        let restoredSnapshot = await restoredStore.snapshot(for: .codex)
        let restoredReads = await restoredSource.readCount
        XCTAssertNil(restoredSnapshot)
        XCTAssertEqual(restoredReads, 0)
        let persisted = f.defaults.persistentDomain(forName: f.name) ?? [:]
        XCTAssertEqual(persisted.keys.filter { $0.hasPrefix("activity.") }, ["activity.codex.account.enabled"])
        XCTAssertEqual(persisted["activity.codex.account.enabled"] as? Bool, true)
        await restoredService.shutdown()
        await f.cleanUp()
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
