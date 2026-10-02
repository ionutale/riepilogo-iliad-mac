import SwiftUI

@main
struct RiepilogoIliadApp: App {
    @State private var model: AppModel?
    @State private var bootstrap: BootstrapState?

    init() {
        // The test bundle is app-hosted, so this `init` runs during `make test`
        // too. Booting for real would open the developer's own `iliad.db`, prune
        // their history, show a menu-bar icon, ask for notification permission
        // and — with accounts configured — log into iliad.it with their stored
        // passwords. The suite has to be hermetic.
        guard !AppBootstrap.isRunningTests else { return }
        do {
            let settings = AppSettings()
            let runtime = settings.runtime
            let store = try Store(path: Store.defaultURL().path)
            let fetcher = AutoFetcher(direct: HTTPFetcher(), safari: SafariFetcher(),
                                      modeProvider: { runtime.fetchMode })
            let notifier = NotificationDecider(
                thresholdProvider: { runtime.lowThresholdPercent },
                enabledProvider: { runtime.notificationsEnabled })
            let coordinator = try RefreshCoordinator(
                store: store, fetcher: fetcher, credentials: KeychainCredentialStore(),
                accounts: { runtime.accounts }, notifier: notifier)
            let appModel = AppModel(settings: settings, coordinator: coordinator)
            appModel.start()
            _model = State(initialValue: appModel)
        } catch {
            _bootstrap = State(initialValue: BootstrapState(
                error: error.localizedDescription,
                databasePath: Store.defaultPathDescription()))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                PopoverView().environment(model)
            } else if let bootstrap {
                BootstrapErrorView(state: bootstrap)
            }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            scene { SettingsView() }
        }

        Window("Storico", id: "history") {
            scene { HistoryWindow() }
        }
    }

    /// Every scene shows the same thing: either the working app, or the same
    /// bootstrap diagnosis. A blank Settings or History window on a bootstrap
    /// failure left the user with no diagnosis and no way forward.
    @ViewBuilder
    private func scene<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let model {
            content().environment(model)
        } else if let bootstrap {
            BootstrapErrorView(state: bootstrap)
        }
    }
}
