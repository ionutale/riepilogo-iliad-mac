import XCTest
@testable import RiepilogoIliad

@MainActor
final class SettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertEqual(settings.refreshInterval, 4 * 3600)
        XCTAssertEqual(settings.fetchMode, .auto)
        XCTAssertEqual(settings.lowThresholdPercent, 10)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertTrue(settings.accounts.isEmpty)
    }

    func testRoundTripAndIntervalFloor() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accounts = [Account(name: "SIM 1", username: "u", renewalDay: 17)]
        settings.fetchMode = .safari
        settings.refreshInterval = 60 // clamped to 1h
        settings.lowThresholdPercent = 5

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.accounts[0].name, "SIM 1")
        XCTAssertEqual(reloaded.accounts[0].renewalDay, 17)
        XCTAssertEqual(reloaded.fetchMode, .safari)
        XCTAssertEqual(reloaded.refreshInterval, 3600)
        XCTAssertEqual(reloaded.lowThresholdPercent, 5)
    }
}
