import XCTest
@testable import RiepilogoIliad

/// Stands in for `SystemNotificationPoster`: the decider's delivery seam, so the
/// tests can assert what it was asked to announce without touching
/// `UNUserNotificationCenter`. Records the whole forwarded payload, so a decider
/// that loses the decision, the account or the reading is caught here.
private final class RecordingPoster: NotificationPosting, @unchecked Sendable {
    struct Posted: Equatable {
        var decision: NotificationDecision
        var accountID: UUID
        var accountName: String
        var remainingGB: Double?
    }

    private let lock = NSLock()
    private var _posted: [Posted] = []

    var posted: [Posted] { lock.withLock { _posted } }

    func post(_ decision: NotificationDecision, for account: Account, data: AccountData) async {
        lock.withLock {
            _posted.append(Posted(decision: decision, accountID: account.id,
                                  accountName: account.name, remainingGB: data.remainingGB))
        }
    }
}

final class NotificationsTests: XCTestCase {
    private let account = Account(name: "SIM 1", username: "u")
    private let decider = NotificationDecider()

    /// Scratch `UserDefaults` suites are per-test and removed in `tearDown`, so
    /// the gate's persisted state never leaks into another test or the real
    /// domain.
    private var scratchSuites: [String] = []

    override func tearDown() {
        for name in scratchSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        scratchSuites = []
        super.tearDown()
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "it.ionut.riepilogo-iliad.tests.gate.\(UUID().uuidString)"
        scratchSuites.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("scratch UserDefaults suite \(name) unavailable")
        }
        return defaults
    }

    private func data(remaining: Double?, allowance: Double? = 200) -> AccountData {
        AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: allowance,
                    renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
    }

    func testExhausted() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 0), account: account), .exhausted)
    }

    func testLowThreshold() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 15), account: account), .low)
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 30), account: account), .none)
    }

    func testRenewed() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 2), current: data(remaining: 195), account: account), .renewed)
    }

    func testRenewedBeatsLow() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 0), current: data(remaining: 195), account: account), .renewed)
    }

    func testNoPreviousMeansNoRenewed() {
        XCTAssertEqual(decider.decide(previous: nil, current: data(remaining: 195), account: account), .none)
    }

    // MARK: - Threshold and reading boundaries

    /// Exactly at the threshold counts as low (`<=`); a hundredth of a percent
    /// above it does not.
    func testLowThresholdBoundaryIsInclusive() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 20), account: account), .low)
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 20.5), account: account), .none)
    }

    /// A refill must clear *both* renewal conditions (`remaining > old + 1` and
    /// `remaining > old * 2`). `allowance: nil` disables the low branch so `.none`
    /// can only mean "not read as a renewal" — with the default 200 GB allowance
    /// both readings are below 10% and would decide `.low`.
    func testRenewalNeedsBothJumpConditions() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 5, allowance: nil),
                                      current: data(remaining: 6, allowance: nil), account: account), .none)
        XCTAssertEqual(decider.decide(previous: data(remaining: 5, allowance: nil),
                                      current: data(remaining: 10, allowance: nil), account: account), .none)
    }

    func testDisabledSuppressesEverything() {
        let silent = NotificationDecider(thresholdPercent: 10, enabled: { false })
        XCTAssertEqual(silent.decide(previous: data(remaining: 50), current: data(remaining: 0), account: account), .none)
    }

    func testIncompleteReadingsDecideNothing() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: nil), account: account), .none)
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 15, allowance: nil), account: account), .none)
    }

    // MARK: - Transition-based suppression

    func testGateAnnouncesOncePerStateChange() {
        let gate = NotificationGate(defaults: scratchDefaults())
        XCTAssertTrue(gate.shouldAnnounce(.low, for: account))
        XCTAssertFalse(gate.shouldAnnounce(.low, for: account))
        XCTAssertTrue(gate.shouldAnnounce(.exhausted, for: account))
        XCTAssertFalse(gate.shouldAnnounce(.exhausted, for: account))
        XCTAssertTrue(gate.shouldAnnounce(.renewed, for: account))
    }

    /// Relaunching must not re-announce a state the user has already seen.
    func testGatePersistsAcrossInstances() {
        let defaults = scratchDefaults()
        XCTAssertTrue(NotificationGate(defaults: defaults).shouldAnnounce(.low, for: account))
        let afterRelaunch = NotificationGate(defaults: defaults)
        XCTAssertFalse(afterRelaunch.shouldAnnounce(.low, for: account))
        XCTAssertTrue(afterRelaunch.shouldAnnounce(.exhausted, for: account))
    }

    // MARK: - Delivery seam

    /// The decider must forward the real payload, not just "something happened":
    /// a poster that received a fabricated reading would announce a wrong number.
    func testDeciderForwardsToInjectedPoster() async {
        let poster = RecordingPoster()
        let decider = NotificationDecider(thresholdPercent: 10, poster: poster)
        let current = data(remaining: 15)
        let decision = decider.decide(previous: data(remaining: 50), current: current, account: account)
        XCTAssertEqual(decision, .low)
        await decider.post(decision, account: account, data: current)
        XCTAssertEqual(poster.posted, [RecordingPoster.Posted(decision: .low,
                                                             accountID: account.id,
                                                             accountName: "SIM 1",
                                                             remainingGB: 15)])
    }

    func testDeciderDoesNotPostNone() async {
        let poster = RecordingPoster()
        let decider = NotificationDecider(thresholdPercent: 10, poster: poster)
        let decision = decider.decide(previous: data(remaining: 50), current: data(remaining: 30), account: account)
        XCTAssertEqual(decision, .none)
        await decider.post(decision, account: account, data: data(remaining: 30))
        XCTAssertEqual(poster.posted, [])
    }
}