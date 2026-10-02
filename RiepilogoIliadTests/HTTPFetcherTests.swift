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
    /// configuration's `HTTPCookieStorage` *object*, so without a per-fetch
    /// store every fetch reuses one cookie jar and account B's login POST
    /// carries account A's session cookie. The replacement storage must also be
    /// functional — a bare `HTTPCookieStorage()` is inert, so identity checks
    /// alone would not catch that. The `MockURLProtocol` bypasses URLSession's
    /// cookie machinery entirely, so isolation is asserted on the
    /// configuration directly rather than end-to-end.
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

        // The per-fetch storage must actually work, not merely be a distinct
        // object: a bare `HTTPCookieStorage()` is inert and would pass the
        // identity checks above while silently storing nothing.
        let url = URL(string: "https://example.test/")!
        let cookie = HTTPCookie(properties: [.name: "session", .value: "a",
                                             .domain: "example.test", .path: "/"])!
        aStorage.setCookie(cookie)
        XCTAssertEqual(aStorage.cookies(for: url)?.first?.value, "a")
        // `cookies(for:)` returns an empty array (not nil) when there are none,
        // so assert emptiness rather than nil.
        let bCookies = bStorage.cookies(for: url) ?? []
        XCTAssertTrue(bCookies.isEmpty, "cookie storage must be scoped to one fetch")
    }

    // MARK: - Redirect chain (mirrors internal/iliad/client.go)

    /// The highest-risk divergence from the Go reference, which followed
    /// redirects and recorded the cookie of *every* hop. If the portal only
    /// establishes the session on hop 2, a client that does not absorb hop 2's
    /// `Set-Cookie` sees the consumi page bounce to `/account/login` and reports
    /// `.auth` for every SIM — telling the user their password is wrong when it
    /// is not, with no fallback (auth errors do not fall back to Safari).
    func testSessionCookieSetOnASecondRedirectHopIsUsed() async throws {
        let seenCookie = Box<String?>(nil)
        let hop2Cookie = Box<String?>(nil)
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            if path == "/account/login" {
                // Hop 1: a redirect that sets nothing at all.
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "/account/redirect"])!, Data())
            }
            if path == "/account/redirect" {
                // Hop 2: the hop that actually establishes the session.
                hop2Cookie.value = request.value(forHTTPHeaderField: "Cookie")
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "/account/consumi-e-credito",
                                                       "Set-Cookie": "session=s3cret; Path=/"])!, Data())
            }
            seenCookie.value = request.value(forHTTPHeaderField: "Cookie")
            let page = #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }

        let html = try await makeFetcher().fetchHTML(for: account())

        XCTAssertTrue(html.contains("1 GB / 10 GB"))
        XCTAssertNil(hop2Cookie.value, "hop 2 runs before the cookie exists")
        XCTAssertEqual(seenCookie.value, "session=s3cret",
                       "the cookie from hop 2 must ride the consumi request")
    }

    /// Both of the portal's login outcomes end at `/account/login`: rejected
    /// credentials redirect back to the form, and a session that was never
    /// established bounces the consumi GET there. Either way the chain's final
    /// URL is the signal, exactly as the Go client reads `resp.Request.URL.Path`.
    func testChainEndingAtTheLoginPageIsAuthError() async {
        // Two distinct rejections, both ending the chain on `/account/login`:
        // the POST bouncing back there (Go's `fakePortal` prints the form with a
        // 200 when the password is wrong), and the consumi GET bouncing there
        // because the session never took.
        MockURLProtocol.handler = { request in
            let page = #"<form action="/account/login"><input name="login-ident"></form>"#
            if request.httpMethod == "POST" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "/account/login"])!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, Data(page.utf8))
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

    /// The mirror case: the login POST redirects to a page that is *not* the login
    /// form, so the rejection can only be seen when the consumi GET bounces. This
    /// is the path the `name="login-ident"` sniff covers, and it must survive the
    /// redirect handling.
    func testConsumiBouncingToLoginIsAuthError() async {
        MockURLProtocol.handler = { request in
            if request.url!.path == "/account/login" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "/account/consumi-e-credito",
                                                       "Set-Cookie": "session=stale; Path=/"])!, Data())
            }
            // Unauthenticated: bounce to the form instead of serving data.
            return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                    headerFields: ["Location": "/account/login"])!, Data())
        }
        let consumiCookie = Box<String?>(nil)
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            if path == "/account/login" && method == "POST" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "/account/area",
                                                       "Set-Cookie": "session=stale; Path=/"])!, Data())
            }
            if path == "/account/area" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: nil)!, Data("<html>area privata</html>".utf8))
            }
            // Unauthenticated: serve the form. The session cookie from the login
            // chain does travel here, so the rejection cannot be a missing cookie.
            consumiCookie.value = request.value(forHTTPHeaderField: "Cookie")
            let page = #"<form action="/account/login"><input name="login-ident"></form>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, Data(page.utf8))
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
        XCTAssertEqual(consumiCookie.value, "session=stale",
                       "the cookie must have been carried, so this is an auth verdict, not a plumbing one")
    }

    /// Spec §2: on some networks `/account/*` enters an http↔https redirect loop.
    /// `HTTPFetcher` turns it into a `.network` error, which is precisely the
    /// class that makes `AutoFetcher` fall back to Safari — so an unbounded
    /// chain here would both burn the timeout on every hop and hide the signal
    /// the fallback depends on.
    func testRedirectLoopIsBoundedAsNetworkError() async {
        let hops = Box(0)
        MockURLProtocol.handler = { request in
            hops.value += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                    headerFields: ["Location": "/account/loop"])!, Data())
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(error.userMessage.contains("redirect"),
                          "a loop must say so, got: \(error.userMessage)")
        } catch {
            XCTFail("got \(error)")
        }
        // The initial request plus exactly `maxRedirectHops` follow-ups.
        XCTAssertEqual(hops.value, HTTPFetcher.maxRedirectHops + 1)
    }

    /// A 302 after a POST continues as a GET without the form body — matching
    /// Go's `http.Client` and RFC 9110. Replaying the login `POST` would log in
    /// twice at best and re-submit credentials at worst.
    func testPostRedirectContinuesAsGetWithoutBody() throws {
        var original = URLRequest(url: URL(string: "https://example.test/account/login")!)
        original.httpMethod = "POST"
        original.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        original.setValue("42", forHTTPHeaderField: "Content-Length")
        original.httpBody = Data("login-ident=user".utf8)
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "/account/consumi-e-credito"])!

        let next = try XCTUnwrap(HTTPFetcher.followingRequest(from: original, response: response))

        XCTAssertEqual(next.httpMethod, "GET")
        XCTAssertNil(next.httpBody)
        XCTAssertNil(next.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(next.url?.absoluteString, "https://example.test/account/consumi-e-credito")
    }

    /// 307/308 mean "same method, same body" — the login POST must not be
    /// silently downgraded to a GET, which the portal would answer with the
    /// unauthenticated login form.
    func testTemporaryRedirectRepeatsThePost() throws {
        for status in [307, 308] {
            var original = URLRequest(url: URL(string: "https://example.test/account/login")!)
            original.httpMethod = "POST"
            original.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            original.httpBody = Data("login-ident=user".utf8)
            let response = HTTPURLResponse(url: original.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Location": "/account/login-again"])!

            let next = try XCTUnwrap(HTTPFetcher.followingRequest(from: original, response: response),
                                     "status \(status)")

            XCTAssertEqual(next.httpMethod, "POST", "status \(status)")
            XCTAssertEqual(next.httpBody, Data("login-ident=user".utf8), "status \(status)")
            XCTAssertEqual(next.value(forHTTPHeaderField: "Content-Type"),
                           "application/x-www-form-urlencoded", "status \(status)")
        }
    }

    /// A redirect with no usable `Location` cannot be followed; reporting it as
    /// a network error is what lets Safari take over instead of the fetch
    /// pretending to have reached a page.
    func testRedirectWithoutLocationIsNetworkError() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(error.userMessage.contains("Location"))
        } catch {
            XCTFail("got \(error)")
        }
    }
}
