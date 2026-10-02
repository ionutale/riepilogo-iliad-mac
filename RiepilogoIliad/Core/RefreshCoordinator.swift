import Foundation

/// Scrubs an error message before it is written to the database (which keeps
/// rows for `retentionDays`) or handed to the UI. Two reasons this matters:
/// `SafariFetcher` can surface raw `osascript` stderr, and the account's
/// password travels in that process's argv, so external text can quote the
/// credentials back at us.
///
/// Redaction is unconditional: a one-character password that garbles the
/// message is a better failure mode than a persisted credential. Credentials
/// are replaced before the message is truncated, so a secret straddling the cut
/// cannot survive half-substituted.
func redactedError(_ message: String, password: String?, username: String? = nil) -> String {
    var scrubbed = message
    for secret in [password, username] {
        guard let secret, !secret.isEmpty else { continue }
        scrubbed = scrubbed.replacingOccurrences(of: secret, with: "***")
    }
    // One line: a multi-line tool dump must not be able to smuggle structure
    // into a field the UI renders.
    let flattened = scrubbed
        .split(whereSeparator: { $0.isNewline || $0 == "\t" })
        .joined(separator: " ")
    guard flattened.count > 300 else { return flattened }
    return String(flattened.prefix(300)) + "…"
}

struct CheckResult: Sendable {
    var account: String
    var ok: Bool
    var path: FetchPath?
    var usedGB: Double?
    var remainingGB: Double?
    var allowanceGB: Double?
    var renewalDate: Date?
    var daysToRenewal: Int?
    var error: String?
}

/// Notification policy seam. Task 9's `NotificationDecider` implements it; the
/// coordinator only knows the shape, so it can be faked in tests.
protocol NotificationDeciding: Sendable {
    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision
    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async
}

/// Runs single-flight refresh cycles and keeps the UI snapshot.
actor RefreshCoordinator {
    private let store: Store
    private let fetcher: AutoFetcher
    private let credentials: CredentialStore
    private let accounts: @Sendable () -> [Account]
    private let notifier: NotificationDeciding
    private let retentionDays: Int

    private var entries: [String: Entry] = [:]
    private var refreshing = false
    private var lastCycle: Date?

    init(store: Store,
         fetcher: AutoFetcher,
         credentials: CredentialStore,
         accounts: @escaping @Sendable () -> [Account],
         notifier: NotificationDeciding,
         retentionDays: Int = 180) throws {
        self.store = store
        self.fetcher = fetcher
        self.credentials = credentials
        self.accounts = accounts
        self.notifier = notifier
        self.retentionDays = retentionDays

        let latest = try store.latestPerAccount()
        let lastGood = try store.lastGoodPerAccount()
        for account in accounts() {
            var entry = Entry(account: account.name)
            if let row = latest[account.name] {
                entry.lastAttempt = row.fetchedAt.date
                if !row.ok { entry.lastError = row.error }
            }
            entry.lastGood = lastGood[account.name]
            entries[account.name] = entry
        }
        // Retention pruning is best-effort: a failure here must not stop the app
        // from starting with the history it does have.
        _ = try? store.deleteOlderThan(Date().addingTimeInterval(-Double(retentionDays) * 86400))
    }

    func snapshot() -> Snapshot {
        Snapshot(entries: entries, refreshing: refreshing, lastCycle: lastCycle)
    }

    /// Runs one cycle over every account, sequentially. Returns `false` when a
    /// cycle is already in flight (single-flight: the caller gets a no-op).
    func refreshOnce() async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        defer {
            refreshing = false
            lastCycle = Date()
        }
        for account in accounts() {
            await refresh(account: account)
        }
        return true
    }

    /// Read-only connectivity probe used by Settings: fetches and parses every
    /// account but touches neither the store nor the in-memory snapshot.
    func checkAccounts() async -> [CheckResult] {
        var results: [CheckResult] = []
        for account in accounts() {
            // Declared outside the `do` so the `catch` can scrub it: a fetch
            // error can quote back the credentials that were just read.
            var password: String?
            do {
                password = try credentials.password(for: account.id)
                guard let password else {
                    throw IliadError.auth("password mancante nel Portachiavi")
                }
                let fetched = FetchedAccount(id: account.id, name: account.name,
                                             username: account.username, password: password,
                                             renewalDay: account.renewalDay)
                let outcome = try await fetcher.fetchHTML(for: fetched)
                let data = try parseAccountPage(html: outcome.html, now: todayNow(), renewalDay: account.renewalDay)
                results.append(CheckResult(
                    account: account.name, ok: true, path: outcome.path,
                    usedGB: data.usedGB, remainingGB: data.remainingGB, allowanceGB: data.allowanceGB,
                    renewalDate: data.renewalDate,
                    daysToRenewal: data.renewalDate.map { daysBetween(todayNow(), $0) },
                    error: nil))
            } catch {
                let message = redactedError((error as? IliadError)?.userMessage ?? error.localizedDescription,
                                            password: password, username: account.username)
                results.append(CheckResult(account: account.name, ok: false, path: nil,
                                           usedGB: nil, remainingGB: nil, allowanceGB: nil,
                                           renewalDate: nil, daysToRenewal: nil, error: message))
            }
        }
        return results
    }

    private func refresh(account: Account) async {
        let now = Date()
        // Declared outside the `do` so the `catch` can scrub it: a fetch error
        // can quote back the credentials that were just read.
        var password: String?
        do {
            password = try credentials.password(for: account.id)
            guard let password else {
                throw IliadError.auth("password mancante nel Portachiavi")
            }
            let fetched = FetchedAccount(id: account.id, name: account.name,
                                         username: account.username, password: password,
                                         renewalDay: account.renewalDay)
            let outcome = try await fetcher.fetchHTML(for: fetched)
            let data = try parseAccountPage(html: outcome.html, now: todayNow(), renewalDay: account.renewalDay)
            let reading = Reading.success(account: account.name, data: data, fetchedAt: now)
            try store.insert(reading)

            let previous = entries[account.name]?.lastGood?.accountData
            entries[account.name] = Entry(account: account.name, lastGood: reading,
                                          lastAttempt: now, lastError: nil)
            let decision = notifier.decide(previous: previous, current: data, account: account)
            await notifier.post(decision, account: account, data: data)
        } catch {
            let message = redactedError((error as? IliadError)?.userMessage ?? error.localizedDescription,
                                        password: password, username: account.username)
            try? store.insert(Reading.failure(account: account.name, error: message, fetchedAt: now))
            var entry = entries[account.name] ?? Entry(account: account.name)
            entry.lastAttempt = now
            entry.lastError = message
            entries[account.name] = entry
        }
    }

    private func todayNow() -> Date {
        today(in: TimeZone(identifier: "Europe/Rome") ?? .current)
    }
}

extension Reading {
    /// Converts a stored reading back into parsed account data (for notification decisions).
    var accountData: AccountData {
        AccountData(
            creditEUR: creditEUR, usedGB: usedGB, remainingGB: remainingGB,
            allowanceGB: allowanceGB,
            renewalDate: renewalDate?.date, periodStart: periodStart?.date, periodEnd: periodEnd?.date,
            phoneNumber: phone ?? "", offerName: offer ?? "")
    }
}