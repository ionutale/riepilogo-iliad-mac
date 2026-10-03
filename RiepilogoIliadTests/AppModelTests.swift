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

    // MARK: - Per-card badges (spec §8)

    private func now(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    private func readEntry(failed: Bool, goodAge: TimeInterval, error: String = "ko") -> Entry {
        var entry = Entry(account: "SIM 1")
        let data = AccountData(creditEUR: nil, usedGB: 2, remainingGB: 198, allowanceGB: 200,
                               renewalDate: nil, periodStart: nil, periodEnd: nil,
                               phoneNumber: "", offerName: "")
        entry.lastGood = Reading.success(account: "SIM 1", data: data,
                                         fetchedAt: now(-goodAge))
        entry.lastAttempt = now(-60)
        if failed { entry.lastError = error }
        return entry
    }

    /// No error and a recent success: no badge at all. This is the common case
    /// and a permanent badge here would be noise.
    func testNoBadgeForHealthyEntry() {
        let entry = readEntry(failed: false, goodAge: 3600)
        XCTAssertNil(entryBadge(for: entry, now: now(), interval: 4 * 3600))
    }

    /// The red badge carries the error so the card can say what failed, and the
    /// last-good values stay visible underneath.
    func testErrorBadgeTakesPrecedence() {
        let entry = readEntry(failed: true, goodAge: 3600, error: "credenziali non valide")
        XCTAssertEqual(entryBadge(for: entry, now: now(), interval: 4 * 3600),
                       .error("credenziali non valide"))
    }

    /// "Dati non aggiornati" covers the other way a card can mislead: the newest
    /// *successful* reading has aged past two intervals, so the numbers may be
    /// wrong even though nothing failed. Spec §5 sets the same 2× bar for the
    /// post-wake refresh.
    func testStaleBadgeAfterTwoIntervals() {
        let interval: TimeInterval = 3600
        XCTAssertNil(entryBadge(for: readEntry(failed: false, goodAge: 2 * interval),
                                now: now(), interval: interval), "exactly 2x is not yet stale")
        XCTAssertEqual(entryBadge(for: readEntry(failed: false, goodAge: 2 * interval + 1),
                                  now: now(), interval: interval), .stale)
    }

    /// A card with no reading at all has nothing to be stale *about* — the body
    /// already says it has no data.
    func testNoBadgeWithoutAnyReading() {
        XCTAssertNil(entryBadge(for: Entry(account: "SIM 1"), now: now(), interval: 3600))
    }

    /// An error and staleness can both hold; the error wins because it is the
    /// specific, actionable one.
    func testErrorWinsOverStale() {
        let entry = readEntry(failed: true, goodAge: 100 * 3600, error: "timeout")
        XCTAssertEqual(entryBadge(for: entry, now: now(), interval: 3600), .error("timeout"))
    }

    // MARK: - Post-wake staleness (spec §5)

    /// No completed cycle at all — the start-up cycle has not published a
    /// snapshot yet — is stale by definition: there is nothing on screen to
    /// defend.
    func testWakeRefreshesWithoutAnyCompletedCycle() {
        XCTAssertTrue(AppModel.shouldRefreshAfterWake(lastCycle: nil, now: now(), interval: 3600),
                      "no cycle yet means the figures on screen are whatever launch left behind")
    }

    /// The case the wake hook exists for: a Mac that slept through the interval
    /// resumes the timer's sleep rather than firing it, so without this a laptop
    /// shows pre-sleep numbers all night.
    func testWakeRefreshesWhenTheLastCycleIsOlderThanTwoIntervals() {
        let interval: TimeInterval = 3600
        XCTAssertTrue(AppModel.shouldRefreshAfterWake(
            lastCycle: now(-(2 * interval + 1)), now: now(), interval: interval))
    }

    /// Inside the bar the timer is still ahead of the data, and a second cycle
    /// would only fight the scheduled one for the Safari tab.
    func testWakeDoesNotRefreshWithinTwoIntervals() {
        let interval: TimeInterval = 3600
        XCTAssertFalse(AppModel.shouldRefreshAfterWake(
            lastCycle: now(-(2 * interval - 1)), now: now(), interval: interval))
    }

    /// Exactly 2× is not stale — the same strict `>` the badge uses, so a card
    /// never says "dati non aggiornati" while a wake is being skipped as fresh.
    func testWakeDoesNotRefreshAtExactlyTwoIntervals() {
        let interval: TimeInterval = 3600
        XCTAssertFalse(AppModel.shouldRefreshAfterWake(
            lastCycle: now(-2 * interval), now: now(), interval: interval))
    }

    /// The bar scales with the configured interval: the same 3h-old cycle is fresh
    /// at the 24h setting and stale at 1h. Nothing here is pinned to the 4h default.
    func testWakeBarFollowsTheConfiguredInterval() {
        let threeHours: TimeInterval = 3 * 3600
        XCTAssertFalse(AppModel.shouldRefreshAfterWake(
            lastCycle: now(-threeHours), now: now(), interval: 24 * 3600))
        XCTAssertTrue(AppModel.shouldRefreshAfterWake(
            lastCycle: now(-threeHours), now: now(), interval: 3600))
    }
}
