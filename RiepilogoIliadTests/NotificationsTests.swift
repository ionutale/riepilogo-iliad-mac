import XCTest
@testable import RiepilogoIliad

final class NotificationsTests: XCTestCase {
    private let account = Account(name: "SIM 1", username: "u")
    private let decider = NotificationDecider()

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
}