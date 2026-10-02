import Foundation

/// Browser User-Agent required by Iliad's WAF (Go's default UA gets 403).
let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

protocol HTMLFetcher: Sendable {
    func fetchHTML(for account: FetchedAccount) async throws -> String
}

/// Direct HTTP fetch: login POST + consumi GET with an ephemeral, per-fetch
/// session. Each fetch is given its own functional ephemeral cookie storage,
/// so cookies stored during one fetch are invisible to every other fetch — that
/// is what keeps accounts from bleeding into each other. The base
/// configuration's own storage is deliberately ignored in favour of the
/// per-fetch one.
struct HTTPFetcher: HTMLFetcher {
    /// Bound on how many redirects one request will follow before it is called a
    /// loop. Iliad's `http`↔`https` loop (spec §2) is infinite by nature, so
    /// without a bound a blocked network would spin until the 20s timeout of
    /// whichever hop happened to be in flight — and the "redirect loop" that the
    /// Safari fallback exists for would never actually be reported as one.
    /// Go's `http.Client` stops at 10 (`defaultMaxRedirects`); matching it means a
    /// legitimate chain is never cut short by our own limit.
    static let maxRedirectHops = 10

    let baseURL: URL
    let timeout: TimeInterval
    let configuration: URLSessionConfiguration

    init(baseURL: URL = URL(string: "https://www.iliad.it")!,
         timeout: TimeInterval = 20,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.configuration = configuration
    }

    /// Builds the configuration for a single fetch: a copy of `base` with the
    /// request timeout applied and its own ephemeral cookie storage, so cookies
    /// stored during this fetch cannot reach any other fetch.
    ///
    /// `.ephemeral.httpCookieStorage` is used rather than `HTTPCookieStorage()`:
    /// each access yields a fresh, working in-memory storage, whereas a bare
    /// `HTTPCookieStorage()` is inert — it neither retains nor returns cookies.
    /// The base configuration's storage is intentionally discarded.
    static func makeIsolatedConfiguration(from base: URLSessionConfiguration,
                                          timeout: TimeInterval) -> URLSessionConfiguration {
        let config = base.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        return config
    }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        let config = Self.makeIsolatedConfiguration(from: configuration, timeout: timeout)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Redirects are followed by `send(_:session:jar:)`, not by URLSession,
        // so that every hop's `Set-Cookie` can be absorbed into this jar before
        // the next hop is issued. The Go reference relies on the equivalent
        // property of `http.Client` (its `Jar` records the cookie of *every*
        // response, redirects included); matching that here is what makes a
        // portal that only sets the session cookie on the second hop work
        // instead of failing every SIM with a false "credenziali non valide".
        let cookies = CookieJar()

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "login-ident", value: account.username),
            URLQueryItem(name: "login-pwd", value: account.password),
        ]
        var login = URLRequest(url: baseURL.appendingPathComponent("/account/login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        login.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        // Deliberately no auth verdict on this stage, matching the Go reference:
        // `FetchHTML` only rejects a login status >= 400 and decides
        // authentication on the *consumi* response. A URL check here would also be
        // dominated — a chain that ends back on `/account/login` serves the form,
        // which the consumi stage detects anyway — while being able to report
        // "credenziali non valide" for a password that is fine.
        do {
            let (response, _) = try await send(login, session: session, jar: cookies, stage: "login")
            guard response.statusCode < 400 else {
                throw IliadError.network("login HTTP \(response.statusCode)")
            }
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("login: \(error.localizedDescription)")
        }

        var consumi = URLRequest(url: baseURL.appendingPathComponent("/account/consumi-e-credito"))
        consumi.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (response, data) = try await send(consumi, session: session, jar: cookies, stage: "consumi")
            guard response.statusCode < 400 else {
                throw IliadError.network("consumi HTTP \(response.statusCode)")
            }
            let page = String(decoding: data, as: UTF8.self)
            if response.url?.path == "/account/login" || page.contains("name=\"login-ident\"") {
                throw IliadError.auth("credenziali non valide o sessione non autenticata")
            }
            return page
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("consumi: \(error.localizedDescription)")
        }
    }

    /// Issues one request and follows its redirect chain by hand, absorbing each
    /// hop's `Set-Cookie` into `jar` before the next request so the session
    /// cookie travels the whole way.
    ///
    /// The loop is here — rather than left to URLSession — for a second reason:
    /// the redirect suppression below only runs when a real `URLSession` stack
    /// asks its delegate about a redirect, and a custom `URLProtocol` (the test
    /// double) never does. A hand-rolled chain behaves identically in tests and
    /// in production, so the redirect semantics are actually covered rather than
    /// assumed.
    private func send(_ request: URLRequest, session: URLSession, jar: CookieJar,
                      stage: String) async throws -> (HTTPURLResponse, Data) {
        var current = request
        for hop in 0...Self.maxRedirectHops {
            if let cookieHeader = jar.headerValue {
                current.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: current, delegate: NoRedirectDelegate.shared)
            } catch {
                throw IliadError.network("\(stage): \(error.localizedDescription)")
            }
            guard let http = response as? HTTPURLResponse else {
                throw IliadError.network("\(stage): risposta non HTTP")
            }
            // Absorb before deciding what to do next: a 302 can be the hop that
            // actually establishes the session.
            jar.absorb(from: http, for: current.url ?? baseURL)
            guard http.statusCode != 304 else {
                throw IliadError.network("\(stage): HTTP 304")
            }
            guard Self.isRedirect(http.statusCode) else {
                return (http, data)
            }
            guard hop < Self.maxRedirectHops else {
                throw IliadError.network("\(stage): loop di redirect oltre \(Self.maxRedirectHops) hop")
            }
            guard let next = Self.followingRequest(from: current, response: http) else {
                throw IliadError.network("\(stage): redirect \(http.statusCode) senza Location valido")
            }
            current = next
        }
        // Unreachable: the loop returns or throws on its final iteration.
        throw IliadError.network("\(stage): catena di redirect non risolta")
    }

    private static func isRedirect(_ status: Int) -> Bool {
        switch status {
        case 301, 302, 303, 307, 308: true
        default: false
        }
    }

    /// The next hop of a redirect chain. Method rewriting follows RFC 9110 (and
    /// Go's `http.Client`): 303 — and 301/302 for a POST, which is the only
    /// method this fetcher issues for login — continue as a GET, while 307/308
    /// repeat method and body.
    static func followingRequest(from request: URLRequest,
                                 response: HTTPURLResponse) -> URLRequest? {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: request.url)?.absoluteURL else {
            return nil
        }
        var next = request
        next.url = target
        let method = request.httpMethod?.uppercased() ?? "GET"
        if response.statusCode == 303 || ((response.statusCode == 301 || response.statusCode == 302)
                                           && method == "POST") {
            next.httpMethod = "GET"
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Length")
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return next
    }
}

/// Stops URLSession from following redirects internally on the fetcher's behalf.
/// The redirect chain is followed by `HTTPFetcher.send(_:session:jar:)` instead,
/// so each hop's `Set-Cookie` is absorbed into the per-fetch jar before the next
/// request is issued — URLSession's internal following would issue the next hop
/// from storage state we do not control.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Minimal per-fetch cookie jar parsed from `Set-Cookie` response headers.
/// Accumulates across every hop of the login chain and is discarded with the
/// fetch, so nothing leaks into another account's session.
final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HTTPCookie] = []

    func absorb(from response: HTTPURLResponse, for url: URL) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let found = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !found.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: found)
    }

    var headerValue: String? {
        lock.lock(); defer { lock.unlock() }
        return HTTPCookie.requestHeaderFields(with: storage)["Cookie"]
    }
}
