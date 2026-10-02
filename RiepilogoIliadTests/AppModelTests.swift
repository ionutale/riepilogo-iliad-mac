import XCTest
@testable import RiepilogoIliad

final class AppModelTests: XCTestCase {
    private func entry(name: String, remaining: Double?, allowance: Double?, renewal: Date?) -> Entry {
        let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: allowance,
                               renewalDate: renewal, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
        var entry = Entry(account: name)
        entry.lastGood = Reading.success(account: name, data: data, fetchedAt: Date())
        return entry
    }

    func testTotalsExcludeMissingAndComputeNextRenewal() {
        let entries = [
            entry(name: "A", remaining: 57.5, allowance: 100, renewal: dateOnly(y: 2026, m: 10, d: 17)),
            entry(name: "B", remaining: 5, allowance: 5, renewal: dateOnly(y: 2026, m: 10, d: 7)),
            Entry(account: "C"),
        ]
        let totals = computeTotals(entries: entries)
        XCTAssertEqual(totals.remainingGB, 62.5)
        XCTAssertEqual(totals.allowanceGB, 105)
        XCTAssertEqual(totals.excluded, 1)
        XCTAssertEqual(totals.nextName, "B")
        XCTAssertTrue(totals.hasData)
    }

    func testSortByDaysToRenewal() {
        let today = dateOnly(y: 2026, m: 10, d: 2)
        let entries = [
            entry(name: "later", remaining: 1, allowance: 10, renewal: dateOnly(y: 2026, m: 10, d: 30)),
            entry(name: "sooner", remaining: 1, allowance: 10, renewal: dateOnly(y: 2026, m: 10, d: 7)),
            Entry(account: "no-renewal"),
        ]
        let sorted = sortEntries(entries, today: today)
        XCTAssertEqual(sorted.map(\.account), ["sooner", "later", "no-renewal"])
    }

    func testEmptyTotals() {
        let totals = computeTotals(entries: [])
        XCTAssertFalse(totals.hasData)
        XCTAssertEqual(totals.excluded, 0)
    }
}
