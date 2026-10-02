import XCTest
@testable import QuotaMew

final class ActivitySnapshotStoreTests: XCTestCase {
    func testStartsEmptyReplacementDiscardsAllPreviousDatesAndClear() async throws {
        let store = ActivitySnapshotStore()
        var snapshot = await store.snapshot(for: .codex)
        XCTAssertNil(snapshot)
        let first = try activitySnapshot()
        let second = try activitySnapshot(date: "2026-10-02")
        await store.replace(snapshot: first)
        snapshot = await store.snapshot(for: .codex)
        XCTAssertEqual(snapshot, first)
        await store.replace(snapshot: second)
        snapshot = await store.snapshot(for: .codex)
        XCTAssertEqual(snapshot, second)
        await store.clear(provider: .codex)
        snapshot = await store.snapshot(for: .codex)
        XCTAssertNil(snapshot)
    }

    func testProviderIndependenceClearAllAndNoLaunchRestore() async throws {
        let store = ActivitySnapshotStore()
        let other = try activitySnapshot(provider: .claude)
        await store.replace(snapshot: try activitySnapshot())
        await store.replace(snapshot: other)
        await store.clear(provider: .codex)
        let retained = await store.snapshot(for: .claude)
        XCTAssertEqual(retained, other)
        await store.clearAll()
        let cleared = await store.snapshot(for: .claude)
        XCTAssertNil(cleared)
        let recreated = ActivitySnapshotStore()
        let fresh = await recreated.snapshot(for: .claude)
        XCTAssertNil(fresh)
    }

    func testStorePublicationFenceRejectsInvalidatedAndOlderGenerations() async throws {
        let store = ActivitySnapshotStore()
        let old = UUID()
        let current = UUID()
        await store.beginRefresh(provider: .codex, generation: old)
        await store.clear(provider: .codex)
        let rejected = await store.finishRefresh(provider: .codex, generation: old, snapshot: try activitySnapshot())
        XCTAssertFalse(rejected)
        await store.beginRefresh(provider: .codex, generation: current)
        let stale = await store.finishRefresh(provider: .codex, generation: old, snapshot: try activitySnapshot())
        XCTAssertFalse(stale)
        let accepted = await store.finishRefresh(provider: .codex, generation: current, snapshot: try activitySnapshot())
        XCTAssertTrue(accepted)
    }
}
