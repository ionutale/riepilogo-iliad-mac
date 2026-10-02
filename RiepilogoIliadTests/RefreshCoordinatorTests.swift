import XCTest
@testable import RiepilogoIliad

// Fixture credentials live at file scope: the `@Sendable` fetcher closures read
// them without capturing the non-Sendable XCTestCase instance. They are
// distinctive enough that a redaction assertion cannot pass by accident, and
// unrelated to the Italian error strings these tests assert on.
private let fixtureUsername = "user@example.com"
private let fixturePassword = "correct-horse-battery"

private let page = #"<html><body><span class="red">2 GB / 200 GB</span><span class="big red">198</span><span class="small red">GB</span><p>Si rinnova il 17/10/2026.</p></body></html>"#

/// Same page after the data cycle renews: the allowance is available again.
private let pageAfterRenewal = #"<html><body><span class="red">2 GB / 200 GB</span><span class="big red">200</span><span class="small red">GB</span><p>Si rinnova il 17/10/2026.</p></body></html>"#

private struct BlockingFetcher: HTMLFetcher {
    let gate: AsyncStream<Void>?
    let result: @Sendable () throws -> String

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        if let gate {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return try result()
    }
}

/// Counts entries and records whether a second fetch was ever started while one
/// was already blocked inside the fetcher. The overlap flag is what proves the
/// "Verifica account" and refresh-cycle guard: a call count alone cannot tell
/// "one fetch" from "two sequential fetches", and what matters is that the two
/// paths never share a Safari tab.
private final class ConcurrencyProbe: HTMLFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = 0
    private var _inFlight = 0
    private var _overlapped = false
    let gate: AsyncStream<Void>
    let result: @Sendable () throws -> String

    init(gate: AsyncStream<Void>, result: @escaping @Sendable () throws -> String) {
        self.gate = gate
        self.result = result
    }

    var entered: Int { lock.withLock { _entered } }
    var overlapped: Bool { lock.withLock { _overlapped } }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        lock.withLock {
            _entered += 1
            _inFlight += 1
            if _inFlight > 1 { _overlapped = true }
        }
        defer { lock.withLock { _inFlight -= 1 } }
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return try result()
    }
}

/// Records every `decide` input and every posted decision, so a regression that
/// stops consulting the notifier — or hands it a backwards `previous` — fails.
/// The account list a test hands to the coordinator, changed mid-test to stand
/// in for the user adding or removing a SIM in Settings. `Box` rather than a
/// local `var`: the `accounts` closure is `@Sendable`, so it cannot capture
/// mutable state.
private final class MutableAccounts: @unchecked Sendable {
    private let box: Box<[Account]>

    init(_ value: [Account]) { box = Box(value) }

    var value: [Account] {
        get { box.value }
        set { box.value = newValue }
    }
}

private final class FakeNotifier: NotificationDeciding, @unchecked Sendable {
    struct DecideCall: Sendable {
        var accountID: UUID
        var previous: AccountData?
        var current: AccountData
    }

    private let lock = NSLock()
    private var _decideCalls: [DecideCall] = []
    private var _posted: [NotificationDecision] = []
    private let returned: NotificationDecision

    init(returning decision: NotificationDecision = .low) { returned = decision }

    var decideCalls: [DecideCall] {
        lock.withLock { _decideCalls }
    }

    var posted: [NotificationDecision] {
        lock.withLock { _posted }
    }

    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision {
        lock.withLock {
            _decideCalls.append(DecideCall(accountID: account.id, previous: previous, current: current))
        }
        return returned
    }

    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {
        // `withLock`, not lock/unlock: raw `NSLock.lock()` is unavailable from
        // an async context.
        lock.withLock { _posted.append(decision) }
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        store: Store,
        account: Account = Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil),
        accounts: [Account]? = nil,
        direct: any HTMLFetcher,
        safari: any HTMLFetcher = HTTPFetcher(baseURL: URL(string: "https://never.test")!),
        mode: FetchMode = .auto,
        notifier: any NotificationDeciding = FakeNotifier()
    ) throws -> RefreshCoordinator {
        let list = accounts ?? [account]
        let credentials = InMemoryCredentialStore()
        for entry in list {
            try credentials.setPassword(fixturePassword, for: entry.id)
        }
        return try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: direct, safari: safari, mode: mode),
            credentials: credentials,
            accounts: { list },
            notifier: notifier,
            retentionDays: 180)
    }

    private func makeStore() throws -> Store {
        try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
    }

    func testRefreshPersistsAndCaches() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { page })
        let ran = await coordinator.refreshOnce()
        XCTAssertTrue(ran)
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, true)
    }

    func testFailureKeepsLastGood() async throws {
        let store = try makeStore()
        let shouldFail = Box(false)
        let notifier = FakeNotifier()
        let direct = StubFetcher {
            if shouldFail.value { throw IliadError.auth("credenziali non valide") }
            return page
        }
        let coordinator = try makeCoordinator(store: store, direct: direct, notifier: notifier)
        _ = await coordinator.refreshOnce()
        shouldFail.value = true
        _ = await coordinator.refreshOnce()
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertEqual(entry.lastError, "credenziali non valide")
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, false)
        // Only the successful refresh is worth a notification decision.
        XCTAssertEqual(notifier.decideCalls.count, 1)
        XCTAssertEqual(notifier.posted, [.low])
    }

    func testSingleFlight() async throws {
        let store = try makeStore()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let coordinator = try makeCoordinator(store: store, direct: BlockingFetcher(gate: stream) { page })
        async let first = coordinator.refreshOnce()
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await coordinator.refreshOnce()
        XCTAssertFalse(second)
        continuation.finish()
        // Hoisted: an `async let` cannot be touched from an XCTest autoclosure.
        let firstRan = await first
        XCTAssertTrue(firstRan)
    }

    func testHydratesFromStore() async throws {
        let store = try makeStore()
        let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: 7, allowanceGB: 10,
                               renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
        try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: Date()))
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { page })
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 7)
    }

    func testHydratesFromStoreAndSeedsBareEntriesForUnfetchedAccounts() async throws {
        let store = try makeStore()
        let fetched = Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil)
        let neverFetched = Account(name: "SIM 9", username: fixtureUsername, renewalDay: nil)
        let coordinator = try makeCoordinator(store: store, accounts: [fetched, neverFetched],
                                              direct: StubFetcher { page })
        let snapshot = await coordinator.snapshot()
        // Hydration must not require a fetch: every configured SIM gets an entry
        // so a card renders at launch, before the first cycle completes.
        XCTAssertEqual(Set(snapshot.entries.keys), ["SIM 1", "SIM 9"])
        XCTAssertNil(snapshot.entries["SIM 9"]?.lastGood)
        XCTAssertNil(snapshot.entries["SIM 9"]?.lastError)
    }

    func testCheckAccountsReportsPath() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(
            store: store,
            direct: StubFetcher { throw IliadError.network("redirect loop") },
            safari: StubFetcher { page })
        let results = await coordinator.checkAccounts()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].ok)
        XCTAssertEqual(results[0].path, .safari)
    }

    /// The decider's `.renewed` heuristic needs the *previous* reading, so the
    /// coordinator has to hand it last cycle's data, not nil and not the current
    /// one. A backwards `previous` would silently kill that feature.
    func testNotifierReceivesPreviousAndCurrent() async throws {
        let store = try makeStore()
        let account = Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil)
        let notifier = FakeNotifier(returning: .low)
        let call = Box(0)
        let direct = StubFetcher {
            call.value += 1
            return call.value == 1 ? page : pageAfterRenewal
        }
        let coordinator = try makeCoordinator(store: store, account: account,
                                               direct: direct, notifier: notifier)

        _ = await coordinator.refreshOnce()
        _ = await coordinator.refreshOnce()

        let calls = notifier.decideCalls
        XCTAssertEqual(calls.count, 2) // exactly once per successful refresh
        let first = try XCTUnwrap(calls.first)
        XCTAssertEqual(first.accountID, account.id)
        XCTAssertNil(first.previous) // nothing to diff against on the first cycle
        XCTAssertEqual(first.current.remainingGB, 198)

        let second = try XCTUnwrap(calls.last)
        XCTAssertEqual(second.accountID, account.id)
        XCTAssertEqual(second.previous?.remainingGB, 198) // from the first refresh
        XCTAssertEqual(second.previous?.allowanceGB, 200)
        XCTAssertEqual(second.current.remainingGB, 200) // from the second page
        XCTAssertEqual(second.current.allowanceGB, 200)

        // The decision the fake made is the decision that gets posted: if the
        // coordinator posted `.none` on its own, this fails.
        XCTAssertEqual(notifier.posted, [.low, .low])
    }

    /// `SafariFetcher` can surface raw `osascript` stderr, and the password
    /// travels in that process's argv. Whatever we persist must not.
    func testFailureRowRedactsPasswordFromPersistedError() async throws {
        let store = try makeStore()
        let noise = String(repeating: "n", count: 400)
        let leak = "osascript: utente \(fixtureUsername) password \(fixturePassword)\n\(noise)"
        let coordinator = try makeCoordinator(
            store: store,
            direct: StubFetcher { throw IliadError.network(leak) },
            mode: .direct)

        _ = await coordinator.refreshOnce()

        let latest = try store.latestPerAccount()
        let row = try XCTUnwrap(latest["SIM 1"])
        XCTAssertEqual(row.ok, false)
        let stored = try XCTUnwrap(row.error)
        XCTAssertTrue(stored.contains("***"))
        XCTAssertFalse(stored.contains(fixturePassword))
        XCTAssertFalse(stored.contains(fixtureUsername))
        XCTAssertFalse(stored.contains("\n"))
        XCTAssertTrue(stored.hasSuffix("…"))
        XCTAssertEqual(stored.count, 301) // 300 characters plus the marker

        // The in-memory error is the same scrubbed string: nothing unsanitised
        // escapes to the UI either.
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastError, stored)
    }

    func testCheckAccountsRedactsCredentialsInError() async throws {
        let store = try makeStore()
        let leak = "login fallita per \(fixtureUsername) con \(fixturePassword)"
        let coordinator = try makeCoordinator(
            store: store,
            direct: StubFetcher { throw IliadError.network(leak) },
            mode: .direct)

        let results = await coordinator.checkAccounts()

        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "login fallita per *** con ***")
    }

    // MARK: - Reconciliation with the account list

    /// The snapshot is what the popover renders and `computeTotals` sums. A SIM
    /// that is no longer configured used to keep its card and keep counting
    /// toward the menu-bar total at its frozen quota — forever, because nothing
    /// ever removed an entry.
    func testDeletedAccountLeavesTheSnapshot() async throws {
        let store = try makeStore()
        let kept = Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil)
        let doomed = Account(name: "SIM 2", username: fixtureUsername, renewalDay: nil)
        let live = MutableAccounts([kept, doomed])
        let credentials = InMemoryCredentialStore()
        for account in live.value { try credentials.setPassword(fixturePassword, for: account.id) }
        let coordinator = try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: StubFetcher { page }, safari: StubFetcher { page }, mode: .direct),
            credentials: credentials,
            accounts: { live.value },
            notifier: FakeNotifier())

        _ = await coordinator.refreshOnce()
        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(Set(snapshot.entries.keys), ["SIM 1", "SIM 2"])

        live.value = [kept]
        await coordinator.reconcile()

        snapshot = await coordinator.snapshot()
        XCTAssertEqual(Set(snapshot.entries.keys), ["SIM 1"],
                       "a removed SIM must not keep its card or its totals")
    }

    /// The literal first-run flow: adding a SIM used to produce no card at all
    /// until the next cycle — up to 4 hours — while the popover claimed there
    /// was no account configured. A bare entry is what makes it render at once,
    /// with "no data yet" rather than a false empty state.
    func testNewlyAddedAccountAppearsImmediately() async throws {
        let store = try makeStore()
        let live = MutableAccounts([])
        let coordinator = try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: StubFetcher { page }, safari: StubFetcher { page }, mode: .direct),
            credentials: InMemoryCredentialStore(),
            accounts: { live.value },
            notifier: FakeNotifier())

        var snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)

        live.value = [Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil)]
        await coordinator.reconcile()

        snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertNil(entry.lastGood, "no reading yet — the card says so rather than inventing data")
        XCTAssertNil(entry.lastError)
    }

    /// Reconciling runs at the top of every cycle, so a SIM removed while the app
    /// was closed still disappears without waiting for the timer.
    func testRefreshOnceReconcilesBeforeFetching() async throws {
        let store = try makeStore()
        let live = MutableAccounts([
            Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil),
            Account(name: "SIM 2", username: fixtureUsername, renewalDay: nil),
        ])
        let fetched = Box<[String]>([])
        let credentials = InMemoryCredentialStore()
        for account in live.value { try credentials.setPassword(fixturePassword, for: account.id) }
        let coordinator = try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(
                direct: StubFetcher { fetched.value.append("fetched"); return page },
                safari: StubFetcher { page },
                mode: .direct),
            credentials: credentials,
            accounts: { live.value },
            notifier: FakeNotifier())

        // SIM 2 is removed while the app is closed.
        live.value = [live.value[0]]
        _ = await coordinator.refreshOnce()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(Set(snapshot.entries.keys), ["SIM 1"],
                       "the removed SIM must not survive the cycle that follows the removal")
        XCTAssertEqual(fetched.value, ["fetched"], "and it must not have been fetched")
    }

    /// `entries` is keyed by name, so a rename is a delete plus an add. The old
    /// card must not survive as a frozen quota counted in the totals.
    func testRenamedAccountDropsTheOldEntry() async throws {
        let store = try makeStore()
        let original = Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil)
        let live = MutableAccounts([original])
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword(fixturePassword, for: original.id)
        let coordinator = try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: StubFetcher { page }, safari: StubFetcher { page }, mode: .direct),
            credentials: credentials,
            accounts: { live.value },
            notifier: FakeNotifier())

        _ = await coordinator.refreshOnce()
        live.value = [Account(id: original.id, name: "SIM 3", username: fixtureUsername, renewalDay: nil)]
        await coordinator.reconcile()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(Set(snapshot.entries.keys), ["SIM 3"])
    }

    // MARK: - Check/cycle mutual exclusion

    /// "Verifica account" and a refresh cycle both drive the *same* Safari tab on
    /// the fallback path, and the check's first step is
    /// `GET /account/?logout=user`. Running them together logs the in-flight
    /// cycle out of its session, which the cycle then reports as `.auth` — a
    /// false "credenziali non valide" persisted as a failure row, with no Safari
    /// fallback because auth errors never fall back.
    func testCheckAccountsDoesNotRaceARefresh() async throws {
        let store = try makeStore()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let probe = ConcurrencyProbe(gate: stream) { page }
        let coordinator = try makeCoordinator(store: store, direct: probe)

        async let cycle = coordinator.refreshOnce()
        // The probe is inside the fetcher only once it has been entered, so wait
        // for that rather than for a fixed delay.
        for _ in 0..<200 where probe.entered == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(probe.entered, 1, "the cycle must be in flight")

        let results = await coordinator.checkAccounts()

        XCTAssertEqual(probe.entered, 1, "the check must not have invoked the fetcher")
        XCTAssertFalse(probe.overlapped, "the two paths must never fetch concurrently")
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, RefreshCoordinator.busyMessage)
        XCTAssertNil(result.path, "no fetch ran, so no transport was used")

        continuation.finish()
        let ran = await cycle
        XCTAssertTrue(ran)
        // And the cycle itself completed normally — the check did not poison it.
        let snapshot = await coordinator.snapshot()
        XCTAssertNil(snapshot.entries["SIM 1"]?.lastError)
    }

    /// The guard is symmetric: a check in flight must keep a cycle from starting
    /// rather than interleaving with it.
    func testRefreshDoesNotStartWhileACheckRuns() async throws {
        let store = try makeStore()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let probe = ConcurrencyProbe(gate: stream) { page }
        let coordinator = try makeCoordinator(store: store, direct: probe)

        async let check = coordinator.checkAccounts()
        for _ in 0..<200 where probe.entered == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(probe.entered, 1, "the check must be in flight")

        let ran = await coordinator.refreshOnce()
        XCTAssertFalse(ran, "single-flight must cover the check path too")
        XCTAssertFalse(probe.overlapped, "the two paths must never fetch concurrently")

        continuation.finish()
        let results = await check
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(try XCTUnwrap(results.first).ok)
    }

    /// One deterministic result per configured account, so a SIM is never missing
    /// from the table just because another one held the gate.
    func testBusyCheckStillListsEveryAccount() async throws {
        let store = try makeStore()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let accounts = [
            Account(name: "SIM 1", username: fixtureUsername, renewalDay: nil),
            Account(name: "SIM 2", username: fixtureUsername, renewalDay: nil),
        ]
        let coordinator = try makeCoordinator(
            store: store, accounts: accounts,
            direct: BlockingFetcher(gate: stream) { page })

        async let cycle = coordinator.refreshOnce()
        try await Task.sleep(nanoseconds: 50_000_000)

        let results = await coordinator.checkAccounts()
        XCTAssertEqual(results.map(\.account), ["SIM 1", "SIM 2"])
        XCTAssertTrue(results.allSatisfy { $0.error == RefreshCoordinator.busyMessage })

        continuation.finish()
        _ = await cycle
    }
}