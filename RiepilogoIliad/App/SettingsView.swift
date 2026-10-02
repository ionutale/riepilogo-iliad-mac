import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Sheet payload: the SIM being edited, or nil for a new one. `Identifiable`
/// so a single `sheet(item:)` can present both cases.
struct EditingAccount: Identifiable {
    let id = UUID()
    let account: Account? // nil = new
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditingAccount?
    @State private var checkResults: [CheckResult]?
    @State private var importMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Account") {
                ForEach(model.settings.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(account.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Modifica") { editing = EditingAccount(account: account) }
                        Button(role: .destructive) { remove(account) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Button("Aggiungi SIM") { editing = EditingAccount(account: nil) }
            }

            Section("Aggiornamento") {
                Picker("Intervallo", selection: Bindable(model.settings).refreshInterval) {
                    Text("1 ora").tag(TimeInterval(3600))
                    Text("2 ore").tag(TimeInterval(7200))
                    Text("4 ore").tag(TimeInterval(14400))
                    Text("8 ore").tag(TimeInterval(28800))
                    Text("24 ore").tag(TimeInterval(86400))
                }
                Picker("Modalità", selection: Bindable(model.settings).fetchMode) {
                    ForEach(FetchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Soglia dati bassi: \(Int(model.settings.lowThresholdPercent))%",
                        value: Bindable(model.settings).lowThresholdPercent, in: 5...50, step: 5)
            }

            Section("Sistema") {
                Toggle("Notifiche", isOn: Bindable(model.settings).notificationsEnabled)
                    .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                        // Permission is asked when the user turns notifications on,
                        // not at launch: a prompt nobody asked for is a prompt
                        // people deny.
                        if enabled { Task { await SystemNotificationPoster.shared.requestAuthorization() } }
                    }
                Toggle("Apri al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }

            Section("Diagnostica") {
                Button("Verifica account") {
                    Task { checkResults = await model.coordinator.checkAccounts() }
                }
                Button("Importa account da config.yaml") { importAccountsFromFile() }
                Button("Importa storico da iliad.db") { importHistoryFromFile() }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .sheet(item: $editing) { editing in
            AccountEditorView(account: editing.account)
                .environment(model)
        }
        .sheet(item: Binding(
            get: { checkResults.map(CheckResultsBox.init) },
            set: { if $0 == nil { checkResults = nil } })) { box in
            CheckResultsView(results: box.results).environment(model)
        }
    }

    private func remove(_ account: Account) {
        model.settings.accounts.removeAll { $0.id == account.id }
        try? KeychainCredentialStore().deletePassword(for: account.id)
    }

    private func importAccountsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url,
              let yaml = try? String(contentsOf: url, encoding: .utf8),
              let imported = try? importAccounts(fromYAML: yaml) else { return }
        let credentials = KeychainCredentialStore()
        for item in imported {
            let account = Account(name: item.name, username: item.username, renewalDay: item.renewalDay)
            model.settings.accounts.append(account)
            try? credentials.setPassword(item.password, for: account.id)
        }
        importMessage = "Importate \(imported.count) SIM."
    }

    private func importHistoryFromFile() {
        let panel = NSOpenPanel()
        // `.data` as well as `.database`: macOS resolves the `db` extension to a
        // dynamic UTI that does not conform to `public.database`, so a
        // `.database`-only panel would grey out the very file we are asking for.
        panel.allowedContentTypes = [.database, .data]
        guard panel.runModal() == .OK, let url = panel.url,
              let destination = try? Store.defaultURL() else { return }
        do {
            try importDatabase(from: url, to: destination)
            importMessage = "Storico importato. Riavvia l'app per vederlo."
        } catch {
            importMessage = "Import non riuscito: \(error.localizedDescription)"
        }
    }
}

/// Identifiable box so the check results can drive `sheet(item:)`: an empty
/// result set would otherwise be indistinguishable from "no sheet".
struct CheckResultsBox: Identifiable {
    let id = UUID()
    let results: [CheckResult]
}

struct CheckResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let results: [CheckResult]

    var body: some View {
        Table(results) {
            TableColumn("SIM", value: \.account)
            TableColumn("Esito") { Text($0.ok ? "OK" : "KO") }
            TableColumn("Via") { Text($0.path?.rawValue ?? "—") }
            TableColumn("Restanti") { Text($0.remainingGB.map(formatGB) ?? "—") }
            TableColumn("Rinnovo") { Text($0.renewalDate.map(formatDate) ?? "—") }
            TableColumn("Errore") { Text($0.error ?? "") }
        }
        .frame(width: 640, height: 260)
        .toolbar { Button("Chiudi") { dismiss() } }
    }
}