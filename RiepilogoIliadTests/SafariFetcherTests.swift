import XCTest
@testable import RiepilogoIliad

final class SafariFetcherTests: XCTestCase {
    private func account() -> FetchedAccount {
        FetchedAccount(id: UUID(), name: "SIM 1", username: "user@example.com", password: "secret", renewalDay: nil)
    }

    func testSuccessParsesPage() async throws {
        let capturedScript = Box("")
        let capturedArgs = Box<[String]>([])
        let runner: ScriptRunner = { script, args in
            capturedScript.value = script
            capturedArgs.value = args
            return #"<html><body><span class="red">1 GB / 10 GB</span><span class="big red">9</span><span class="small red">GB</span></body></html>"#
        }
        let fetcher = SafariFetcher(runner: runner)
        let html = try await fetcher.fetchHTML(for: account())
        XCTAssertTrue(html.contains("9"))
        XCTAssertTrue(capturedScript.value.contains("tell application \"Safari\""))
        XCTAssertEqual(capturedArgs.value.count, 1)
        let js = capturedArgs.value[0]
        XCTAssertTrue(js.contains("/account/?logout=user"))
        XCTAssertTrue(js.contains("/account/login"))
        XCTAssertTrue(js.contains("/account/consumi-e-credito"))
        XCTAssertTrue(js.contains("\"user@example.com\"")) // JSON literal
    }

    func testCredentialsAreJSONEscaped() async throws {
        let capturedArgs = Box<[String]>([])
        let runner: ScriptRunner = { _, args in
            capturedArgs.value = args
            return #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
        }
        let fetcher = SafariFetcher(runner: runner)
        _ = try await fetcher.fetchHTML(for: FetchedAccount(
            id: UUID(), name: "X", username: "u\"ser", password: "p'wd\\", renewalDay: nil))
        let js = capturedArgs.value[0]
        XCTAssertTrue(js.contains(#""u\"ser""#))
        XCTAssertTrue(js.contains(#""p'wd\\""#))
    }

    func testLoginPageMeansAuthError() async {
        let runner: ScriptRunner = { _, _ in
            #"<form><input name="login-ident"></form>"#
        }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testJSSettingErrorIsActionable() async {
        let runner: ScriptRunner = { _, _ in
            throw IliadError.network("You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings")
        }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected safariJSSetting error")
        } catch let error as IliadError {
            guard case .safariJSSetting = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testRunnerFailureIsNetworkError() async {
        let runner: ScriptRunner = { _, _ in throw IliadError.network("boom") }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// `delay 30` needs no Apple Events permission and touches no application,
    /// so cancelling after half a second must tear the child down promptly.
    /// Bounded by `fulfillment(timeout:)` so a regression fails instead of
    /// hanging. Only "it throws" is asserted — the message is not part of the
    /// contract (an `.network` error is fine).
    func testDefaultRunnerTerminatesOnCancellation() async throws {
        let finished = expectation(description: "runner returns after cancellation")
        let thrown = Box<Error?>(nil)
        let task = Task {
            do {
                _ = try await SafariFetcher.defaultRunner("delay 30", [])
            } catch {
                thrown.value = error
            }
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertNotNil(thrown.value, "expected the runner to throw when cancelled")
    }
}
