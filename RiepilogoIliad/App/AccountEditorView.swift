import SwiftUI

/// Add/edit sheet for one SIM. `account` is nil for a new SIM. The password is
/// read from and written to the Keychain only: it is never kept in `Account`
/// (and therefore never in UserDefaults).
struct AccountEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var renewalDay = 0

    let account: Account? // nil = new

    var body: some View {
        Form {
            TextField("Nome (es. SIM 1)", text: $name)
            TextField("ID utente / username", text: $username)
            SecureField("Password", text: $password)
            Stepper("Giorno rinnovo (opzionale): \(renewalDay == 0 ? "—" : "\(renewalDay)")",
                    value: $renewalDay, in: 0...28)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            if let account {
                name = account.name
                username = account.username
                renewalDay = account.renewalDay ?? 0
                password = (try? KeychainCredentialStore().password(for: account.id)) ?? ""
            }
        }
        .toolbar {
            Button("Salva") { save() }
            Button("Annulla") { dismiss() }
        }
    }

    private func save() {
        let credentials = KeychainCredentialStore()
        if var existing = account {
            existing.name = name
            existing.username = username
            existing.renewalDay = renewalDay == 0 ? nil : renewalDay
            if let index = model.settings.accounts.firstIndex(where: { $0.id == existing.id }) {
                model.settings.accounts[index] = existing
            }
            try? credentials.setPassword(password, for: existing.id)
        } else {
            let new = Account(name: name, username: username,
                              renewalDay: renewalDay == 0 ? nil : renewalDay)
            model.settings.accounts.append(new)
            try? credentials.setPassword(password, for: new.id)
        }
        dismiss()
    }
}