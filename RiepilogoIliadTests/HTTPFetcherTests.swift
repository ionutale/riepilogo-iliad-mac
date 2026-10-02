import XCTest
@testable import RiepilogoIliad

/// Fake portal served through URLProtocol; mimics the real WAF and cookies.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPFetcherTests: XCTestCase {
    private func mockConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    private func makeFetcher() -> HTTPFetcher {
        HTTPFetcher(baseURL: URL(string: "https://example.test")!, timeout: 5, configuration: mockConfig())
    }

    private func account(name: String = "SIM 1") -> FetchedAccount {
        FetchedAccount(id: UUID(), name: name, username: "user", password: "pass", renewalDay: nil)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessFollowsCookieSession() async throws {
        MockURLProtocol.handler = { request in
            let page = #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
            if request.url!.path == "/account/login" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), browserUserAgent)
                XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") ?? false)
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "https://example.test/account/consumi-e-credito",
                                                       "Set-Cookie": "session=abc; Path=/"])!, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        let html = try await makeFetcher().fetchHTML(for: account())
        XCTAssertTrue(html.contains("1 GB / 10 GB"))
    }

    func testLoginPageMeansAuthError() async {
        MockURLProtocol.handler = { request in
            let page = #"<form><input name="login-ident"></form>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testHTTPErrorIsNetworkError() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testSessionsAreIsolatedPerAccount() async throws {
        let seenCookies = Box<[String: String]>([:])
        MockURLProtocol.handler = { request in
            let host = request.url!.host!
            if request.url!.path == "/account/login" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "https://\(host)/account/consumi-e-credito",
                                                       "Set-Cookie": "session=\(host); Path=/"])!, Data())
            }
            seenCookies.value[host] = request.value(forHTTPHeaderField: "Cookie")
            let page = #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        let alice = HTTPFetcher(baseURL: URL(string: "https://alice.test")!, timeout: 5, configuration: mockConfig())
        let bob = HTTPFetcher(baseURL: URL(string: "https://bob.test")!, timeout: 5, configuration: mockConfig())
        _ = try await alice.fetchHTML(for: account())
        _ = try await bob.fetchHTML(for: account())
        XCTAssertEqual(seenCookies.value["alice.test"], "session=alice.test")
        XCTAssertEqual(seenCookies.value["bob.test"], "session=bob.test")
    }

    /// Regression: `URLSessionConfiguration.copy()` shares the base
    /// configuration's `HTTPCookieStorage` *object*, so without a fresh store
    /// every fetch reuses one cookie jar and account B's login POST carries
    /// account A's session cookie. The `MockURLProtocol` bypasses URLSession's
    /// cookie machinery entirely, so isolation is asserted on the configuration
    /// directly rather than end-to-end.
    func testEachFetchGetsIsolatedCookieStorage() throws {
        let base = mockConfig()
        let baseStorage = base.httpCookieStorage

        let a = HTTPFetcher.makeIsolatedConfiguration(from: base, timeout: 5)
        let b = HTTPFetcher.makeIsolatedConfiguration(from: base, timeout: 5)

        let aStorage = try XCTUnwrap(a.httpCookieStorage)
        let bStorage = try XCTUnwrap(b.httpCookieStorage)

        XCTAssertFalse(aStorage === bStorage, "each fetch must get its own cookie storage")
        XCTAssertFalse(aStorage === baseStorage, "must not reuse the base configuration's storage")
        XCTAssertFalse(bStorage === baseStorage, "must not reuse the base configuration's storage")
        XCTAssertEqual(a.timeoutIntervalForRequest, 5)
        XCTAssertEqual(b.timeoutIntervalForRequest, 5)

        XCTAssertTrue(base.httpCookieStorage === baseStorage, "base configuration must not be mutated")
    }
}
