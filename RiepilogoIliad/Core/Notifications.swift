import Foundation
import UserNotifications

/// Pure decision logic: low data, exhausted, renewed cycle.
/// Providers keep thresholds and the enabled flag live without rebuilding.
struct NotificationDecider: NotificationDeciding {
    var thresholdProvider: @Sendable () -> Double
    var enabledProvider: @Sendable () -> Bool

    init(thresholdPercent: Double = 10, enabled: @escaping @Sendable () -> Bool = { true }) {
        self.thresholdProvider = { thresholdPercent }
        self.enabledProvider = enabled
    }

    init(thresholdProvider: @escaping @Sendable () -> Double,
         enabledProvider: @escaping @Sendable () -> Bool = { true }) {
        self.thresholdProvider = thresholdProvider
        self.enabledProvider = enabledProvider
    }

    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision {
        guard enabledProvider() else { return .none }
        let thresholdPercent = thresholdProvider()
        guard let remaining = current.remainingGB else { return .none }

        if let old = previous?.remainingGB, old >= 0, remaining > old + 1, remaining > old * 2 {
            return .renewed
        }
        if remaining == 0 { return .exhausted }
        if let allowance = current.allowanceGB, allowance > 0,
           remaining / allowance * 100 <= thresholdPercent {
            return .low
        }
        return .none
    }

    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {
        guard decision != .none else { return }
        let body: String
        switch decision {
        case .low: body = "Restano \(formatGB(data.remainingGB ?? 0)) sulla \(account.name)."
        case .exhausted: body = "Dati esauriti sulla \(account.name)."
        case .renewed: body = "Nuovo ciclo dati sulla \(account.name): \(formatGB(data.remainingGB ?? 0))."
        case .none: return
        }
        await SystemNotificationPoster.shared.post(
            title: "Riepilogo Iliad", body: body,
            id: "\(account.id)-\(decision)")
    }
}

/// Sends local notifications via UNUserNotificationCenter.
final class SystemNotificationPoster: @unchecked Sendable {
    static let shared = SystemNotificationPoster()

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Temporary formatting helper; Task 10 moves this to Format.swift.
func formatGB(_ value: Double) -> String {
    var s = String(format: "%.1f", value)
    s = s.replacingOccurrences(of: ".", with: ",")
    if s.hasSuffix(",0") { s.removeLast(2) }
    return s + " GB"
}