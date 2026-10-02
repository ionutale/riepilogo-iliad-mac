import GRDB
import XCTest
@testable import RiepilogoIliad

final class StoreTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).db").path
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 8) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testInsertLatestAndLastGood() throws {
        let store = try Store(path: tempPath())
        let data = AccountData(creditEUR: 4.32, usedGB: 1, remainingGB: 9, allowanceGB: 10,
                               renewalDate: dateOnly(y: 2026, m: 10, d: 17), periodStart: nil, periodEnd: nil,
                               phoneNumber: "3511112222", offerName: "GIGA 200")
        try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: date(2026, 10, 1)))
        try store.insert(Reading.failure(account: "SIM 1", error: "rete giù", fetchedAt: date(2026, 10, 1, hour: 9)))

        let latest = try store.latestPerAccount()
        XCTAssertEqual(latest["SIM 1"]?.ok, false)
        XCTAssertEqual(latest["SIM 1"]?.error, "rete giù")

        let good = try store.lastGoodPerAccount()
        XCTAssertEqual(good["SIM 1"]?.phone, "3511112222")
        XCTAssertEqual(good["SIM 1"]?.renewalDate?.date, dateOnly(y: 2026, m: 10, d: 17))
    }

    func testHistoryIsAscendingAndOKOnly() throws {
        let store = try Store(path: tempPath())
        for i in 0..<3 {
            let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: Double(9 - i), allowanceGB: 10,
                                   renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
            try store.insert(Reading.success(account: "A", data: data, fetchedAt: date(2026, 10, 1 + i)))
        }
        try store.insert(Reading.failure(account: "A", error: "x", fetchedAt: date(2026, 10, 5)))

        let history = try store.history(account: "A", since: date(2026, 10, 1))
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].remainingGB, 9)
        XCTAssertEqual(history[2].remainingGB, 7)
    }

    func testDeleteOlderThan() throws {
        let store = try Store(path: tempPath())
        try store.insert(Reading.failure(account: "A", error: "old", fetchedAt: date(2025, 1, 1)))
        try store.insert(Reading.failure(account: "A", error: "new", fetchedAt: date(2026, 10, 1)))
        let deleted = try store.deleteOlderThan(date(2026, 1, 1))
        XCTAssertEqual(deleted, 1)
    }

    /// Review Focus #4: a DB written with the Go app's raw schema must read back
    /// with correct date/timestamp parsing.
    func testReadsGoSchemaDatabase() throws {
        let path = tempPath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE readings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account TEXT NOT NULL, fetched_at TEXT NOT NULL, ok INTEGER NOT NULL,
                    error TEXT, phone TEXT, offer TEXT,
                    used_gb REAL, remaining_gb REAL, allowance_gb REAL, credit_eur REAL,
                    renewal_date TEXT, period_start TEXT, period_end TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO readings
                (account, fetched_at, ok, error, phone, offer, used_gb, remaining_gb, allowance_gb,
                 credit_eur, renewal_date, period_start, period_end)
                VALUES ('SIM 1', '2026-10-01T08:00:00Z', 1, NULL, '3330000000', 'GIGA 200',
                        2.29, 197.0, 200.0, 4.32, '2026-11-02', '2026-10-01', '2026-11-01')
                """)
        }
        let store = try Store(path: path) // migrator is idempotent
        let latest = try store.latestPerAccount()
        let reading = try XCTUnwrap(latest["SIM 1"])
        XCTAssertEqual(reading.remainingGB, 197)
        XCTAssertEqual(reading.renewalDate?.date, dateOnly(y: 2026, m: 11, d: 2))
        XCTAssertEqual(reading.periodStart?.date, dateOnly(y: 2026, m: 10, d: 1))
        XCTAssertEqual(reading.fetchedAt.date, date(2026, 10, 1))
    }

    /// Review Focus #4, schema half: the table this app creates must be the Go
    /// DDL column for column, otherwise the user's `iliad.db` is not importable.
    func testSchemaMatchesGoDDL() throws {
        let path = tempPath()
        _ = try Store(path: path)
        let queue = try DatabaseQueue(path: path)

        // "name type notnull pk", in declaration order.
        let columns = try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name || ' ' || type || ' ' || "notnull" || ' ' || pk
                FROM pragma_table_info('readings')
                """)
        }
        XCTAssertEqual(columns, [
            "id INTEGER 0 1",
            "account TEXT 1 0",
            "fetched_at TEXT 1 0",
            "ok INTEGER 1 0",
            "error TEXT 0 0",
            "phone TEXT 0 0",
            "offer TEXT 0 0",
            "used_gb REAL 0 0",
            "remaining_gb REAL 0 0",
            "allowance_gb REAL 0 0",
            "credit_eur REAL 0 0",
            "renewal_date TEXT 0 0",
            "period_start TEXT 0 0",
            "period_end TEXT 0 0",
        ])

        let indexes = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'readings' ORDER BY name")
        }
        XCTAssertEqual(indexes, ["idx_readings_account_fetched"])
    }

    /// The Go app must stay able to read rows this app writes, so the on-disk
    /// formats are asserted directly instead of only round-tripped through `Store`.
    func testInsertWritesGoFormats() throws {
        let path = tempPath()
        let store = try Store(path: path)
        let data = AccountData(creditEUR: 4.32, usedGB: 1, remainingGB: 9, allowanceGB: 10,
                               renewalDate: dateOnly(y: 2026, m: 10, d: 17), periodStart: nil, periodEnd: nil,
                               phoneNumber: "", offerName: "")
        try store.insert(Reading.success(account: "A", data: data, fetchedAt: date(2026, 10, 1)))
        try store.insert(Reading.failure(account: "A", error: "rete giù", fetchedAt: date(2026, 10, 1, hour: 9)))

        let queue = try DatabaseQueue(path: path)
        try queue.read { db in
            // RFC3339 UTC without fractional seconds, as Go's time.RFC3339 writes.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT fetched_at FROM readings"), "2026-10-01T08:00:00Z")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT renewal_date FROM readings"), "2026-10-17")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ok FROM readings"), 1)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT credit_eur FROM readings"), 4.32)
            // Go's nullString: absent values are NULL, never an empty string.
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT phone FROM readings"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT period_start FROM readings"))
            // `ok` stays 0/1 integer, so the Go app's `ok = 1` filter still works.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ok FROM readings WHERE error IS NOT NULL"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT error FROM readings WHERE error IS NOT NULL"), "rete giù")
        }
    }
}