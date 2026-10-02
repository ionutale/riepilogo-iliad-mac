import Foundation
import Yams

struct ImportedAccount: Sendable {
    var name: String
    var username: String
    var password: String
    var renewalDay: Int?
}

private struct GoConfig: Decodable {
    struct GoAccount: Decodable {
        var name: String
        var username: String
        var password: String
        var renewal_day: Int?
    }
    var accounts: [GoAccount]
}

/// Parses the Go app's config.yaml. Only `accounts` is read: the Go-only keys
/// (`listen`, `fetch_mode`) are ignored by the decoder, and `renewal_day` is
/// optional because the Go app treats 0 as "unset".
func importAccounts(fromYAML yaml: String) throws -> [ImportedAccount] {
    let config = try YAMLDecoder().decode(GoConfig.self, from: yaml)
    return config.accounts.map {
        ImportedAccount(name: $0.name, username: $0.username,
                        password: $0.password, renewalDay: $0.renewal_day)
    }
}

/// Copies a Go `iliad.db` to the destination path, plus its `-wal`/`-shm`
/// sidecars when the source has them.
///
/// The sidecars matter: a database left in WAL mode keeps recent rows in
/// `iliad.db-wal` until it is checkpointed, so copying the main file alone
/// would silently drop the most recent readings. Each copied file replaces an
/// existing destination file.
///
/// Two things the caller must know:
/// - Sidecars the *source* lacks are not touched. SQLite does not validate a
///   `-wal` against the database file it sits next to, so an orphan left by an
///   earlier session can be replayed into the freshly copied database and
///   surface as malformed or stale rows. The copy is only safe into a directory
///   whose database is closed, and a running `Store` keeps (re)creating its own
///   `-wal` at that very path — so importing from inside the running app is not
///   the safe case the "restart the app afterwards" message implies.
/// - Opening the imported file through GRDB (as `Store` does) adds a
///   `grdb_migrations` table to it. That is benign: the Go app ignores tables
///   it does not know and the `readings` schema is untouched.
func importDatabase(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
        let sourceFile = URL(fileURLWithPath: source.path + suffix)
        let destinationFile = URL(fileURLWithPath: destination.path + suffix)
        if fileManager.fileExists(atPath: sourceFile.path) {
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            try fileManager.copyItem(at: sourceFile, to: destinationFile)
        }
    }
}