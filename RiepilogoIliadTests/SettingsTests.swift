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

    /// A SIM added after the coordinator has already hydrated must reach the
    /// actors' mirror, not just the UI: the coordinator reads `runtime.accounts`,
    /// so a missing sync would make the new SIM invisible to the very next cycle.
    func testRuntimeSeesAccountsAddedAfterInit() {
        let settings = AppSettings(defaults: freshDefaults())
        let account = Account(name: "SIM 1", username: "u", renewalDay: nil)
        settings.accounts = [account]
        settings.accounts.append(Account(name: "SIM 2", username: "u2", renewalDay: nil))
        XCTAssertEqual(settings.runtime.accounts.map(\.name), ["SIM 1", "SIM 2"])

        settings.accounts.removeAll { $0.name == "SIM 1" }
        XCTAssertEqual(settings.runtime.accounts.map(\.name), ["SIM 2"],
                       "a removal must be visible to the coordinator too")
    }

    /// The picker is bound to `refreshInterval`, so every value it can produce has
    /// to be one the floor accepts — otherwise a `Picker` bound to a value
    /// outside its tag list shows no selection at all.
    func testEveryPickerTagSurvivesTheFloor() {
        let settings = AppSettings(defaults: freshDefaults())
        for tag in refreshIntervalTags {
            settings.refreshInterval = tag
            XCTAssertEqual(settings.refreshInterval, tag)
        }
        XCTAssertEqual(refreshIntervalTags.first, 3600, "the picker must offer the floor itself")
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

    /// The background actors read `runtime`, never `AppSettings` directly, so a
    /// missing sync would leave them on the launch-time values forever.
    func testRuntimeMirrorsSettingsOnEveryChange() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertTrue(settings.runtime.accounts.isEmpty)
        XCTAssertEqual(settings.runtime.fetchMode, .auto)
        XCTAssertEqual(settings.runtime.lowThresholdPercent, 10)
        XCTAssertFalse(settings.runtime.notificationsEnabled)

        let account = Account(name: "SIM 1", username: "u", renewalDay: 17)
        settings.accounts = [account]
        settings.fetchMode = .safari
        settings.lowThresholdPercent = 25
        settings.notificationsEnabled = true

        XCTAssertEqual(settings.runtime.accounts, [account])
        XCTAssertEqual(settings.runtime.fetchMode, .safari)
        XCTAssertEqual(settings.runtime.lowThresholdPercent, 25)
        XCTAssertTrue(settings.runtime.notificationsEnabled)
    }
}
