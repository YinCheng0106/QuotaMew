import AppKit
import SwiftUI

@MainActor
final class ActivityWindowController: NSObject, NSWindowDelegate {
    typealias WindowFactory = @MainActor (ActivityWindowView) -> NSWindow
    static let defaultSize = NSSize(width: 560, height: 680)
    static let minimumSize = NSSize(width: 420, height: 460)

    let model: ActivityModel
    private let openSettings: @MainActor () -> Void
    private let activate: @MainActor () -> Void
    private let windowFactory: WindowFactory
    private(set) var window: NSWindow?
    private var openTask: Task<Void, Never>?
    private var openGeneration = UUID()
    private var isTornDown = false

    init(model: ActivityModel, openSettings: @escaping @MainActor () -> Void,
         activate: @escaping @MainActor () -> Void = { NSApplication.shared.activate() },
         windowFactory: @escaping WindowFactory = ActivityWindowController.makeWindow) {
        self.model = model
        self.openSettings = openSettings
        self.activate = activate
        self.windowFactory = windowFactory
    }

    func show() {
        guard !isTornDown else { return }
        if window == nil {
            let window = windowFactory(ActivityWindowView(model: model, openSettings: openSettings))
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
        }
        activate() // No activation-policy change or permanent Dock icon.
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        // Opening is the only automatic presentation demand. Never age-based.
        guard model.state == .idle else { return }
        // An invalidated, bounded old waiter must not block a new idle session.
        openTask?.cancel()
        let generation = UUID()
        openGeneration = generation
        openTask = Task { [weak self, model] in
            try? await model.refresh()
            if self?.openGeneration == generation { self?.openTask = nil }
        }
    }

    func waitForOpenRefresh() async { await openTask?.value }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        releasePresentation()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        openGeneration = UUID()
        openTask?.cancel()
        openTask = nil
        window?.delegate = nil
        window?.close()
        releasePresentation()
    }

    private func releasePresentation() {
        // Keep the runtime's current memory snapshot; release all rendering while closed.
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
    }

    static func makeWindow(_ view: ActivityWindowView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = AppLocalization.string("Codex Account Activity")
        window.setAccessibilityLabel(window.title)
        window.contentViewController = NSHostingController(rootView: view)
        window.contentMinSize = minimumSize
        window.center()
        return window
    }
}
