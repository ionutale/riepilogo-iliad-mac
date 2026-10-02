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

struct CheckResult: Identifiable, Sendable {
    var account: String
    /// The account name is how the coordinator keys a SIM, so it also
    /// identifies the row in the Settings check-results table (`TableColumn`
    /// requires `Identifiable`).
    var id: String { account }
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
    /// True while either a refresh cycle or a "Verifica account" run is in
    /// flight. The two are mutually exclusive on purpose: both drive the same
    /// Safari tab on the fallback path, and `SafariFetcher`'s first step is
    /// `GET /account/?logout=user`, so overlapping them would log the in-flight
    /// cycle out of its session and turn a working SIM into a bogus `.auth`.
    private var fetchInFlight = false
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
        let live = accounts()
        // Hydration *is* reconciliation, written out rather than delegated to
        // `reconcile(accounts:)` because an actor's `init` is not isolated to the
        // actor. Every configured SIM gets an entry here, so it has a card at
        // launch instead of appearing only after the first cycle.
        //
        // Rows in the store for accounts that are no longer configured are left
        // untouched: they belong to the history, not to the snapshot, and a
        // re-added SIM must find its own past data again.
        for account in live {
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

    /// Reconciles the in-memory snapshot with the configured accounts.
    ///
    /// `entries` *is* what the UI renders and what `computeTotals` sums, and it
    /// is keyed by account **name** — the same key the `readings` table uses —
    /// so without this call the snapshot drifts from the account list in both
    /// directions:
    ///
    /// - a deleted or renamed SIM keeps its card, keeps its frozen `lastGood`
    ///   and keeps contributing to the menu-bar total until the app is
    ///   relaunched;
    /// - a SIM added in Settings renders no card at all until the next cycle
    ///   (up to 4h by default), while the popover claims there is no account
    ///   configured.
    ///
    /// Seeding a bare `Entry` is what makes a new SIM appear at once: it has no
    /// reading and no error, so the card says it has no data yet instead of
    /// being absent.
    func reconcile(accounts configured: [Account]? = nil) {
        let live = configured ?? accounts()
        let names = Set(live.map(\.name))
        for name in Array(entries.keys) where !names.contains(name) {
            entries.removeValue(forKey: name)
        }
        for account in live where entries[account.name] == nil {
            entries[account.name] = Entry(account: account.name)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(entries: entries, lastCycle: lastCycle)
    }

    /// Escape hatch for the UI to read history. `nonisolated` so the main-actor
    /// `AppModel` can reach it; `Store` is itself `Sendable`, so handing the
    /// handle across actors is safe and the caller decides the executor.
    nonisolated var storeHandle: Store { store }

    /// Runs one cycle over every account, sequentially. Returns `false` when a
    /// fetch is already in flight (single-flight: the caller gets a no-op).
    func refreshOnce() async -> Bool {
        guard !fetchInFlight else { return false }
        fetchInFlight = true
        defer {
            fetchInFlight = false
            lastCycle = Date()
        }
        reconcile()
        for account in accounts() {
            await refresh(account: account)
        }
        return true
    }

    /// Returned verbatim for every account while a fetch is already running, so
    /// a busy "Verifica account" can never be mistaken for a credential
    /// failure — reporting `ok: false` with this message is a statement about
    /// the app's state, not about the SIM's password.
    static let busyMessage = "Aggiornamento in corso. Riprova tra poco."

    /// Read-only connectivity probe used by Settings: fetches and parses every
    /// account but touches neither the store nor the in-memory snapshot.
    ///
    /// Serialised against refresh cycles (see `fetchInFlight`): a concurrent
    /// probe would race the cycle through the same Safari tab and, on the
    /// fallback path, its logout step would invalidate the cycle's session.
    func checkAccounts() async -> [CheckResult] {
        guard !fetchInFlight else {
            return accounts().map {
                CheckResult(account: $0.name, ok: false, path: nil, usedGB: nil,
                            remainingGB: nil, allowanceGB: nil, renewalDate: nil,
                            daysToRenewal: nil, error: Self.busyMessage)
            }
        }
        fetchInFlight = true
        defer { fetchInFlight = false }
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

            // The user can remove or rename this SIM while the fetch is in flight
            // (the fetches are sequential and seconds apart). `accounts` is the
            // live list, so re-checking it here keeps a completed-but-obsolete
            // fetch from resurrecting a card the user has just deleted; the next
            // `reconcile()` would drop it again, but until then it would sit on
            // screen and in the totals. The reading row is still written: history
            // belongs to the database, not to the current account list.
            if isStillConfigured(account.name) {
                let previous = entries[account.name]?.lastGood?.accountData
                entries[account.name] = Entry(account: account.name, lastGood: reading,
                                              lastAttempt: now, lastError: nil)
                let decision = notifier.decide(previous: previous, current: data, account: account)
                await notifier.post(decision, account: account, data: data)
            }
        } catch {
            let message = redactedError((error as? IliadError)?.userMessage ?? error.localizedDescription,
                                        password: password, username: account.username)
            try? store.insert(Reading.failure(account: account.name, error: message, fetchedAt: now))
            // Same guard as the success path: a failure row is written either way,
            // but a SIM the user removed mid-cycle must not get a card back.
            guard isStillConfigured(account.name) else { return }
            var entry = entries[account.name] ?? Entry(account: account.name)
            entry.lastAttempt = now
            entry.lastError = message
            entries[account.name] = entry
        }
    }

    /// Whether `name` is still one of the configured accounts. The provider is
    /// read live (`AppSettings.runtime`), so this sees an edit made while this
    /// cycle was fetching.
    private func isStillConfigured(_ name: String) -> Bool {
        accounts().contains { $0.name == name }
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
