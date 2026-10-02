import XCTest
@testable import RiepilogoIliad

struct StubFetcher: HTMLFetcher {
    let result: @Sendable () throws -> String
    func fetchHTML(for account: FetchedAccount) async throws -> String { try result() }
}

final class AutoFetcherTests: XCTestCase {
    private func account() -> FetchedAccount {
        FetchedAccount(id: UUID(), name: "SIM 1", username: "u", password: "p", renewalDay: nil)
    }

    func testDirectSuccessDoesNotTouchSafari() async throws {
        let safariUsed = Box(false)
        let direct = StubFetcher { "<html>ok</html>" }
        let safari = StubFetcher {
            safariUsed.value = true
            return "<html>safari</html>"
        }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        let outcome = try await auto.fetchHTML(for: account())
        XCTAssertEqual(outcome.path, .direct)
        XCTAssertFalse(safariUsed.value)
    }

    func testNetworkErrorFallsBackToSafari() async throws {
        let direct = StubFetcher { throw IliadError.network("redirect loop") }
        let safari = StubFetcher { "<html>safari</html>" }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        let outcome = try await auto.fetchHTML(for: account())
        XCTAssertEqual(outcome.path, .safari)
        XCTAssertEqual(outcome.html, "<html>safari</html>")
    }

    func testAuthErrorDoesNotFallBack() async {
        let safariUsed = Box(false)
        let direct = StubFetcher { throw IliadError.auth("bad credentials") }
        let safari = StubFetcher {
            safariUsed.value = true
            return "<html>safari</html>"
        }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        do {
            _ = try await auto.fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
        XCTAssertFalse(safariUsed.value)
    }

    func testForcedModes() async throws {
        let direct = StubFetcher { "<html>direct</html>" }
        let safari = StubFetcher { "<html>safari</html>" }
        let safariOnly = AutoFetcher(direct: direct, safari: safari, mode: .safari)
        // Hoisted out of the assertion: XCTAssertEqual takes its expression as a
        // non-async autoclosure, so an `await` cannot appear inside it.
        let safariPath = try await safariOnly.fetchHTML(for: account()).path
        XCTAssertEqual(safariPath, .safari)

        let directOnly = AutoFetcher(direct: direct, safari: safari, mode: .direct)
        let directPath = try await directOnly.fetchHTML(for: account()).path
        XCTAssertEqual(directPath, .direct)
    }

    /// The mode must be read per fetch, not captured at construction: the app
    /// builds one fetcher for the whole process and the user can change the mode
    /// in Settings afterwards.
    func testModeProviderIsConsultedOnEveryFetch() async throws {
        let mode = Box(FetchMode.direct)
        let direct = StubFetcher { "<html>direct</html>" }
        let safari = StubFetcher { "<html>safari</html>" }
        let auto = AutoFetcher(direct: direct, safari: safari, modeProvider: { mode.value })

        let directPath = try await auto.fetchHTML(for: account()).path
        XCTAssertEqual(directPath, .direct)

        mode.value = .safari
        let safariPath = try await auto.fetchHTML(for: account()).path
        XCTAssertEqual(safariPath, .safari)
    }
}
