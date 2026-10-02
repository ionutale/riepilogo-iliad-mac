import Foundation

/// Moves the database out of the way when it cannot be opened, so the app can
/// start again instead of dead-ending at a bootstrap error.
///
/// Renames only — nothing is ever deleted. A user whose database was merely
/// mis-imported, or who clicks this without needing to, keeps every row in a
/// timestamped `.bak` file they can rename back.
enum HistoryReset {
    /// `iliad.db-wal` and `iliad.db-shm` are SQLite's write-ahead log and
    /// shared-memory index. Leaving them behind next to a freshly created
    /// `iliad.db` would hand the new database a stale log.
    static let sidecarSuffixes = ["-wal", "-shm"]

    static func timestampStamp(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `iliad.db` -> `iliad.db.20261003-011530.bak`. The stamp comes first so the
    /// name is still recognisable as the database in a file listing.
    static func backupName(for source: URL, stamp: String, attempt: Int = 1) -> String {
        let base = attempt == 1
            ? "\(source.lastPathComponent).\(stamp).bak"
            : "\(source.lastPathComponent).\(stamp)-\(attempt).bak"
        return base
    }

    /// Moves the database and every existing sidecar aside. Returns the
    /// destinations, in the order moved; empty when the database is already
    /// gone (nothing to reset).
    ///
    /// The stamp is computed once for the whole operation so the three renamed
    /// files stay obviously related, and a collision within the same second
    /// falls back to a `-2`, `-3`, … suffix rather than overwriting a previous
    /// backup — losing a backup would defeat the point.
    @discardableResult
    static func moveAside(at database: URL,
                          now: Date = Date(),
                          timeZone: TimeZone = romeTimeZone,
                          fileManager: FileManager = .default) throws -> [URL] {
        let directory = database.deletingLastPathComponent()
        let stamp = timestampStamp(for: now, timeZone: timeZone)
        let sources = [database] + sidecarSuffixes.map {
            directory.appendingPathComponent(database.lastPathComponent + $0)
        }

        var moved: [URL] = []
        for source in sources where fileManager.fileExists(atPath: source.path) {
            var attempt = 1
            var destination = directory.appendingPathComponent(
                backupName(for: source, stamp: stamp, attempt: attempt))
            while fileManager.fileExists(atPath: destination.path) {
                attempt += 1
                destination = directory.appendingPathComponent(
                    backupName(for: source, stamp: stamp, attempt: attempt))
            }
            try fileManager.moveItem(at: source, to: destination)
            moved.append(destination)
        }
        return moved
    }

    /// True when there is something to move. Drives whether the reset action is
    /// offered at all.
    static func hasDatabase(at database: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: database.path)
    }
}
