import Foundation

enum AppRuntimeEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var shouldCreateStatusItemController: Bool {
        !isRunningTests
    }
}

@MainActor
enum AppDependencies {
    struct Runtime {
        let appModel: AppModel
        let activityService: ActivityService
        let activityStore: ActivitySnapshotStore
        let settingsModel: SettingsModel
    }

    static func makeLiveProviders() -> [any UsageProvider] {
        [CodexProvider(), ClaudeProvider()]
    }

    static func makeAppModel(
        providers: [any UsageProvider] = makeLiveProviders(),
        preferences: SettingsStore? = nil,
        notificationService: (any NotificationServicing)? = nil
    ) -> AppModel {
        let usageService = UsageService(providers: providers, preferences: preferences)
        let refreshCoordinator = RefreshCoordinator(usageService: usageService)
        let runsAutomatically = !AppRuntimeEnvironment.isRunningTests

        let resolvedNotificationService = notificationService
            ?? NotificationService(preferences: preferences)
        resolvedNotificationService.prepareForLaunch()
        let model = AppModel(
            providerIDs: providers.map(\.id),
            enabledProviderIDs: Set(
                providers.map(\.id).filter { preferences?.isProviderEnabled($0) ?? true }
            ),
            refreshCoordinator: refreshCoordinator,
            notificationService: resolvedNotificationService,
            observesLifecycle: runsAutomatically
        )
        if runsAutomatically {
            model.start()
        }
        return model
    }

    static func makeRuntime(
        settingsStore: SettingsStore = SettingsStore(),
        codexClient: CodexAppServerClient? = nil
    ) -> Runtime {
        let client = codexClient ?? CodexAppServerClient(locator: CodexExecutableLocator())
        let providers: [any UsageProvider] = [
            CodexProvider(reader: client, runtimeDiagnosticReader: client), ClaudeProvider(),
        ]
        let activityStore = ActivitySnapshotStore()
        let activityService = ActivityService(
            sources: [CodexTokenActivitySource(reader: client)],
            store: activityStore, settings: settingsStore
        )
        let notificationService = NotificationService(preferences: settingsStore)
        let appModel = makeAppModel(
            providers: providers,
            preferences: settingsStore,
            notificationService: notificationService
        )
        return Runtime(
            appModel: appModel,
            activityService: activityService,
            activityStore: activityStore,
            settingsModel: SettingsModel(
                store: settingsStore,
                appModel: appModel,
                notificationService: notificationService
            )
        )
    }

    static func makePreviewModel(now: Date = .now) -> AppModel {
        let providers: [any UsageProvider] = [
            MockUsageProvider.codex(now: now),
            MockUsageProvider.claude(now: now),
        ]
        let usageService = UsageService(providers: providers)
        let refreshCoordinator = RefreshCoordinator(usageService: usageService)

        return AppModel(
            providerIDs: providers.map(\.id),
            refreshCoordinator: refreshCoordinator,
            notificationService: PreviewNotificationService(),
            observesLifecycle: false
        )
    }
}

@MainActor
private final class PreviewNotificationService: NotificationServicing {
    func evaluate(_ providerStates: [ProviderState], now: Date) async {}

    #if DEBUG
    func sendTestNotification() async throws {}
    #endif
}
