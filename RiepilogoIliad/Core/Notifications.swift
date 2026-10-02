import Foundation
import UserNotifications

/// Pure decision logic: low data, exhausted, renewed cycle.
/// Providers keep thresholds and the enabled flag live without rebuilding.
struct NotificationDecider: NotificationDeciding {
    var thresholdProvider: @Sendable () -> Double
    var enabledProvider: @Sendable () -> Bool
    var poster: any NotificationPosting

    init(thresholdPercent: Double = 10,
         enabled: @escaping @Sendable () -> Bool = { true },
         poster: any NotificationPosting = SystemNotificationPoster.shared) {
        self.thresholdProvider = { thresholdPercent }
        self.enabledProvider = enabled
        self.poster = poster
    }

    init(thresholdProvider: @escaping @Sendable () -> Double,
         enabledProvider: @escaping @Sendable () -> Bool = { true },
         poster: any NotificationPosting = SystemNotificationPoster.shared) {
        self.thresholdProvider = thresholdProvider
        self.enabledProvider = enabledProvider
        self.poster = poster
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
        await poster.post(decision, for: account, data: data)
    }
}

/// Delivery seam under `NotificationDecider`, so the policy can be exercised
/// without a live `UNUserNotificationCenter`.
protocol NotificationPosting: Sendable {
    /// Announces `decision` for `account`. The reading is required, not optional:
    /// the alert text quotes the remaining GB, so there is no honest way to
    /// announce without it — a data-less overload could only invent a number,
    /// and an invented alert would still consume the gate's transition and
    /// suppress the real one.
    func post(_ decision: NotificationDecision, for account: Account, data: AccountData) async
}

/// Transition-based suppression: a state is announced once per account, and only
/// when it differs from the last announced one. An account parked below the
/// threshold would otherwise be re-alerted on every refresh cycle (floor: one
/// hour), which trains users to turn notifications off — and loses the `.renewed`
/// alert the spec wants. The last announced decision is persisted so relaunching
/// does not re-nag about a condition the user has already seen.
/// `@unchecked` only because `UserDefaults` is not `Sendable` in the SDK: it is
/// documented thread-safe, and the lock below serialises check-and-record anyway.
final class NotificationGate: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records the announcement and reports whether it should be delivered.
    /// Check-and-record is atomic, so two cycles cannot both claim one
    /// transition. `.none` is not a state worth announcing and is never recorded.
    func shouldAnnounce(_ decision: NotificationDecision, for account: Account) -> Bool {
        guard decision != .none else { return false }
        let key = "notification.lastDecision.\(account.id.uuidString)"
        let announced = "\(decision)"
        return lock.withLock {
            guard defaults.string(forKey: key) != announced else { return false }
            defaults.set(announced, forKey: key)
            return true
        }
    }
}

/// Sends local notifications via UNUserNotificationCenter, announcing each state
/// once per account.
final class SystemNotificationPoster: NotificationPosting, Sendable {
    static let shared = SystemNotificationPoster()

    private let gate: NotificationGate

    init(gate: NotificationGate = NotificationGate()) {
        self.gate = gate
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func post(_ decision: NotificationDecision, for account: Account, data: AccountData) async {
        guard let body = body(for: decision, account: account, remainingGB: data.remainingGB) else { return }
        // An unauthorized centre makes `add` fail. Ask first: the transition must
        // not be consumed by an announcement that could never be delivered, or the
        // user would never hear about it after granting permission later.
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        guard gate.shouldAnnounce(decision, for: account) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Riepilogo Iliad"
        content.body = body
        let request = UNNotificationRequest(identifier: "\(account.id)-\(decision)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func body(for decision: NotificationDecision, account: Account, remainingGB: Double?) -> String? {
        switch decision {
        case .none: return nil
        case .low: return "Restano \(formatGB(remainingGB ?? 0)) sulla \(account.name)."
        case .exhausted: return "Dati esauriti sulla \(account.name)."
        case .renewed: return "Nuovo ciclo dati sulla \(account.name): \(formatGB(remainingGB ?? 0))."
        }
    }
}
