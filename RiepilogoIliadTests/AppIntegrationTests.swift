import XCTest
@testable import RiepilogoIliad

/// A consumi page with enough structure for the parser to extract a quota, so a
/// card renders real numbers rather than "nessun dato".
private let consumiPage = #"""
<html><body>
  <span class="red">2 GB / 200 GB</span>
  <span class="big red">198</span><span class="small red">GB</span>
  <p>Si rinnova il 17/10/2026.</p>
</body></html>
"""#

/// Blocks inside `fetchHTML` until the test releases it, which is what makes
/// "a cycle is in flight" an observable state rather than a race to win.
private final class GatedFetcher: HTMLFetcher, @unchecked Sendable {
    let gate: AsyncStream<Void>
    let result: @Sendable () throws -> String
    /// Set as soon as the fetcher is entered, so a test can wait for the exact
    /// moment the cycle is provably mid-flight.
    let onEnter: @Sendable () -> Void
    private let lock = NSLock()
    private var _calls = 0

    init(gate: AsyncStream<Void>,
         result: @escaping @Sendable () throws -> String,
         onEnter: @escaping @Sendable () -> Void = {}) {
        self.gate = gate
        self.result = result
        self.onEnter = onEnter
    }

    var calls: Int { lock.withLock { _calls } }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        lock.withLock { _calls += 1 }
        onEnter()
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return try result()
    }
}

private final class SilentNotifier: NotificationDeciding, @unchecked Sendable {
    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision {
        .none
    }
    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {}
}

/// `AppModel` was never constructed in any test before this file, so its entire
/// surface — `start`, `reload`, `refreshNow`, `accountsChanged`, the empty
/// state — was unverified. These exercise it against a real coordinator, a real
/// temporary store and stub fetchers, i.e. the seams the UI actually goes
/// through.
@MainActor
final class AppIntegrationTests: XCTestCase {
    private var store: Store!
    private var storePath: String!
    private var settings: AppSettings!
    private var suiteName: String!
    private var model: AppModel?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "integration-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-\(UUID().uuidString).db").path
        store = try Store(path: storePath)
    }

    override func tearDown() async throws {
        // Leave no pending sleep behind: the model's timer task would outlive the
        // test and keep the coordinator alive.
        model?.cancelTimer()
        model = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        if let storePath { try? FileManager.default.removeItem(atPath: storePath) }
        try await super.tearDown()
    }

    private func makeModel(_ direct: any HTMLFetcher, accounts: [Account],
                           safari: any HTMLFetcher = StubFetcher { consumiPage }) throws -> AppModel {
        settings.accounts = accounts
        let runtime = settings.runtime
        let credentials = InMemoryCredentialStore()
        for account in accounts {
            try credentials.setPassword("password-\(account.name)", for: account.id)
        }
        let coordinator = try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: direct, safari: safari, modeProvider: { runtime.fetchMode }),
            credentials: credentials,
            accounts: { runtime.accounts },
            notifier: SilentNotifier())
        let model = AppModel(settings: settings, coordinator: coordinator)
        self.model = model
        return model
    }

    private func account(_ name: String) -> Account {
        Account(name: name, username: "user@example.com", renewalDay: nil)
    }

    /// The first-run flow, end to end: a SIM added in Settings must have a card in
    /// the popover now — previously there was none until the next cycle, up to 4h
    /// away, and the popover claimed no account was configured.
    func testAddingAnAccountProducesACardImmediately() async throws {
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [])
        await model.reload()
        XCTAssertTrue(model.hasNoAccounts, "with no SIM configured the empty state is honest")

        let added = account("SIM 1")
        settings.accounts = [added]
        await model.accountsChanged()

        XCTAssertEqual(model.cards.map(\.account), ["SIM 1"])
        XCTAssertFalse(model.hasNoAccounts,
                       "a configured SIM with no reading yet must not read as 'no accounts'")
        XCTAssertNil(model.cards.first?.lastGood)
        // Totals exclude a card with no data rather than reporting zero.
        XCTAssertEqual(model.totals.excluded, 1)
        XCTAssertFalse(model.totals.hasData)
    }

    /// The inverse: a removed SIM must stop rendering *and* stop contributing to
    /// the totals, instead of sitting on screen at its frozen quota and in the
    /// menu bar until relaunch.
    func testRemovingAnAccountRemovesItsCardAndItsTotals() async throws {
        let kept = account("SIM 1")
        let doomed = account("SIM 2")
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [kept, doomed])
        await model.runRefreshCycle()

        XCTAssertEqual(model.cards.count, 2)
        XCTAssertEqual(model.totals.allowanceGB, 400)
        XCTAssertEqual(model.totals.remainingGB, 396)

        settings.accounts = [kept]
        await model.accountsChanged()

        XCTAssertEqual(model.cards.map(\.account), ["SIM 1"])
        XCTAssertEqual(model.totals.allowanceGB, 200, "the removed SIM must leave the totals")
        XCTAssertEqual(model.totals.remainingGB, 198)
    }

    func testZeroAccountsShowsTheEmptyState() async throws {
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [])
        await model.accountsChanged()
        XCTAssertTrue(model.hasNoAccounts)
        XCTAssertTrue(model.cards.isEmpty)
    }

    /// `Snapshot.refreshing` could never be observed (the snapshot is only
    /// re-read before and after a cycle), so "Aggiorna ora" was clickable while
    /// five fetches ran for minutes with no feedback. `isRefreshing` brackets the
    /// whole cycle.
    func testIsRefreshingIsTrueForTheWholeCycle() async throws {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let entered = Box(false)
        let fetcher = GatedFetcher(gate: gate, result: { consumiPage },
                               onEnter: { entered.value = true })
        let model = try makeModel(fetcher, accounts: [account("SIM 1")])

        let cycle = Task { await model.runRefreshCycle() }
        // Wait for the fetcher to be entered, i.e. the cycle is provably running.
        for _ in 0..<200 where !entered.value {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(entered.value, "the cycle never started")
        XCTAssertTrue(model.isRefreshing, "the UI must be able to see a cycle in flight")

        continuation.finish()
        await cycle.value

        XCTAssertFalse(model.isRefreshing)
        XCTAssertNotNil(model.cards.first?.lastGood)
        XCTAssertNotNil(model.snapshot.lastCycle, "the footer needs the cycle timestamp")
    }

    /// The interval is read once per loop iteration and then slept on, so
    /// switching from 24h to 1h used to leave the old cadence in place for up to
    /// a day. Rescheduling must cancel the pending sleep and install a new one.
    func testRescheduleTimerReplacesThePendingSleep() async throws {
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [account("SIM 1")])
        model.start()

        let first = try XCTUnwrap(model.timerTask)
        XCTAssertFalse(first.isCancelled)

        model.rescheduleTimer()
        let second = try XCTUnwrap(model.timerTask)
        XCTAssertNotEqual(first, second, "a new loop task must be installed")
        XCTAssertTrue(first.isCancelled, "the old pending sleep must be cancelled")
        XCTAssertFalse(second.isCancelled)

        // A second reschedule (the interval picker fires on every change) must
        // not leave a dangling cancelled task behind.
        model.rescheduleTimer()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(try XCTUnwrap(model.timerTask).isCancelled)
    }

    /// Spec §8 asks for a 7-day sparkline per card. The points come off the main
    /// actor and are collapsed to one per local day, same as the History window.
    func testSparklinesArePopulatedFromSeededReadings() async throws {
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [account("SIM 1")])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = romeTimeZone
        let today = today(in: romeTimeZone)

        // Eight days of readings: only the last seven may be plotted.
        for dayOffset in 0..<8 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let data = AccountData(creditEUR: nil, usedGB: Double(dayOffset),
                                   remainingGB: Double(200 - dayOffset), allowanceGB: 200,
                                   renewalDate: nil, periodStart: nil, periodEnd: nil,
                                   phoneNumber: "", offerName: "")
            try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: day))
        }

        await model.reload()

        let points = try XCTUnwrap(model.sparklines["SIM 1"])
        XCTAssertEqual(points.count, AppModel.sparklineDays)
        XCTAssertEqual(points.map(\.remainingGB), [194, 195, 196, 197, 198, 199, 200],
                       "oldest first, the last seven days")
    }

    func testSparklinesAreEmptyForAnAccountWithoutHistory() async throws {
        let model = try makeModel(StubFetcher { consumiPage }, accounts: [account("SIM 1")])
        await model.reload()
        // Key absent or empty — either way the card renders no chart.
        XCTAssertTrue((model.sparklines["SIM 1"] ?? []).isEmpty)
    }

    /// A failed refresh keeps the last good numbers on the card and marks them
    /// with the red badge — the two together are what stop a stale quota being
    /// read as a current one.
    func testFailedCycleKeepsLastGoodAndBadgesTheCard() async throws {
        let shouldFail = Box(false)
        let failing = StubFetcher { throw IliadError.network("portale irraggiungibile") }
        let direct = StubFetcher {
            if shouldFail.value { throw IliadError.network("portale irraggiungibile") }
            return consumiPage
        }
        // Both transports fail: in `.auto` a network error falls back to Safari,
        // so failing only the direct one would leave the cycle successful.
        let model = try makeModel(direct, accounts: [account("SIM 1")], safari: failing)

        await model.runRefreshCycle()
        XCTAssertEqual(model.cards.first?.lastGood?.remainingGB, 198)
        XCTAssertNil(model.badge(for: try XCTUnwrap(model.cards.first)))

        shouldFail.value = true
        await model.runRefreshCycle()

        let entry = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(entry.lastGood?.remainingGB, 198, "last-good values stay visible")
        XCTAssertEqual(model.badge(for: entry), .error("portale irraggiungibile"))
        XCTAssertEqual(model.totals.remainingGB, 198, "and they still count")
    }

    /// The warning icon in the menu bar keys off low *remaining*, so the menu-bar
    /// total must stay put when a refresh fails.
    func testWarningAndTotalsSurviveAFailedCycle() async throws {
        let shouldFail = Box(false)
        let failing = StubFetcher { throw IliadError.network("ko") }
        let direct = StubFetcher {
            if shouldFail.value { throw IliadError.network("ko") }
            return consumiPage
        }
        let model = try makeModel(direct, accounts: [account("SIM 1")], safari: failing)
        await model.runRefreshCycle()
        XCTAssertFalse(model.hasWarning)

        shouldFail.value = true
        await model.runRefreshCycle()
        XCTAssertFalse(model.hasWarning, "198 GB remaining is not a warning")
        XCTAssertEqual(model.totals.hasData, true)
    }
}
