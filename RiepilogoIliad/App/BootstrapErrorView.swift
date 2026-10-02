import SwiftUI

/// Shown in every scene when the app could not open its database.
///
/// A dead end is not acceptable here: without a visible diagnosis (and a way to
/// move the file aside) a corrupt `iliad.db` leaves the user with an app that
/// shows nothing and cannot be repaired from inside itself. The reset action
/// only ever *renames* — if the database turned out to be fine, it is still there
/// to rename back.
struct BootstrapErrorView: View {
    let state: BootstrapState
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Errore all'avvio")
                .font(.headline)
            Text(state.error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("Database")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.databasePath)
                    .font(.caption).monospaced()
                    .textSelection(.enabled)
            }
            Text("Puoi spostare il database: verrà rinominato con il suffisso `.bak` "
                 + "(niente viene cancellato) e al prossimo avvio l'app ne creerà uno vuoto.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Sposta il database") { confirmingReset = true }
                    .disabled(!state.canResetHistory)
                if let message = state.resetMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Dopo aver spostato il database: esci e riapri l'app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
        .confirmationDialog(
            "Spostare il database?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Sposta", role: .destructive) { state.resetHistory() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Il database e i suoi file di supporto (wal e shm) vengono "
                 + "rinominati aggiungendo data e ora. Nessun dato viene cancellato.")
        }
    }
}
