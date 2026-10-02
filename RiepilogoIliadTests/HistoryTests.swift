import XCTest
@testable import RiepilogoIliad

final class HistoryTests: XCTestCase {
    func testDailyDedupeKeepsLatestPerLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let day1a = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 8))!
        let day1b = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 20))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!

        func reading(_ at: Date, _ remaining: Double) -> Reading {
            let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: 10,
                                   renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
            return Reading.success(account: "A", data: data, fetchedAt: at)
        }

        let points = dailyHistoryPoints(
            readings: [reading(day1a, 9), reading(day1b, 8), reading(day2, 7)],
            timeZone: calendar.timeZone)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].remainingGB, 8) // latest of day 1
        XCTAssertEqual(points[1].remainingGB, 7)
    }
}