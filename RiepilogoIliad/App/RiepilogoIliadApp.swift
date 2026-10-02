import SwiftUI

@main
struct RiepilogoIliadApp: App {
    @State private var model: AppModel?
    @State private var bootstrapError: String?

    init() {
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
            _bootstrapError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                PopoverView().environment(model)
            } else {
                Text("Errore avvio: \(bootstrapError ?? "sconosciuto")").padding()
            }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // The Settings scene is added in Task 12.
        Window("Storico", id: "history") {
            if let model { HistoryWindow().environment(model) }
        }
    }
}
