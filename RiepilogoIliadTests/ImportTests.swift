import Foundation
import GRDB
import XCTest
@testable import RiepilogoIliad

final class ImportTests: XCTestCase {
    private let yaml = """
    listen: 127.0.0.1:8787
    refresh_interval: 4h
    fetch_mode: safari
    accounts:
      - name: SIM 1
        username: user1
        password: pass1
        renewal_day: 17
      - name: SIM 2
        username: user2
        password: pass2
    """

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    /// A database with the table the importer requires, in rollback-journal mode
    /// so no sidecars appear next to it: a WAL-mode source would bring its
    /// `-wal`/`-shm` along and defeat the stale-sidecar test. `fetched_at` is
    /// only there so `Store` can reopen an imported file — the importer itself
    /// needs nothing but a table named `readings`.
    private func makeSourceDatabase(at url: URL, table: String = "readings") throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "CREATE TABLE " + table + " (id INTEGER PRIMARY KEY, account TEXT, fetched_at TEXT)")
        }
    }

    // MARK: - config.yaml accounts

    func testImportAccountsFromYAML() throws {
        let imported = try importAccounts(fromYAML: yaml)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].name, "SIM 1")
        XCTAssertEqual(imported[0].username, "user1")
        XCTAssertEqual(imported[0].password, "pass1")
        XCTAssertEqual(imported[0].renewalDay, 17)
        XCTAssertNil(imported[1].renewalDay)
    }

    // MARK: - refresh_interval

    func testParseGoDurationReadsGoSyntax() throws {
        XCTAssertEqual(try parseGoDuration("4h"), 14400)
        XCTAssertEqual(try parseGoDuration("1h30m"), 5400)
        XCTAssertEqual(try parseGoDuration("90m"), 5400)
        XCTAssertEqual(try parseGoDuration("30s"), 30)
    }

    func testParseGoDurationRejectsEverythingElse() {
        for text in ["invalid", "4", "h", "1h30", "4hours", "1.5h", "-1h", "1H", "", "0h"] {
            XCTAssertThrowsError(try parseGoDuration(text), text) { error in
                XCTAssertEqual(error as? ImportError, .invalidDuration, text)
            }
        }
        // Each component is finite on its own (`Double` of 307 nines is ~1e306); the
        // sum overflows. An infinite interval would otherwise snap to 24 h.
        let huge = String(repeating: "9", count: 307)
        XCTAssertThrowsError(try parseGoDuration(huge + "h" + huge + "h"), "sum overflow") { error in
            XCTAssertEqual(error as? ImportError, .invalidDuration)
        }
    }

    func testSnapRefreshIntervalPicksNearestTag() {
        XCTAssertEqual(snapRefreshInterval(6 * 3600), 6 * 3600)
        XCTAssertEqual(snapRefreshInterval(90 * 60), 2 * 3600)
        XCTAssertEqual(snapRefreshInterval(30 * 60), 1 * 3600)
    }

    func testSnapRefreshIntervalRoundsTiesUpAndFloorsTheRest() {
        // Midpoint between 4h and 6h: the higher tag wins.
        XCTAssertEqual(snapRefreshInterval(5 * 3600), 6 * 3600)
        // Beyond the last tag, and below the first one, stay on the ends.
        XCTAssertEqual(snapRefreshInterval(100 * 3600), 24 * 3600)
        XCTAssertEqual(snapRefreshInterval(refreshIntervalTags.first!), 1 * 3600)
        XCTAssertEqual(snapRefreshInterval(0), 1 * 3600)
    }

    func testImportRefreshIntervalFromYAML() throws {
        XCTAssertEqual(try importRefreshInterval(fromYAML: yaml), 4 * 3600)
        let withoutInterval = "accounts:\n  - name: SIM 1\n    username: u\n    password: p\n"
        XCTAssertNil(try importRefreshInterval(fromYAML: withoutInterval))
        let badInterval = yaml.replacingOccurrences(of: "4h", with: "four hours")
        XCTAssertThrowsError(try importRefreshInterval(fromYAML: badInterval)) { error in
            XCTAssertEqual(error as? ImportError, .invalidDuration)
        }
    }

    func testEveryPickerTagIsASnapResult() {
        for tag in refreshIntervalTags {
            XCTAssertEqual(snapRefreshInterval(tag), tag, "\(tag) must survive its own snap")
        }
    }

    // MARK: - account merge

    func testMergeUpdatesMatchingAccountAndKeepsItsID() throws {
        let id = UUID()
        let existing = [Account(id: id, name: "SIM 1", username: "old", renewalDay: nil)]
        let imported = [ImportedAccount(name: "SIM 1", username: "user1",
                                        password: "newpass", renewalDay: 17)]

        let merge = mergeImportedAccounts(existing: existing, imported: imported)

        XCTAssertEqual(merge.accounts.count, 1)
        XCTAssertEqual(merge.accounts[0].id, id, "the Keychain key must survive the merge")
        XCTAssertEqual(merge.accounts[0].username, "user1")
        XCTAssertEqual(merge.accounts[0].renewalDay, 17)
        XCTAssertEqual(merge.updatedCount, 1)
        XCTAssertEqual(merge.addedCount, 0)
        XCTAssertEqual(merge.passwords, [.init(id: id, password: "newpass")],
                       "the imported password must replace the stored one for the same id")
    }

    func testMergeAddsUnknownAccountsWithNewIDs() throws {
        let id = UUID()
        let existing = [Account(id: id, name: "SIM 1", username: "user1")]

        let merge = mergeImportedAccounts(existing: existing, imported: [
            ImportedAccount(name: "SIM 2", username: "user2", password: "pass2", renewalDay: 3),
        ])

        XCTAssertEqual(merge.accounts.count, 2)
        let added = try XCTUnwrap(merge.accounts.last)
        XCTAssertEqual(added.name, "SIM 2")
        XCTAssertNotEqual(added.id, id)
        XCTAssertEqual(added.renewalDay, 3)
        XCTAssertEqual(merge.addedCount, 1)
        XCTAssertEqual(merge.updatedCount, 0)
        XCTAssertEqual(merge.passwords, [.init(id: added.id, password: "pass2")])
        // The pre-existing SIM is untouched.
        XCTAssertEqual(merge.accounts[0].id, id)
        XCTAssertEqual(merge.accounts[0].username, "user1")
    }

    func testMergeCountsAddAndUpdate() throws {
        let merge = mergeImportedAccounts(
            existing: [Account(name: "SIM 1", username: "user1"),
                       Account(name: "SIM 2", username: "user2")],
            imported: [
                ImportedAccount(name: "SIM 1", username: "user1", password: "p1"),
                ImportedAccount(name: "SIM 3", username: "user3", password: "p3"),
            ])

        XCTAssertEqual(merge.accounts.count, 3, "an existing SIM must not be duplicated")
        XCTAssertEqual(merge.updatedCount, 1)
        XCTAssertEqual(merge.addedCount, 1)
        XCTAssertEqual(merge.passwords.count, 2)
    }

    func testMergeKeepsStoredPasswordWhenTheConfigHasNone() throws {
        let id = UUID()
        let existing = [Account(id: id, name: "SIM 1", username: "user1")]

        let merge = mergeImportedAccounts(existing: existing, imported: [
            ImportedAccount(name: "SIM 1", username: "user1", password: ""),
            ImportedAccount(name: "SIM 2", username: "user2", password: ""),
        ])

        XCTAssertEqual(merge.accounts.count, 2)
        XCTAssertEqual(merge.updatedCount, 1)
        XCTAssertEqual(merge.addedCount, 1)
        XCTAssertEqual(merge.passwords, [],
                       "an empty password must not overwrite (or create) a Keychain item")
    }

    func testImportSummaryCountsInItalian() {
        let merge = AccountMerge(accounts: [], passwords: [],
                                 addedCount: 1, updatedCount: 2)
        XCTAssertEqual(importSummary(merge, interval: nil), "1 SIM importata, 2 aggiornate.")
        XCTAssertEqual(importSummary(merge, interval: 4 * 3600),
                       "1 SIM importata, 2 aggiornate, intervallo 4 ore.")
        let single = AccountMerge(accounts: [], passwords: [], addedCount: 0, updatedCount: 1)
        XCTAssertEqual(importSummary(single, interval: 3600),
                       "0 SIM importate, 1 aggiornata, intervallo 1 ora.")
    }

    // MARK: - database import

    func testImportDatabaseCopiesSidecars() throws {
        let source = tempDir.appendingPathComponent("iliad.db")
        try makeSourceDatabase(at: source)
        try Data("wal".utf8).write(to: tempDir.appendingPathComponent("iliad.db-wal"))
        let destination = tempDir.appendingPathComponent("dest/iliad.db")

        try importDatabase(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-wal")), Data("wal".utf8))
    }

    func testImportDatabaseRejectsFileWithoutReadingsAndLeavesDestinationAlone() throws {
        let source = tempDir.appendingPathComponent("other.db")
        try makeSourceDatabase(at: source, table: "something_else")
        let destination = tempDir.appendingPathComponent("dest/iliad.db")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("history so far".utf8).write(to: destination)

        XCTAssertThrowsError(try importDatabase(from: source, to: destination)) { error in
            XCTAssertEqual(error as? ImportError, .invalidDatabase)
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("history so far".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".bak"),
                       "a rejected import must not leave a backup behind")
    }

    func testImportDatabaseRejectsNonDatabaseFile() throws {
        let source = tempDir.appendingPathComponent("iliad.db")
        try Data("this is not sqlite".utf8).write(to: source)
        let destination = tempDir.appendingPathComponent("dest/iliad.db")

        XCTAssertThrowsError(try importDatabase(from: source, to: destination)) { error in
            XCTAssertEqual(error as? ImportError, .invalidDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testImportDatabaseRemovesStaleSidecarsWhenSourceHasNone() throws {
        let source = tempDir.appendingPathComponent("iliad.db")
        try makeSourceDatabase(at: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-wal"))
        let destination = tempDir.appendingPathComponent("dest/iliad.db")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old db".utf8).write(to: destination)
        try Data("stale wal".utf8).write(to: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-wal"))
        try Data("stale shm".utf8).write(to: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-shm"))
        // A hot rollback journal is the same hazard in `Store`'s journal mode.
        try Data("stale journal".utf8).write(to: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-journal"))

        try importDatabase(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-wal"),
                       "a stale WAL would be replayed over the imported database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-journal"),
                       "a hot journal would be replayed over the imported database")
    }

    func testImportDatabaseBacksUpTheExistingDatabase() throws {
        let source = tempDir.appendingPathComponent("go.db")
        try makeSourceDatabase(at: source)
        let destination = tempDir.appendingPathComponent("dest/iliad.db")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existing = try Store(path: destination.path)
        try existing.insert(Reading.success(account: "SIM 1", data: sampleData, fetchedAt: importDate))
        // An older backup, with no history schema at all: it must be replaced,
        // not appended to or left as is.
        let backupURL = destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db.bak")
        try makeSourceDatabase(at: backupURL, table: "stale")

        try importDatabase(from: source, to: destination)

        let backup = try Store(path: backupURL.path)
        XCTAssertEqual(try backup.history(account: "SIM 1", since: epoch).map(\.account),
                       ["SIM 1"], "the previous history must be recoverable from the .bak")
        XCTAssertEqual(try rowCount(at: destination, table: "readings"), 0,
                       "the destination must now hold the imported database, not the old history")
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".import"),
                       "the staging file must not be left behind")
    }

    private func rowCount(at url: URL, table: String) throws -> Int {
        try DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM " + table) ?? -1
        }
    }

    func testImportDatabaseReplacesAnOlderBackup() throws {
        let source = tempDir.appendingPathComponent("iliad.db")
        try makeSourceDatabase(at: source)
        let destination = tempDir.appendingPathComponent("dest/iliad.db")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old backup".utf8).write(to: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db.bak"))
        try Data("the previous history".utf8).write(to: destination)

        try importDatabase(from: source, to: destination)

        let backup = destination.deletingLastPathComponent().appendingPathComponent("iliad.db.bak")
        XCTAssertEqual(try Data(contentsOf: backup), Data("the previous history".utf8))
    }

    func testImportDatabaseOverAnOpenStoreKeepsTheBackupUsable() throws {
        // The real situation: the running app holds the destination open.
        let destination = tempDir.appendingPathComponent("iliad.db")
        let live = try Store(path: destination.path)
        try live.insert(Reading.success(account: "SIM 1", data: sampleData, fetchedAt: importDate))
        let source = tempDir.appendingPathComponent("go.db")
        let goStore = try Store(path: source.path)
        try goStore.insert(Reading.success(account: "SIM 2", data: sampleData, fetchedAt: importDate))

        try importDatabase(from: source, to: destination)

        // The .bak is a complete database on its own.
        let backupURL = destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db.bak")
        let backup = try Store(path: backupURL.path)
        XCTAssertEqual(try backup.history(account: "SIM 1", since: epoch).map(\.account), ["SIM 1"])

        // A connection opened after the swap sees the imported history...
        let reopened = try Store(path: destination.path)
        XCTAssertEqual(try reopened.history(account: "SIM 2", since: epoch).map(\.account), ["SIM 2"])
        XCTAssertEqual(try reopened.history(account: "SIM 1", since: epoch).count, 0)
        // ...while the connection the app opened at launch cannot read either file
        // any more. That is why Settings says "quit and relaunch" rather than the
        // softer "restart": the running app would report a disk I/O error on
        // every refresh until it starts again.
        XCTAssertThrowsError(try live.history(account: "SIM 1", since: epoch))
    }

    private var importDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private var epoch: Date { Date(timeIntervalSince1970: 0) }

    private var sampleData: AccountData {
        AccountData(creditEUR: nil, usedGB: 1, remainingGB: 9, allowanceGB: 10,
                    renewalDate: nil, periodStart: nil, periodEnd: nil,
                    phoneNumber: "3511112222", offerName: "GIGA 200")
    }
}