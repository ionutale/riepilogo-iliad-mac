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

/// Records every `decide` input and every posted decision, so a regression that
/// stops consulting the notifier — or hands it a backwards `previous` — fails.
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
        direct: any HTMLFetcher,
        safari: any HTMLFetcher = HTTPFetcher(baseURL: URL(string: "https://never.test")!),
        mode: FetchMode = .auto,
        notifier: any NotificationDeciding = FakeNotifier()
    ) throws -> RefreshCoordinator {
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword(fixturePassword, for: account.id)
        return try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: direct, safari: safari, mode: mode),
            credentials: credentials,
            accounts: { [account] },
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
}