import AppKit
import SwiftUI

/// Bridges the App's public SwiftUI Settings action to the retained AppKit controller.
@MainActor
final class SettingsSceneRoute {
    var open: (@MainActor () -> Void)?
}

@MainActor
final class StatusItemContextMenu: NSObject {
    let menu = NSMenu()
    private let refresh: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private let quit: @MainActor () -> Void

    init(
        refresh: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.refresh = refresh
        self.openSettings = openSettings
        self.quit = quit
        super.init()
        menu.autoenablesItems = false
        add("Refresh Now", action: #selector(refreshNow), locale: locale)
        add("Settings…", action: #selector(showSettings), locale: locale)
        menu.addItem(.separator())
        add("Quit QuotaMew", action: #selector(quitApplication), keyEquivalent: "q", locale: locale)
    }

    private func add(
        _ title: String.LocalizationValue,
        action: Selector,
        keyEquivalent: String = "",
        locale: Locale
    ) {
        let item = NSMenuItem(
            title: AppLocalization.string(title, locale: locale),
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshNow() { refresh() }
    @objc private func showSettings() { openSettings() }
    @objc private func quitApplication() { quit() }

    func teardown() {
        menu.cancelTracking()
        for item in menu.items {
            item.target = nil
            item.action = nil
        }
    }
}
