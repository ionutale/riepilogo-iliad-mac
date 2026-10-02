import XCTest
@testable import RiepilogoIliad

final class DateUtilsTests: XCTestCase {
    func testDaysBetweenIgnoresDST() {
        let from = dateOnly(y: 2026, m: 10, d: 24)
        let to = dateOnly(y: 2026, m: 10, d: 27) // DST fall-back on the 25th
        XCTAssertEqual(daysBetween(from, to), 3)
        XCTAssertEqual(daysBetween(to, from), -3)
        XCTAssertEqual(daysBetween(from, from), 0)
    }

    func testTodayIsUTCMidnightOfRomeDate() {
        let today = today(in: TimeZone(identifier: "Europe/Rome")!)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utcCalendar.component(.hour, from: today), 0)
        XCTAssertEqual(utcCalendar.component(.minute, from: today), 0)
        XCTAssertEqual(utcCalendar.component(.second, from: today), 0)

        var romeCalendar = Calendar(identifier: .gregorian)
        romeCalendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let expected = romeCalendar.dateComponents([.year, .month, .day], from: Date())
        let actual = utcCalendar.dateComponents([.year, .month, .day], from: today)
        XCTAssertEqual(actual.year, expected.year)
        XCTAssertEqual(actual.month, expected.month)
        XCTAssertEqual(actual.day, expected.day)
    }
}
