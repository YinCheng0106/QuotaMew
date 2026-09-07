import SwiftUI

@main
struct QuotaMewApp: App {
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(QuotaMewApplicationDelegate.self)
    private var applicationDelegate
    @State private var runtime: AppDependencies.Runtime

    init() {
        let runtime = AppDependencies.makeRuntime()
        _runtime = State(initialValue: runtime)
        applicationDelegate.configure(
            appModel: runtime.appModel,
            settingsModel: runtime.settingsModel
        )
    }

    var body: some Scene {
        let _ = configureSettingsRoute()
        Settings {
            SettingsView(model: runtime.settingsModel, appModel: runtime.appModel)
        }
    }

    private func configureSettingsRoute() {
        let action = openSettings
        applicationDelegate.settingsSceneRoute.open = { action() }
    }
}
