import Foundation
import Observation

/// Refresh-interval choices offered in Settings, in seconds. Shared with
/// `snapRefreshInterval` so an interval imported from the Go `config.yaml`
/// always lands on a value the picker can show — a `Picker` bound to a value
/// outside its tag list displays no selection at all. The first entry is the
/// one-hour floor `AppSettings.refreshInterval` enforces.
let refreshIntervalTags: [TimeInterval] = [1, 2, 4, 6, 8, 12, 24].map { $0 * 3600 }

/// UserDefaults-backed app settings. Accounts are JSON; passwords are Keychain.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let accounts = "accounts"
        static let refreshInterval = "refreshInterval"
        static let fetchMode = "fetchMode"
        static let lowThresholdPercent = "lowThresholdPercent"
        static let notificationsEnabled = "notificationsEnabled"
    }

    private let defaults: UserDefaults

    /// Lock-guarded mirror of the settings for the background actors
    /// (`RefreshCoordinator`, the fetcher and notifier providers) that read them
    /// off the main actor.
    let runtime = RuntimeConfig()

    var accounts: [Account] {
        didSet {
            persist(accounts, forKey: Keys.accounts)
            syncRuntime()
        }
    }
    var refreshInterval: TimeInterval {
        didSet {
            if refreshInterval < 3600 { refreshInterval = 3600 }
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
            syncRuntime()
        }
    }
    var fetchMode: FetchMode {
        didSet {
            defaults.set(fetchMode.rawValue, forKey: Keys.fetchMode)
            syncRuntime()
        }
    }
    var lowThresholdPercent: Double {
        didSet {
            defaults.set(lowThresholdPercent, forKey: Keys.lowThresholdPercent)
            syncRuntime()
        }
    }
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            syncRuntime()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accounts = Self.load([Account].self, from: defaults, key: Keys.accounts) ?? []
        let stored = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = stored >= 3600 ? stored : 4 * 3600
        self.fetchMode = FetchMode(rawValue: defaults.string(forKey: Keys.fetchMode) ?? "") ?? .auto
        let threshold = defaults.double(forKey: Keys.lowThresholdPercent)
        self.lowThresholdPercent = threshold > 0 ? threshold : 10
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        syncRuntime()
    }

    /// Pushes the current values into the background-readable mirror. Called
    /// after every mutation so the actors never observe a stale setting.
    private func syncRuntime() {
        runtime.update(accounts: accounts, fetchMode: fetchMode,
                       lowThresholdPercent: lowThresholdPercent,
                       notificationsEnabled: notificationsEnabled)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Thread-safe snapshot the coordinator reads from background actors.
final class RuntimeConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _accounts: [Account] = []
    private var _fetchMode: FetchMode = .auto
    private var _lowThresholdPercent: Double = 10
    private var _notificationsEnabled = false

    var accounts: [Account] { lock.withLock { _accounts } }
    var fetchMode: FetchMode { lock.withLock { _fetchMode } }
    var lowThresholdPercent: Double { lock.withLock { _lowThresholdPercent } }
    var notificationsEnabled: Bool { lock.withLock { _notificationsEnabled } }

    func update(accounts: [Account], fetchMode: FetchMode, lowThresholdPercent: Double,
                notificationsEnabled: Bool) {
        lock.withLock {
            _accounts = accounts
            _fetchMode = fetchMode
            _lowThresholdPercent = lowThresholdPercent
            _notificationsEnabled = notificationsEnabled
        }
    }
}
