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
    @State private var checkResults: CheckResultsBox?
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
                    ForEach(refreshIntervalTags, id: \.self) { seconds in
                        Text(hoursLabel(seconds)).tag(seconds)
                    }
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
                    Task { checkResults = CheckResultsBox(results: await model.coordinator.checkAccounts()) }
                }
                // A check drives the same Safari tab as an in-flight cycle, and
                // its first step logs the portal session out; running both at
                // once would turn a working SIM into a bogus credential failure.
                .disabled(model.isRefreshing)
                if model.isRefreshing {
                    Text("Verifica account non disponibile mentre un aggiornamento è in corso.")
                        .font(.caption).foregroundStyle(.secondary)
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
        // The sleep loop reads the interval once per cycle, so a change here has
        // to cancel the pending sleep rather than wait it out.
        .onChange(of: model.settings.refreshInterval) { model.rescheduleTimer() }
        .sheet(item: $editing) { editing in
            AccountEditorView(account: editing.account)
                .environment(model)
        }
        .sheet(item: $checkResults) { box in
            CheckResultsView(results: box.results).environment(model)
        }
    }

    private func hoursLabel(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        return "\(hours) \(hours == 1 ? "ora" : "ore")"
    }

    private func remove(_ account: Account) {
        model.settings.accounts.removeAll { $0.id == account.id }
        try? KeychainCredentialStore().deletePassword(for: account.id)
        // Without this the deleted SIM keeps its card and keeps counting toward
        // the menu-bar total at its frozen quota until the app is relaunched.
        Task { await model.accountsChanged() }
    }

    private func importAccountsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let yaml = try String(contentsOf: url, encoding: .utf8)
            let merge = mergeImportedAccounts(existing: model.settings.accounts,
                                              imported: try importAccounts(fromYAML: yaml))
            for update in merge.passwords {
                try? KeychainCredentialStore().setPassword(update.password, for: update.id)
            }
            model.settings.accounts = merge.accounts

            // The interval is imported too (the Go config's `refresh_interval`),
            // but a bad value must not throw away the accounts just imported:
            // it is reported next to the counts instead.
            var interval: TimeInterval?
            var intervalIgnored = false
            do {
                interval = try importRefreshInterval(fromYAML: yaml)
            } catch {
                intervalIgnored = true
            }
            if let interval { model.settings.refreshInterval = interval }

            var message = importSummary(merge, interval: interval)
            if intervalIgnored { message += " Intervallo ignorato: non valido." }
            importMessage = message
            // Imported SIMs must render at once: the interval imported above also
            // has to take effect without waiting out the old sleep.
            if interval != nil { model.rescheduleTimer() }
            Task { await model.accountsChanged() }
        } catch {
            // Never the raw error: a decoding failure quotes the YAML it failed
            // on, and that YAML holds the passwords.
            importMessage = "Import non riuscito: file non valido"
        }
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
            // Quitting is the instruction, not restarting: the app's open connection stops
            // working the moment the file is swapped (its reads fail with a disk
            // I/O error until it starts again), and the backup is the user's way
            // back if the file they picked was wrong.
            importMessage = "Storico importato (il precedente è in iliad.db.bak). Esci e riapri l'app."
        } catch {
            let reason = (error as? ImportError)?.errorDescription ?? "file non valido"
            importMessage = "Import non riuscito: \(reason)"
        }
    }
}

/// Identifiable box so the check results can drive `sheet(item:)`: an empty
/// result set would otherwise be indistinguishable from "no sheet". The
/// identity is fixed when the results are assigned, so re-reading the sheet's
/// binding cannot restart the sheet under the user.
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