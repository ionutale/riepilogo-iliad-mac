import Foundation
import GRDB

/// SQLite persistence with the exact schema of the Go app, so history
/// migrates without conversion.
final class Store: Sendable {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("RiepilogoIliad", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iliad.db")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // `.real`, not `.double`: the Go DDL says REAL and a fresh database here
        // must look the same as one the Go app created.
        migrator.registerMigration("v1") { db in
            try db.create(table: "readings", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("fetched_at", .text).notNull()
                t.column("ok", .integer).notNull()
                t.column("error", .text)
                t.column("phone", .text)
                t.column("offer", .text)
                t.column("used_gb", .real)
                t.column("remaining_gb", .real)
                t.column("allowance_gb", .real)
                t.column("credit_eur", .real)
                t.column("renewal_date", .text)
                t.column("period_start", .text)
                t.column("period_end", .text)
            }
            try db.create(index: "idx_readings_account_fetched", on: "readings",
                          columns: ["account", "fetched_at"], ifNotExists: true)
        }
        return migrator
    }

    func insert(_ reading: Reading) throws {
        var record = reading
        try dbQueue.write { db in try record.insert(db) }
    }

    func latestPerAccount() throws -> [String: Reading] {
        let sql = """
        SELECT * FROM readings r
        WHERE r.id = (SELECT MAX(id) FROM readings WHERE account = r.account)
        """
        return try dbQueue.read { db in
            let rows = try Reading.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.account, $0) })
        }
    }

    func lastGoodPerAccount() throws -> [String: Reading] {
        let sql = """
        SELECT * FROM readings r
        WHERE r.id = (SELECT MAX(id) FROM readings WHERE account = r.account AND ok = 1)
        """
        return try dbQueue.read { db in
            let rows = try Reading.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.account, $0) })
        }
    }

    func history(account: String, since: Date) throws -> [Reading] {
        try dbQueue.read { db in
            try Reading
                .filter(Column("account") == account && Column("ok") == true &&
                        Column("fetched_at") >= Timestamp(date: since).databaseValue)
                .order(Column("fetched_at").asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func deleteOlderThan(_ date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM readings WHERE fetched_at < ?",
                           arguments: [Timestamp(date: date)])
            return db.changesCount
        }
    }
}