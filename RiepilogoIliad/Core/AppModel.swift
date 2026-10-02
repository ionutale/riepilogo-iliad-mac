import Foundation
import Observation

struct Totals: Equatable {
    var remainingGB = 0.0
    var allowanceGB = 0.0
    var pct = 0.0
    var excluded = 0
    var nextName: String?
    var nextDays: Int?
    var hasData = false
}

func computeTotals(entries: [Entry], today: Date = today(in: TimeZone(identifier: "Europe/Rome")!)) -> Totals {
    var totals = Totals()
    for entry in entries {
        guard let good = entry.lastGood,
              let remaining = good.remainingGB,
              let allowance = good.allowanceGB, allowance > 0 else {
            totals.excluded += 1
            continue
        }
        totals.remainingGB += remaining
        totals.allowanceGB += allowance
        if let renewal = good.renewalDate?.date {
            let days = daysBetween(today, renewal)
            if totals.nextDays == nil || days < totals.nextDays! {
                totals.nextDays = days
                totals.nextName = entry.account
            }
        }
    }
    totals.hasData = totals.allowanceGB > 0
    if totals.hasData {
        totals.pct = totals.remainingGB / totals.allowanceGB * 100
    }
    return totals
}

func sortEntries(_ entries: [Entry], today: Date = today(in: TimeZone(identifier: "Europe/Rome")!)) -> [Entry] {
    entries.sorted { lhs, rhs in
        let l = lhs.lastGood?.renewalDate.map { daysBetween(today, $0.date) }
        let r = rhs.lastGood?.renewalDate.map { daysBetween(today, $0.date) }
        switch (l, r) {
        case let (l?, r?): return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.account < rhs.account
        }
    }
}

/// One point per local calendar day, plotted at that day's midnight.
struct HistoryPoint: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var remainingGB: Double
}

/// Collapses a run of readings into one point per local day, keeping the latest
/// reading of each day. `readings` must be ascending by `fetchedAt` (which is
/// what `Store.history` returns), so the last write for a day is its newest one
/// while `order` preserves first-seen day ordering. A day whose newest reading
/// has no `remainingGB` is dropped: a nil cannot be plotted, and falling back to
/// an older reading of the same day would report a quota figure already stale.
func dailyHistoryPoints(readings: [Reading], timeZone: TimeZone) -> [HistoryPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var byDay: [Date: Reading] = [:]
    var order: [Date] = []
    for reading in readings {
        let day = calendar.startOfDay(for: reading.fetchedAt.date)
        if byDay[day] == nil { order.append(day) }
        byDay[day] = reading
    }
    return order.compactMap { day in
        guard let reading = byDay[day], let remaining = reading.remainingGB else { return nil }
        return HistoryPoint(date: day, remainingGB: remaining)
    }
}

/// Per-card state badge spec §8 asks for, with last-good values kept on screen.
enum EntryBadge: Equatable, Sendable {
    /// The last attempt failed. The numbers below the badge are the previous
    /// good ones, which is precisely what the user needs to know.
    case error(String)
    /// The newest *successful* reading is older than two refresh intervals, so
    /// the fetch loop itself is not keeping up and the numbers may be wrong.
    case stale
}

/// True when the remaining quota is at or below the configured low threshold.
///
/// Independent of `barClass`, which is about *used* — spec §8 asks for both
/// signals, and a SIM that is nearly out is both nearly used and low. An
/// allowance of zero is not "low data": there is nothing to compare against.
func isLowData(remaining: Double, allowance: Double, threshold: Double) -> Bool {
    guard allowance > 0 else { return false }
    return remaining / allowance * 100 <= threshold
}

/// The badge for one card, given the current refresh interval.
///
/// An error always wins: the newest attempt failed and the figures on the card
/// are the previous good ones. `stale` covers the other way a card can be
/// lying — the last *successful* reading has aged past two intervals. A SIM
/// that was just attempted and failed already gets `.error`, so the two cases
/// cannot both claim the same card.
func entryBadge(for entry: Entry, now: Date = Date(), interval: TimeInterval) -> EntryBadge? {
    if let error = entry.lastError { return .error(error) }
    guard let good = entry.lastGood else { return nil }
    guard now.timeIntervalSince(good.fetchedAt.date) > 2 * interval else { return nil }
    return .stale
}

@MainActor
@Observable
final class AppModel {
    /// Days plotted by the per-SIM sparkline in the popover (spec §8).
    static let sparklineDays = 7

    var snapshot = Snapshot()
    /// Observable for the whole duration of a cycle, manual or timer-driven.
    /// `Snapshot` cannot carry this: the coordinator republishes only after the
    /// cycle, so a flag read from it was always `false` when the UI needed it.
    private(set) var isRefreshing = false
    /// Last 7 daily points per account, for the card sparkline. Refilled on
    /// every `reload()` off the main actor, same as `historyPoints`.
    private(set) var sparklines: [String: [HistoryPoint]] = [:]
    let settings: AppSettings
    let coordinator: RefreshCoordinator
    /// Internal rather than private so the reschedule behaviour is observable
    /// from tests without waiting out a one-hour sleep.
    private(set) var timerTask: Task<Void, Never>?

    /// Stops the sleep loop. Used by tests (and the only correct way to shut the
    /// loop down without waiting out its interval).
    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    init(settings: AppSettings, coordinator: RefreshCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    var totals: Totals { computeTotals(entries: Array(snapshot.entries.values)) }
    var cards: [Entry] { sortEntries(Array(snapshot.entries.values)) }

    /// The empty state is only honest when no account is configured. A SIM that
    /// has been added but not fetched yet still renders a card (a bare entry),
    /// so "no cards" alone is not enough — and claiming "Nessun account
    /// configurato" next to a configured SIM is the false message this guards.
    var hasNoAccounts: Bool { cards.isEmpty && settings.accounts.isEmpty }

    var hasWarning: Bool {
        cards.contains { entry in
            guard let remaining = entry.lastGood?.remainingGB else { return false }
            if remaining == 0 { return true }
            if let allowance = entry.lastGood?.allowanceGB, allowance > 0 {
                return remaining / allowance * 100 <= settings.lowThresholdPercent
            }
            return false
        }
    }

    func badge(for entry: Entry) -> EntryBadge? {
        entryBadge(for: entry, now: Date(), interval: settings.refreshInterval)
    }

    func start() {
        Task {
            // Notifications need a granted centre before the first cycle can post;
            // asked once at launch (and idempotently) so a revoked-then-restored
            // permission does not silence alerts until the next settings edit.
            if settings.notificationsEnabled {
                await SystemNotificationPoster.shared.requestAuthorization()
            }
            await reload()
            await runRefreshCycle()
        }
        rescheduleTimer()
    }

    /// Cancels the pending sleep and starts a fresh loop with the interval that
    /// is configured *now*.
    ///
    /// Without it the loop reads `settings.refreshInterval` once per iteration
    /// and then sleeps for it: switching from 24h to 1h would leave the old
    /// cadence in place for up to a day, which for a quota monitor means showing
    /// a day-old reading with no warning.
    func rescheduleTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.settings.refreshInterval))
                // `Task.sleep` swallows its cancellation as `nil`, so the
                // cancelled sleep falls through to here; without this check a
                // cancel-then-reschedule would fire one extra cycle.
                if Task.isCancelled { return }
                await self.runRefreshCycle()
            }
        }
    }

    func refreshNow() {
        Task { await runRefreshCycle() }
    }

    /// One cycle plus the post-cycle reload, bracketed by `isRefreshing` so the
    /// popover can disable "Aggiorna ora" and show a spinner for the whole
    /// window — five sequential fetches can run for minutes.
    func runRefreshCycle() async {
        isRefreshing = true
        _ = await coordinator.refreshOnce()
        isRefreshing = false
        await reload()
    }

    /// Reconciles the snapshot with the configured accounts and reloads it.
    /// Called from Settings after add/edit/remove/import so the popover shows a
    /// new SIM (or drops a deleted one) at once instead of at the next cycle.
    func accountsChanged() async {
        await coordinator.reconcile()
        await reload()
    }

    func reload() async {
        snapshot = await coordinator.snapshot()
        await loadSparklines()
    }

    /// Reads one account's history off the main actor: the SQLite query is
    /// synchronous, so it runs on a detached task and the UI only ever awaits
    /// the aggregated result.
    func historyPoints(account: String, days: Int = 30) async -> [HistoryPoint] {
        let store = coordinator.storeHandle
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let readings = (try? await Task.detached { try store.history(account: account, since: since) }.value) ?? []
        return dailyHistoryPoints(readings: readings, timeZone: romeTimeZone)
    }

    /// One off-main pass over every account for the card sparklines. A SIM with
    /// no history yet simply has no entry, and the card renders no chart.
    private func loadSparklines() async {
        let store = coordinator.storeHandle
        let names = Array(snapshot.entries.keys)
        let since = Date().addingTimeInterval(-Double(Self.sparklineDays) * 86400)
        let days = Self.sparklineDays
        sparklines = await Task.detached { () -> [String: [HistoryPoint]] in
            var result: [String: [HistoryPoint]] = [:]
            for name in names {
                let readings = (try? store.history(account: name, since: since)) ?? []
                result[name] = Array(
                    dailyHistoryPoints(readings: readings, timeZone: romeTimeZone).suffix(days))
            }
            return result
        }.value
    }
}

/// Single source for the timezone every "today"/day-boundary calculation uses
/// (spec §6: date-only arithmetic in UTC, "today" in `Europe/Rome`).
let romeTimeZone: TimeZone = TimeZone(identifier: "Europe/Rome") ?? .current
