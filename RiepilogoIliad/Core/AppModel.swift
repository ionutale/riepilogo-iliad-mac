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

/// Replaced with the real implementation in Task 11.
struct HistoryPoint: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var remainingGB: Double
}

/// Replaced with the real implementation in Task 11.
func dailyHistoryPoints(readings: [Reading], timeZone: TimeZone) -> [HistoryPoint] { [] }

@MainActor
@Observable
final class AppModel {
    var snapshot = Snapshot()
    var bootstrapError: String?
    let settings: AppSettings
    let coordinator: RefreshCoordinator
    private var timerTask: Task<Void, Never>?

    init(settings: AppSettings, coordinator: RefreshCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    var totals: Totals { computeTotals(entries: Array(snapshot.entries.values)) }
    var cards: [Entry] { sortEntries(Array(snapshot.entries.values)) }
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

    func start() {
        Task {
            // Notifications need a granted centre before the first cycle can post;
            // asked once at launch (and idempotently) so a revoked-then-restored
            // permission does not silence alerts until the next settings edit.
            if settings.notificationsEnabled {
                await SystemNotificationPoster.shared.requestAuthorization()
            }
            await reload()
            _ = await coordinator.refreshOnce()
            await reload()
        }
        timerTask = Task { [settings] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(settings.refreshInterval))
                _ = await coordinator.refreshOnce()
                await self.reload()
            }
        }
    }

    func refreshNow() {
        Task {
            _ = await coordinator.refreshOnce()
            await reload()
        }
    }

    func reload() async {
        snapshot = await coordinator.snapshot()
    }

    func historyPoints(account: String, days: Int = 30) -> [HistoryPoint] {
        guard let store = coordinator.storeHandle else { return [] }
        let readings = (try? store.history(account: account, since: Date().addingTimeInterval(-Double(days) * 86400))) ?? []
        return dailyHistoryPoints(readings: readings, timeZone: TimeZone(identifier: "Europe/Rome") ?? .current)
    }
}
