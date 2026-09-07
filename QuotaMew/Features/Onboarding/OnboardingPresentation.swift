import AppKit
import SwiftUI

enum OnboardingPresentationMode: Equatable, Sendable {
    case firstRun
    case manualReplay
}

enum OnboardingPresentationAction: Equatable, Sendable {
    case skip
    case complete
    case close
}

struct OnboardingStartupPolicy {
    static func shouldPresent(
        launchSource: ApplicationLaunchSource,
        menuBarDisposition: MenuBarLaunchDisposition,
        onboardingState: OnboardingState
    ) -> Bool {
        launchSource == .explicit
            && menuBarDisposition == .normal
            && onboardingState == .neverShown
    }

    static func shouldPresentManualReplay(isRecoveryPresented: Bool) -> Bool {
        !isRecoveryPresented
    }
}

enum OnboardingProviderStatus: Equatable, Sendable {
    case available
    case detected
    case notDetected
    case configured
    case notConfigured
    case disabled
    case unavailable

    static func codex(_ diagnostics: ProviderDiagnosticSnapshot) -> Self {
        if !diagnostics.isEnabled || diagnostics.availability == .disabled {
            return .disabled
        }
        if diagnostics.availability == .available {
            return .available
        }
        if diagnostics.availability == .notInstalled || diagnostics.runtimeDetected == false {
            return .notDetected
        }
        if diagnostics.runtimeDetected == true {
            return .detected
        }
        return .unavailable
    }

    static func claude(_ diagnostics: ProviderDiagnosticSnapshot) -> Self {
        if !diagnostics.isEnabled || diagnostics.availability == .disabled {
            return .disabled
        }
        switch diagnostics.availability {
        case .available, .stale:
            return .configured
        case .notConfigured, .notInstalled:
            return .notConfigured
        case .loading, .unsupportedAuthentication, .failed:
            return .unavailable
        case .disabled:
            return .disabled
        }
    }
}

@MainActor
protocol OnboardingPresentationHandling: AnyObject {
    var isPresented: Bool { get }

    func show(
        mode: OnboardingPresentationMode,
        model: SettingsModel,
        action: @escaping @MainActor (
            OnboardingPresentationMode,
            OnboardingPresentationAction
        ) -> Void,
        didClose: @escaping @MainActor () -> Void
    )
    func focus()
    func teardown()
}

@MainActor
final class OnboardingWindowController: NSObject, OnboardingPresentationHandling, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var hostingController: NSHostingController<OnboardingView>?
    private var mode: OnboardingPresentationMode?
    private var actionHandler: (@MainActor (
        OnboardingPresentationMode,
        OnboardingPresentationAction
    ) -> Void)?
    private var didCloseHandler: (@MainActor () -> Void)?
    private var isClosingForAction = false
    private var isTornDown = false

    var isPresented: Bool {
        windowController?.window?.isVisible == true
    }

    func show(
        mode: OnboardingPresentationMode,
        model: SettingsModel,
        action: @escaping @MainActor (
            OnboardingPresentationMode,
            OnboardingPresentationAction
        ) -> Void,
        didClose: @escaping @MainActor () -> Void
    ) {
        guard !isTornDown else { return }
        guard !isPresented else {
            focus()
            return
        }

        self.mode = mode
        actionHandler = action
        didCloseHandler = didClose
        let rootView = OnboardingView(
            model: model,
            mode: mode,
            skip: { [weak self] in self?.perform(.skip) },
            complete: { [weak self] in self?.perform(.complete) },
            close: { [weak self] in self?.perform(.close) }
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Welcome to QuotaMew")
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.hostingController = hostingController
            windowController = NSWindowController(window: window)
        }

        windowController?.showWindow(nil)
        focus()
    }

    func focus() {
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        actionHandler = nil
        didCloseHandler = nil
        mode = nil
        windowController?.window?.delegate = nil
        windowController?.close()
        windowController?.window?.contentViewController = nil
        hostingController = nil
        windowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let mode else { return }
        if !isClosingForAction {
            actionHandler?(mode, .close)
        }
        isClosingForAction = false
        self.mode = nil
        actionHandler = nil
        let didCloseHandler = didCloseHandler
        self.didCloseHandler = nil
        didCloseHandler?()
    }

    private func perform(_ action: OnboardingPresentationAction) {
        guard let mode, isPresented else { return }
        actionHandler?(mode, action)
        isClosingForAction = true
        windowController?.close()
    }
}
