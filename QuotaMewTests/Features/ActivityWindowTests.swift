import AppKit
import SwiftUI
import XCTest
@testable import QuotaMew

@MainActor
final class ActivityWindowTests: XCTestCase {
    func testDisabledOpenReusesWindowAndNeverReadsOrChangesActivationPolicy() async throws {
        let f = try M4ActivityFixture()
        let policy = NSApplication.shared.activationPolicy()
        var creations = 0, activations = 0
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: { activations += 1 }) { view in
            XCTAssertTrue(view.model === f.model)
            creations += 1
            return M4TestWindow()
        }
        for _ in 0..<20 { controller.show() }
        await controller.waitForOpenRefresh()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(activations, 20)
        XCTAssertEqual((controller.window as? M4TestWindow)?.frontCount, 20)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), policy)
        XCTAssertEqual(f.model.state, .disabled)
        let reads = await f.source.readCount
        XCTAssertEqual(reads, 0)
        controller.teardown()
        controller.teardown()
        controller.show()
        XCTAssertNil(controller.window)
        XCTAssertEqual(creations, 1)
        await f.cleanUp()
    }

    func testEnabledFirstOpenCoalescesAvailableReopenDoesNotRefetchAndManualDoes() async throws {
        let f = try M4ActivityFixture(enabled: true)
        var creations = 0
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {}) { _ in
            creations += 1
            return M4TestWindow()
        }
        defer { controller.teardown() }
        for _ in 0..<20 { controller.show() }
        await controller.waitForOpenRefresh()
        var reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        guard case .available = f.model.state else { return XCTFail("Expected fixture projection") }
        let first = try XCTUnwrap(controller.window)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))
        XCTAssertNil(controller.window)
        XCTAssertNil(first.contentViewController)
        controller.show()
        await controller.waitForOpenRefresh()
        XCTAssertEqual(creations, 2)
        XCTAssertFalse(controller.window === first)
        reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        try await controller.model.refresh()
        reads = await f.source.readCount
        XCTAssertEqual(reads, 2)
        await f.cleanUp()
    }

    func testFailedUnsupportedUnavailableAndEmptyReopenDoNotRetry() async throws {
        for outcome in [ActivityFetchResult.failed(.fetchFailed), .unsupported, .unavailable(.providerUnavailable),
                        .noDailyBuckets(source: .synthetic, capturedAt: .distantPast, reason: .emptyCollection)] {
            let f = try M4ActivityFixture(enabled: true)
            await f.source.setResult(outcome)
            let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {}) { _ in M4TestWindow() }
            controller.show()
            await controller.waitForOpenRefresh()
            let first = try XCTUnwrap(controller.window)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))
            for _ in 0..<10 { controller.show() }
            await controller.waitForOpenRefresh()
            let reads = await f.source.readCount
            XCTAssertEqual(reads, 1)
            controller.teardown()
            await f.cleanUp()
        }
    }

    func testSettingsConsentUsesOnlySharedStoreAndModelWithoutIOAndRestartRestoresOnlyConsent() async throws {
        let f = try M4ActivityFixture()
        let settingsView = ActivityConsentView(model: f.model, store: f.settings)
        XCTAssertTrue(settingsView.model === f.model)
        XCTAssertTrue(settingsView.store === f.settings)
        XCTAssertFalse(f.settings.isCodexAccountActivityEnabled)
        await settingsView.model.setEnabled(true)
        XCTAssertTrue(f.settings.isCodexAccountActivityEnabled)
        XCTAssertEqual(f.model.state, .idle)
        var reads = await f.source.readCount
        XCTAssertEqual(reads, 0)
        try await f.model.refresh()
        let persisted = f.defaults.persistentDomain(forName: f.name)!
        XCTAssertEqual(persisted["activity.codex.account.enabled"] as? Bool, true)
        XCTAssertFalse(persisted.keys.contains { $0.contains("tokens") || $0.contains("snapshot") || $0.contains("period") })
        let freshStore = ActivitySnapshotStore()
        let restoredSettings = SettingsStore(defaults: f.defaults)
        let freshService = ActivityService(sources: [f.source], store: freshStore, settings: restoredSettings)
        let freshModel = ActivityModel(service: freshService, providerID: .codex,
                                       initiallyEnabled: restoredSettings.isActivityEnabled(.codex))
        XCTAssertEqual(freshModel.state, .idle)
        let restoredSnapshot = await freshStore.snapshot(for: .codex)
        XCTAssertNil(restoredSnapshot)
        reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        await settingsView.model.setEnabled(false)
        XCTAssertFalse(f.settings.isCodexAccountActivityEnabled)
        XCTAssertEqual(f.model.state, .disabled)
        let cleared = await f.store.snapshot(for: .codex)
        XCTAssertNil(cleared)
        try await f.model.refresh()
        reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        await freshService.shutdown()
        await f.cleanUp()
    }

    func testDisableWhileWindowOpenClearsLoadingAndFencesLateCompletion() async throws {
        let f = try M4ActivityFixture(enabled: true)
        await f.source.block()
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {}) { _ in M4TestWindow() }
        controller.show()
        await f.source.waitForRead()
        XCTAssertEqual(f.model.state, .loading)
        await f.model.setEnabled(false)
        XCTAssertEqual(f.model.state, .disabled)
        XCTAssertFalse(f.settings.isCodexAccountActivityEnabled)
        await f.source.complete()
        await controller.waitForOpenRefresh()
        XCTAssertEqual(f.model.state, .disabled)
        let stored = await f.store.snapshot(for: .codex)
        XCTAssertNil(stored)
        controller.show()
        try await f.model.refresh()
        let reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        controller.teardown()
        await f.cleanUp()
    }

    func testSettingsProviderDisableImmediatelyClearsSharedModelAndPreservesConsent() async throws {
        let f = try M4ActivityFixture(enabled: true)
        try await f.model.refresh()
        let appModel = AppDependencies.makePreviewModel()
        let settingsModel = SettingsModel(store: f.settings, appModel: appModel,
                                          notificationService: M4NotificationService(), activityModel: f.model)
        settingsModel.setProvider(.codex, enabled: false)
        XCTAssertEqual(f.model.state, .disabled)
        XCTAssertTrue(f.settings.isCodexAccountActivityEnabled)
        // Await the explicit transition rather than relying on UI scheduling.
        await f.model.invalidate()
        XCTAssertEqual(f.model.state, .disabled)
        let snapshot = await f.store.snapshot(for: .codex)
        XCTAssertNil(snapshot)
        settingsModel.setProvider(.codex, enabled: true)
        await f.model.invalidate()
        XCTAssertEqual(f.model.state, .idle)
        let reads = await f.source.readCount
        XCTAssertEqual(reads, 1)
        await f.cleanUp()
    }

    func testReenabledIdleOpenDoesNotWaitForInvalidatedOldWindowDemand() async throws {
        let f = try M4ActivityFixture(enabled: true)
        await f.source.block()
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {}) { _ in M4TestWindow() }
        controller.show()
        await f.source.waitForRead()
        await f.model.setEnabled(false)
        await f.model.setEnabled(true)
        XCTAssertEqual(f.model.state, .idle)
        let newRead = expectation(description: "Reenabled explicit open starts new demand")
        await f.source.setReadSignal { newRead.fulfill() }
        controller.show()
        await fulfillment(of: [newRead], timeout: 2)
        await f.source.complete()
        await controller.waitForOpenRefresh()
        guard case .available = f.model.state else { return XCTFail("New generation must publish") }
        let reads = await f.source.readCount
        XCTAssertEqual(reads, 2)
        controller.teardown()
        await f.cleanUp()
    }

    func testNativeWindowHasResizableOwnershipAndSettingsUsesInjectedRoute() async throws {
        let f = try M4ActivityFixture()
        var settingsCalls = 0
        let view = ActivityWindowView(model: f.model, openSettings: { settingsCalls += 1 })
        view.openSettings()
        XCTAssertEqual(settingsCalls, 1)
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {})
        controller.show()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.contentMinSize, ActivityWindowController.minimumSize)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertNotNil(window.contentViewController as? NSHostingController<ActivityWindowView>)
        XCTAssertFalse(window.title.isEmpty)
        window.close()
        XCTAssertNil(controller.window)
        controller.show()
        XCTAssertNotNil(controller.window)
        controller.teardown()
        await f.cleanUp()
    }

    func testSharedRuntimeLaunchDashboardSettingsAndEnableDoNotRequestActivity() async throws {
        let name = "M4Runtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = CodexAppServerClient(locator: CodexExecutableLocator())
        let runtime = AppDependencies.makeRuntime(settingsStore: SettingsStore(defaults: defaults), codexClient: client)
        _ = DashboardView(model: runtime.appModel, usagePresentationMode: .remaining)
        _ = SettingsView(model: runtime.settingsModel, appModel: runtime.appModel,
                         activityModel: runtime.activityModel, showOnboarding: {})
        await runtime.settingsModel.refreshSystemState()
        await runtime.settingsModel.refreshDiagnostics()
        await runtime.activityModel.setEnabled(true)
        let queue = await client.requestQueueCounts()
        XCTAssertEqual(queue.activity, 0)
        let diagnostic = await client.runtimeDiagnostic()
        XCTAssertEqual(diagnostic.appServerState, .notStarted)
        await runtime.activityService.shutdown()
        await client.shutdown()
    }

    func testNativeLayoutHostsPeriodsAtSupportedWidthsAndAppearances() async throws {
        let f = try M4ActivityFixture(enabled: true)
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {})
        defer { controller.teardown() }
        controller.show()
        await controller.waitForOpenRefresh()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.contentMinSize, ActivityWindowController.minimumSize)
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hant-TW")] {
            for appearance in [ColorScheme.light, .dark] {
                for period in ActivityPeriod.allCases {
                    window.contentViewController = NSHostingController(rootView:
                        ActivityWindowView(model: f.model, openSettings: {}, initialPeriod: period)
                            .environment(\.locale, locale).environment(\.colorScheme, appearance)
                    )
                    window.contentMinSize = ActivityWindowController.minimumSize
                    for width in [420.0, 560.0, 760.0] {
                        window.setContentSize(NSSize(width: width, height: 680))
                        window.contentView?.layoutSubtreeIfNeeded()
                        XCTAssertEqual(window.contentLayoutRect.width, width, accuracy: 1)
                        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 420)
                    }
                }
            }
        }
        // This is host/layout constraint coverage, not human visual or VoiceOver acceptance.
        await f.cleanUp()
    }

    func testNativeRefreshControlAndCommandRUseSharedModel() async throws {
        let f = try M4ActivityFixture(enabled: true)
        let controller = ActivityWindowController(model: f.model, openSettings: {}, activate: {})
        defer { controller.teardown() }
        controller.show()
        await controller.waitForOpenRefresh()
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(window.toolbar, "Native Activity toolbar must expose Refresh")
        let refreshed = expectation(description: "Command-R reaches activity source")
        await f.source.setReadSignal { refreshed.fulfill() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        await fulfillment(of: [refreshed], timeout: 2)
        let reads = await f.source.readCount
        XCTAssertEqual(reads, 2)
        await f.cleanUp()
    }
}

@MainActor
struct M4ActivityFixture {
    let name = "M4Activity-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: SettingsStore
    let source: M4ActivitySource
    let store = ActivitySnapshotStore()
    let service: ActivityService
    let model: ActivityModel

    init(enabled: Bool = false) throws {
        defaults = UserDefaults(suiteName: name)!
        settings = SettingsStore(defaults: defaults)
        settings.setCodexAccountActivityEnabled(enabled)
        source = M4ActivitySource(result: .snapshot(try activitySnapshot()))
        service = ActivityService(sources: [source], store: store, settings: settings)
        model = ActivityModel(service: service, providerID: .codex, initiallyEnabled: enabled)
    }

    func cleanUp() async {
        await service.shutdown()
        defaults.removePersistentDomain(forName: name)
    }
}

actor M4ActivitySource: TokenActivitySource {
    nonisolated let id = ProviderID.codex
    private(set) var readCount = 0
    private var result: ActivityFetchResult
    private var isBlocked = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var readSignal: (@Sendable () -> Void)?
    init(result: ActivityFetchResult) { self.result = result }
    func setResult(_ result: ActivityFetchResult) { self.result = result }
    func block() { isBlocked = true }
    func setReadSignal(_ signal: @escaping @Sendable () -> Void) { readSignal = signal }
    func waitForRead() async {
        if !continuations.isEmpty { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func fetchActivity() async throws -> ActivityFetchResult {
        readCount += 1
        readSignal?()
        if isBlocked {
            await withCheckedContinuation {
                continuations.append($0)
                readWaiters.forEach { $0.resume() }
                readWaiters.removeAll()
            }
        }
        return result
    }
    func complete() {
        isBlocked = false
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

@MainActor
private final class M4TestWindow: NSWindow {
    var frontCount = 0
    init() { super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false) }
    override func makeKeyAndOrderFront(_ sender: Any?) { frontCount += 1 }
}

@MainActor
private final class M4NotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}
    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}
