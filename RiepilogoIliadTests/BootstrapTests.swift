import XCTest
@testable import RiepilogoIliad

/// The test bundle is app-hosted (`TEST_HOST` points at the app binary), so
/// `RiepilogoIliadApp.init()` runs during `make test`. Its guard is the only
/// thing keeping the suite off the developer's own database, credentials, Safari
/// and menu bar, so the predicate itself is pinned here: if it ever went false,
/// the suite would silently boot the production app again.
final class BootstrapTests: XCTestCase {
    func testTestRunnerIsDetected() {
        XCTAssertTrue(AppBootstrap.isRunningTests,
                      "the bootstrap guard must be active under XCTest, or `make test` "
                      + "opens the real iliad.db and logs into iliad.it")
    }

    func testStoreDefaultPathIsTheApplicationSupportDatabase() throws {
        // The bootstrap-error surface shows this path, so it has to be the one the
        // store actually opens.
        let path = Store.defaultPathDescription()
        XCTAssertTrue(path.hasSuffix("Library/Application Support/RiepilogoIliad/iliad.db"),
                      "got \(path)")
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory()))
        // ...and it must sit in exactly the directory `defaultURL()` uses, or the
        // reset would act on a different file than the one the app failed to
        // open. Compared against the non-creating form on purpose: calling
        // `defaultURL()` here would create the very directory this suite has to
        // leave alone.
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path,
                       try Store.defaultDirectory(createIfNeeded: false).path)
    }

    /// Hermeticity is verified outside the suite too — see
    /// `.superpowers/sdd/2026-10-02-riepilogo-iliad-mac/final-fix-report.md`:
    /// moving the database aside, running the full suite, and confirming it was
    /// not recreated. It cannot be asserted from inside the run, because by the
    /// time a test could look, the whole process has already had its chance to
    /// touch the file.
    func testDefaultPathDescriptionCreatesNothing() throws {
        let path = Store.defaultPathDescription()
        let existed = FileManager.default.fileExists(atPath: path)
        _ = Store.defaultPathDescription()
        XCTAssertEqual(FileManager.default.fileExists(atPath: path), existed,
                       "describing the path must be free of side effects")
    }
}

final class HistoryResetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func names() throws -> Set<String> {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).reduce(into: Set<String>()) {
            $0.insert($1)
        }
    }

    /// Renames, never deletes: if the database turned out to be fine after all,
    /// the user renames the `.bak` back and keeps every row.
    func testMovesDatabaseAndSidecarsAsideWithoutDeleting() throws {
        let database = try write("iliad.db", "rows")
        try write("iliad.db-wal", "wal")
        try write("iliad.db-shm", "shm")
        let stamp = HistoryReset.timestampStamp(for: Date(timeIntervalSince1970: 0),
                                               timeZone: romeTimeZone)

        let moved = try HistoryReset.moveAside(at: database,
                                               now: Date(timeIntervalSince1970: 0),
                                               timeZone: romeTimeZone)

        XCTAssertEqual(moved.count, 3, "the sidecars move with the database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(try names(), [
            HistoryReset.backupName(for: database, stamp: stamp),
            "iliad.db-wal.\(stamp).bak",
            "iliad.db-shm.\(stamp).bak",
        ])
        // The data survived, verbatim.
        for url in moved {
            XCTAssertFalse(try String(contentsOf: url).isEmpty)
        }
    }

    /// Leaving a stale `-wal`/`-shm` next to the fresh database the app creates
    /// on the next launch would hand that new file an old write-ahead log.
    func testMovesOnlyTheSidecarsThatExist() throws {
        let database = try write("iliad.db", "rows")
        try write("iliad.db-wal", "wal")

        let moved = try HistoryReset.moveAside(at: database)

        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { $0.lastPathComponent.hasSuffix(".bak") })
    }

    /// A reset with nothing to move must not throw — the user may have already
    /// moved the file by hand.
    func testMissingDatabaseMovesNothing() throws {
        let database = directory.appendingPathComponent("iliad.db")
        XCTAssertFalse(HistoryReset.hasDatabase(at: database))

        let moved = try HistoryReset.moveAside(at: database)

        XCTAssertTrue(moved.isEmpty)
    }

    /// When the move genuinely fails — the containing directory made read-only
    /// after the file was written, so no destination can be created — the error
    /// propagates for `BootstrapState` to turn into a message. Swallowing it
    /// would leave the user on a dead-end screen with a button that silently does
    /// nothing.
    func testUnwritableDirectoryThrowsRatherThanReportingSuccess() throws {
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let insideLocked = locked.appendingPathComponent("iliad.db")
        try "rows".write(to: insideLocked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        XCTAssertThrowsError(try HistoryReset.moveAside(at: insideLocked),
                             "an impossible move must not be reported as a success")
        // Whatever went wrong, nothing was deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: insideLocked.path))
    }

    /// Two resets inside the same second must not have the second overwrite the
    /// first: losing a backup would defeat the point of the action.
    func testSameSecondCollisionDoesNotOverwriteAPreviousBackup() throws {
        let database = try write("iliad.db", "first")
        let now = Date(timeIntervalSince1970: 0)

        let first = try HistoryReset.moveAside(at: database, now: now, timeZone: romeTimeZone)
        try write("iliad.db", "second")
        let second = try HistoryReset.moveAside(at: database, now: now, timeZone: romeTimeZone)

        let firstName = try XCTUnwrap(first.first).lastPathComponent
        let secondName = try XCTUnwrap(second.first).lastPathComponent
        XCTAssertNotEqual(firstName, secondName)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: directory.appendingPathComponent(firstName).path)),
                       "first")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: directory.appendingPathComponent(secondName).path)),
                       "second")
    }

    func testBackupNameCarriesATimestamp() {
        let url = URL(fileURLWithPath: "/tmp/iliad.db")
        let stamp = HistoryReset.timestampStamp(for: Date(timeIntervalSince1970: 0),
                                               timeZone: romeTimeZone)
        // YYYYMMDD-HHMMSS, all digits and one separator.
        XCTAssertEqual(stamp.count, 15)
        XCTAssertNotNil(stamp.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression))
        XCTAssertEqual(HistoryReset.backupName(for: url, stamp: stamp), "iliad.db.\(stamp).bak")
        XCTAssertEqual(HistoryReset.backupName(for: url, stamp: stamp, attempt: 2),
                       "iliad.db.\(stamp)-2.bak")
    }

    func testHasDatabaseFindsTheFile() throws {
        let database = try write("iliad.db", "rows")
        XCTAssertTrue(HistoryReset.hasDatabase(at: database))
    }
}

@MainActor
final class BootstrapStateTests: XCTestCase {
    private func withTemporaryDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("iliad.db"))
    }

    func testReportsThePathAndOffersTheReset() throws {
        try withTemporaryDatabase { database in
            try "rows".write(to: database, atomically: true, encoding: .utf8)
            let state = BootstrapState(error: "database non leggibile", databasePath: database.path)

            XCTAssertEqual(state.error, "database non leggibile")
            XCTAssertEqual(state.databasePath, database.path)
            XCTAssertTrue(state.canResetHistory)
            XCTAssertNil(state.resetMessage)
        }
    }

    func testResetMovesTheFileAndExplainsTheRestart() throws {
        try withTemporaryDatabase { database in
            try "rows".write(to: database, atomically: true, encoding: .utf8)
            let state = BootstrapState(error: "boom", databasePath: database.path)

            state.resetHistory()

            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
            let message = try XCTUnwrap(state.resetMessage)
            XCTAssertTrue(message.contains(".bak"), message)
            XCTAssertTrue(message.contains("Esci e riapri"), "the app cannot rebuild while running: \(message)")
            // Not offered again: there is nothing left to move.
            XCTAssertFalse(state.canResetHistory)
        }
    }

    func testResetOnAnAbsentDatabaseSaysSoInsteadOfFailing() throws {
        try withTemporaryDatabase { database in
            let state = BootstrapState(error: "boom", databasePath: database.path)
            state.resetHistory()
            XCTAssertEqual(state.resetMessage, "Non c'era nessun database da spostare.")
        }
    }

    /// A recovery action is the worst possible place to throw: the user clicked a
/// button trying to get out of a dead end. Both outcomes — moved, or nothing to
/// move — have to produce a message, and neither may delete anything.
func testResetAlwaysExplainsWhatItDid() throws {
        try withTemporaryDatabase { database in
            try "rows".write(to: database, atomically: true, encoding: .utf8)

            let state = BootstrapState(error: "boom", databasePath: database.path)
            state.resetHistory()
            let first = try XCTUnwrap(state.resetMessage)
            XCTAssertTrue(first.contains(".bak"), first)
            XCTAssertTrue(first.contains("Esci e riapri"), first)

            // A second press, with the database already gone, must still say
            // something rather than throw or silently do nothing.
            state.resetHistory()
            let second = try XCTUnwrap(state.resetMessage)
            XCTAssertEqual(second, "Non c'era nessun database da spostare.")
        }
    }
}
