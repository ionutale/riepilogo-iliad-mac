import Foundation
import Observation

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

    var accounts: [Account] {
        didSet { persist(accounts, forKey: Keys.accounts) }
    }
    var refreshInterval: TimeInterval {
        didSet {
            if refreshInterval < 3600 { refreshInterval = 3600 }
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
        }
    }
    var fetchMode: FetchMode {
        didSet { defaults.set(fetchMode.rawValue, forKey: Keys.fetchMode) }
    }
    var lowThresholdPercent: Double {
        didSet { defaults.set(lowThresholdPercent, forKey: Keys.lowThresholdPercent) }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
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
