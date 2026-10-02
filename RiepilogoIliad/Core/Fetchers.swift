import Foundation

/// Browser User-Agent required by Iliad's WAF (Go's default UA gets 403).
let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

protocol HTMLFetcher: Sendable {
    func fetchHTML(for account: FetchedAccount) async throws -> String
}

/// Direct HTTP fetch: login POST + consumi GET with an ephemeral, per-fetch
/// session. Every fetch gets a brand-new `HTTPCookieStorage`, because
/// `URLSessionConfiguration.copy()` shares the base configuration's storage
/// object; without the fresh store a second account's login POST would carry
/// the first account's session cookie.
struct HTTPFetcher: HTMLFetcher {
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
    /// request timeout applied and a **fresh** cookie storage, so cookies are
    /// scoped to one fetch and never shared between accounts.
    static func makeIsolatedConfiguration(from base: URLSessionConfiguration,
                                          timeout: TimeInterval) -> URLSessionConfiguration {
        let config = base.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage()
        return config
    }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        let config = Self.makeIsolatedConfiguration(from: configuration, timeout: timeout)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Second cookie mechanism, needed because URLSession's automatic
        // injection lives in its HTTP protocol handler, which a custom
        // URLProtocol bypasses. Scoped to this call only.
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

        do {
            let (_, response) = try await session.data(for: login, delegate: NoRedirectDelegate.shared)
            guard let http = response as? HTTPURLResponse else {
                throw IliadError.network("login: risposta non HTTP")
            }
            cookies.absorb(from: http, for: login.url ?? baseURL)
            guard http.statusCode < 400 else {
                throw IliadError.network("login HTTP \(http.statusCode)")
            }
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("login: \(error.localizedDescription)")
        }

        var consumi = URLRequest(url: baseURL.appendingPathComponent("/account/consumi-e-credito"))
        consumi.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader = cookies.headerValue {
            consumi.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await session.data(for: consumi)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                throw IliadError.network("consumi HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let page = String(decoding: data, as: UTF8.self)
            if http.url?.path == "/account/login" || page.contains("name=\"login-ident\"") {
                throw IliadError.auth("credenziali non valide o sessione non autenticata")
            }
            return page
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("consumi: \(error.localizedDescription)")
        }
    }
}

/// Used on the login POST: stops URLSession from internally following the
/// post-login redirect with a request that bypasses our cookie propagation.
/// The consumi GET keeps normal redirect handling so an unauthenticated
/// session that bounces to `/account/login` is still detected.
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
private final class CookieJar: @unchecked Sendable {
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
