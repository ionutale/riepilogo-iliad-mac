import XCTest
@testable import RiepilogoIliad

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

private final class FakeNotifier: NotificationDeciding, @unchecked Sendable {
    var decisions: [NotificationDecision] = []
    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision { .none }
    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {
        decisions.append(decision)
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    // `static` so the `@Sendable` fetcher closures below can read it without
    // capturing the non-Sendable XCTestCase instance.
    private static let page = #"<html><body><span class="red">2 GB / 200 GB</span><span class="big red">198</span><span class="small red">GB</span><p>Si rinnova il 17/10/2026.</p></body></html>"#

    private func makeCoordinator(
        store: Store,
        direct: any HTMLFetcher,
        safari: any HTMLFetcher = HTTPFetcher(baseURL: URL(string: "https://never.test")!)
    ) throws -> RefreshCoordinator {
        let account = Account(name: "SIM 1", username: "u", renewalDay: nil)
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("p", for: account.id)
        return try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: direct, safari: safari, mode: .auto),
            credentials: credentials,
            accounts: { [account] },
            notifier: FakeNotifier(),
            retentionDays: 180)
    }

    func testRefreshPersistsAndCaches() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { Self.page })
        let ran = await coordinator.refreshOnce()
        XCTAssertTrue(ran)
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, true)
    }

    func testFailureKeepsLastGood() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let shouldFail = Box(false)
        let direct = StubFetcher {
            if shouldFail.value { throw IliadError.auth("credenziali non valide") }
            return Self.page
        }
        let coordinator = try makeCoordinator(store: store, direct: direct)
        _ = await coordinator.refreshOnce()
        shouldFail.value = true
        _ = await coordinator.refreshOnce()
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertEqual(entry.lastError, "credenziali non valide")
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, false)
    }

    func testSingleFlight() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let coordinator = try makeCoordinator(store: store, direct: BlockingFetcher(gate: stream) { Self.page })
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
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: 7, allowanceGB: 10,
                               renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
        try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: Date()))
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { Self.page })
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 7)
    }

    func testCheckAccountsReportsPath() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let coordinator = try makeCoordinator(
            store: store,
            direct: StubFetcher { throw IliadError.network("redirect loop") },
            safari: StubFetcher { Self.page })
        let results = await coordinator.checkAccounts()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].ok)
        XCTAssertEqual(results[0].path, .safari)
    }
}