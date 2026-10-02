import XCTest
@testable import RiepilogoIliad

final class ImportTests: XCTestCase {
    func testImportAccountsFromYAML() throws {
        let yaml = """
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
        let imported = try importAccounts(fromYAML: yaml)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].name, "SIM 1")
        XCTAssertEqual(imported[0].username, "user1")
        XCTAssertEqual(imported[0].password, "pass1")
        XCTAssertEqual(imported[0].renewalDay, 17)
        XCTAssertNil(imported[1].renewalDay)
    }

    func testImportDatabaseCopiesSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("iliad.db")
        try Data("db".utf8).write(to: source)
        try Data("wal".utf8).write(to: dir.appendingPathComponent("iliad.db-wal"))
        let destination = dir.appendingPathComponent("dest/iliad.db")

        try importDatabase(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("db".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-wal")), Data("wal".utf8))
    }
}