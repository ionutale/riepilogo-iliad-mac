import Foundation
import Observation

/// State for a failed bootstrap. Replaces the bare `bootstrapError` string that
/// only the popover ever saw, so all three scenes can render the same diagnosis
/// and offer the same way back.
@MainActor
@Observable
final class BootstrapState {
    /// The underlying failure, shown verbatim (it is a Foundation/`GRDB` message
    /// about a path, not fetched content).
    private(set) var error: String
    /// Where the database is expected. Shown so the user can act on the file
    /// themselves — restore a `.bak`, move it aside, check permissions.
    let databasePath: String
    private(set) var resetMessage: String?

    init(error: String, databasePath: String) {
        self.error = error
        self.databasePath = databasePath
    }

    var databaseURL: URL { URL(fileURLWithPath: databasePath) }

    /// False when the database is not there, so the app does not offer a reset
    /// that would do nothing.
    var canResetHistory: Bool { HistoryReset.hasDatabase(at: databaseURL) }

    /// Renames the database and its sidecars to timestamped `.bak` files and
    /// tells the user to quit and reopen — the app cannot rebuild its schema
    /// while it is running, and the open connection to a file that has just been
    /// moved fails on every read until it restarts.
    func resetHistory() {
        do {
            let moved = try HistoryReset.moveAside(at: databaseURL)
            let names = moved.map(\.lastPathComponent).joined(separator: ", ")
            resetMessage = names.isEmpty
                ? "Non c'era nessun database da spostare."
                : "Database spostato in \(names). Esci e riapri l'app: verrà creato un database vuoto."
        } catch {
            resetMessage = "Impossibile spostare il database: \(error.localizedDescription)"
        }
    }
}
