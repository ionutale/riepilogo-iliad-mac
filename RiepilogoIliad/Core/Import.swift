import Foundation
import GRDB
import Yams

/// Why an import could not be completed. The messages are authored here on
/// purpose: a raw `DecodingError` (or a Yams debug description) quotes the
/// YAML it failed on, and that YAML holds the SIM passwords.
enum ImportError: Error, Equatable, LocalizedError {
    case invalidDatabase
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidDatabase:
            "il file selezionato non è un database storico valido"
        case .invalidDuration:
            "l'intervallo di aggiornamento nel file non è valido"
        }
    }
}

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
    /// Go `time.Duration` text (`4h`), not a number: it has to go through
    /// `parseGoDuration` like the Go app's own parser.
    var refresh_interval: String?
}

private func decodeGoConfig(_ yaml: String) throws -> GoConfig {
    try YAMLDecoder().decode(GoConfig.self, from: yaml)
}

/// Parses the Go app's config.yaml. The Go-only keys (`listen`, `fetch_mode`)
/// are ignored by the decoder, and `renewal_day` is optional because the Go app
/// treats 0 as "unset".
func importAccounts(fromYAML yaml: String) throws -> [ImportedAccount] {
    let config = try decodeGoConfig(yaml)
    return config.accounts.map {
        ImportedAccount(name: $0.name, username: $0.username,
                        password: $0.password, renewalDay: $0.renewal_day)
    }
}

/// The config's `refresh_interval` as a Settings interval, or `nil` when the key
/// is absent. Throws `ImportError.invalidDuration` when it is present but
/// unreadable, so the caller can say so instead of silently keeping the old
/// value.
func importRefreshInterval(fromYAML yaml: String) throws -> TimeInterval? {
    guard let text = try decodeGoConfig(yaml).refresh_interval else { return nil }
    return snapRefreshInterval(try parseGoDuration(text))
}

/// Parses the subset of Go's `time.ParseDuration` syntax the config uses
/// (`4h`, `1h30m`, `90m`, `30s`): unsigned integer components, each carrying an
/// `h`, `m` or `s` unit, in any order, nothing else. Go additionally accepts
/// signs, decimals and finer units; the config never uses them and accepting
/// them would let a typo (`4hours`, `1,5h`, `-1h`) pass for a valid interval.
func parseGoDuration(_ text: String) throws -> TimeInterval {
    var total: TimeInterval = 0
    var digits = ""
    for character in text {
        if character.isASCII, character.isNumber {
            digits.append(character)
            continue
        }
        let unit: TimeInterval
        switch character {
        case "h": unit = 3600
        case "m": unit = 60
        case "s": unit = 1
        default: throw ImportError.invalidDuration
        }
        // An empty `digits` (`"h"`) and an overflowing number are both unusable.
        guard let value = TimeInterval(digits), value.isFinite else {
            throw ImportError.invalidDuration
        }
        total += value * unit
        digits = ""
    }
    // Trailing digits ("1h30") mean a number with no unit, and a zero or empty
    // duration would mean "never refresh". The running total needs its own guard:
    // two components can each be finite and still overflow when summed, and an
    // infinite interval would silently snap to the longest tag.
    guard digits.isEmpty, total > 0, total.isFinite else { throw ImportError.invalidDuration }
    return total
}

/// Snaps a parsed Go interval onto `refreshIntervalTags` (nearest, ties going
/// up) and honours the one-hour floor the first tag and `AppSettings` share:
/// `6h` stays `6h`, `90m` becomes `2h`, `30m` becomes `1h`.
func snapRefreshInterval(_ seconds: TimeInterval) -> TimeInterval {
    let floor = refreshIntervalTags.first ?? 3600
    guard seconds > floor else { return floor }
    return refreshIntervalTags.min { lhs, rhs in
        let (left, right) = (abs(lhs - seconds), abs(rhs - seconds))
        return left == right ? lhs > rhs : left < right // ties round up
    } ?? floor
}

/// What a `config.yaml` import did to the configured SIMs.
struct AccountMerge: Equatable {
    /// One Keychain write. `id` is the existing SIM's id for a matched import,
    /// so the stored password is replaced instead of orphaned, or the new SIM's
    /// id when the SIM is new.
    struct PasswordUpdate: Equatable {
        var id: UUID
        var password: String
    }
    /// The list to persist: existing SIMs updated in place, then the new ones.
    var accounts: [Account]
    var passwords: [PasswordUpdate]
    var addedCount = 0
    var updatedCount = 0
}

/// Merges accounts read from `config.yaml` into the configured ones, matching
/// by name: the Go app requires unique SIM names, so it is the only key both
/// sides agree on (the username is per-SIM and the Go side has no id to match).
/// A matched SIM keeps its `id`, because that id is the Keychain key —
/// re-creating the account would strand the stored password and leave the
/// history rows keyed by a name the coordinator still resolves.
func mergeImportedAccounts(existing: [Account], imported: [ImportedAccount]) -> AccountMerge {
    var merge = AccountMerge(accounts: existing, passwords: [])
    for item in imported {
        var account: Account
        if let index = merge.accounts.firstIndex(where: { $0.name == item.name }) {
            account = merge.accounts[index]
            account.username = item.username
            account.renewalDay = item.renewalDay
            merge.accounts[index] = account
            merge.updatedCount += 1
        } else {
            account = Account(name: item.name, username: item.username,
                              renewalDay: item.renewalDay)
            merge.accounts.append(account)
            merge.addedCount += 1
        }
        // An empty password means "keep the stored one", exactly as in the
        // account editor: a config that omits a password must not wipe it, and a
        // new SIM with no password simply has no Keychain item until the user
        // types one — which "Verifica account" then reports as a missing
        // password rather than an authentication failure.
        if !item.password.isEmpty {
            merge.passwords.append(.init(id: account.id, password: item.password))
        }
    }
    return merge
}

/// The Settings message after an import. Italian counts because Settings is the
/// only place the user ever reads it.
func importSummary(_ merge: AccountMerge, interval: TimeInterval?) -> String {
    let added = "\(merge.addedCount) SIM \(merge.addedCount == 1 ? "importata" : "importate")"
    let updated = "\(merge.updatedCount) \(merge.updatedCount == 1 ? "aggiornata" : "aggiornate")"
    var parts = [added, updated]
    if let interval {
        let hours = Int(interval / 3600)
        parts.append("intervallo \(hours) \(hours == 1 ? "ora" : "ore")")
    }
    return parts.joined(separator: ", ") + "."
}

/// Replaces the history database at `destination` with the Go app's `iliad.db`
/// and its `-wal`/`-shm` sidecars.
///
/// Three rules make the swap safe:
/// 1. The source is validated *before* the destination is touched: picking the
///    wrong file must never cost the user the history they already have.
/// 2. The current database is preserved as `iliad.db.bak` before it is
///    replaced, so a wrong pick is always recoverable.
/// 3. Sidecars are replaced or *removed*, never left behind: SQLite does not
///    check which database a `-wal` (or a hot `-journal`) belongs to before
///    replaying it, so an orphan left by a previous session would be applied to
///    the fresh file.
///
/// Opening the imported file through GRDB (as `Store` does) adds a
/// `grdb_migrations` table to it. That is benign: the Go app ignores tables it
/// does not know and the `readings` schema is untouched.
///
/// Only safe while the app is not running: the live `Store` keeps its own
/// handle on the destination, and once the file is swapped its reads fail with a
/// disk I/O error (verified by `testImportDatabaseOverAnOpenStore`). Settings
/// therefore tells the user to quit, not just to restart.
func importDatabase(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try validateHistoryDatabase(at: source)

    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    try backup(destination, fileManager: fileManager)

    // `-journal` is on the list for the same reason as the WAL pair: `Store` runs
    // in rollback-journal mode, so a crash can leave a hot journal that would
    // otherwise be replayed onto the imported database.
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let sourceFile = URL(fileURLWithPath: source.path + suffix)
        let destinationFile = URL(fileURLWithPath: destination.path + suffix)
        if fileManager.fileExists(atPath: sourceFile.path) {
            try install(sourceFile, at: destinationFile, fileManager: fileManager)
        } else if fileManager.fileExists(atPath: destinationFile.path) {
            try fileManager.removeItem(at: destinationFile)
        }
    }
}

/// Fails unless `url` is a SQLite database carrying the history schema. Opened
/// read-only on purpose: a read-write open of a WAL database checkpoints it,
/// which would rewrite the user's Go file just to look at it.
private func validateHistoryDatabase(at url: URL) throws {
    var configuration = Configuration()
    configuration.readonly = true
    do {
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let tables = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'readings'
                """) ?? 0
        }
        guard tables > 0 else { throw ImportError.invalidDatabase }
    } catch let error as ImportError {
        throw error
    } catch {
        // Not a database at all, or unreadable: either way it cannot be the
        // history import, whatever the underlying reason was.
        throw ImportError.invalidDatabase
    }
}

/// Copies the current database aside as `iliad.db.bak`, replacing an older
/// backup, through SQLite's own backup API rather than a file copy: the API
/// reads through the WAL and writes one self-contained file, so the backup
/// cannot tear, needs no sidecars, and opens on its own afterwards. (Copying
/// `iliad.db` plus a live `-wal`/`-shm` by hand produces a pair that can fail to
/// open at all — SQLite validates the copied `-shm` index against the copied
/// WAL and rejects the mismatch.)
private func backup(_ database: URL, fileManager: FileManager) throws {
    guard fileManager.fileExists(atPath: database.path) else { return }
    let saved = URL(fileURLWithPath: database.path + ".bak")
    if fileManager.fileExists(atPath: saved.path) {
        try fileManager.removeItem(at: saved)
    }
    var configuration = Configuration()
    configuration.readonly = true
    do {
        try DatabaseQueue(path: database.path, configuration: configuration)
            .backup(to: DatabaseQueue(path: saved.path))
    } catch {
        // A destination that is not a readable database still has recoverable
        // bytes, and refusing the import would leave no way to replace a broken
        // one: keep them verbatim instead.
        try? fileManager.removeItem(at: saved)
        try fileManager.copyItem(at: database, to: saved)
    }
}

/// Puts `source` at `destination` through a staging file, so the destination
/// path is never missing: the swap is a rename, which is atomic, where
/// remove-then-copy would leave a window with no database at all.
private func install(_ source: URL, at destination: URL, fileManager: FileManager) throws {
    let staged = URL(fileURLWithPath: destination.path + ".import")
    if fileManager.fileExists(atPath: staged.path) {
        try fileManager.removeItem(at: staged)
    }
    try fileManager.copyItem(at: source, to: staged)
    defer { try? fileManager.removeItem(at: staged) }
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
    } else {
        try fileManager.moveItem(at: staged, to: destination)
    }
}