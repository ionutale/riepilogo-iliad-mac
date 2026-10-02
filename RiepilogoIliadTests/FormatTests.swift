import XCTest
@testable import RiepilogoIliad

final class FormatTests: XCTestCase {
    func testFormatGB() {
        XCTAssertEqual(formatGB(43.25), "43,2 GB")
        XCTAssertEqual(formatGB(100), "100 GB")
        XCTAssertEqual(formatGB(0), "0 GB")
    }

    func testBarClass() {
        XCTAssertEqual(barClass(usedPct: 0), "ok")
        XCTAssertEqual(barClass(usedPct: 69.9), "ok")
        XCTAssertEqual(barClass(usedPct: 70), "warn")
        XCTAssertEqual(barClass(usedPct: 90), "warn")
        XCTAssertEqual(barClass(usedPct: 90.1), "danger")
    }

    func testFormatDays() {
        XCTAssertEqual(formatDays(-2), "2 giorni fa")
        XCTAssertEqual(formatDays(0), "oggi")
        XCTAssertEqual(formatDays(1), "domani")
        XCTAssertEqual(formatDays(6), "tra 6 giorni")
    }

    func testFormatDate() {
        XCTAssertEqual(formatDate(dateOnly(y: 2026, m: 10, d: 7)), "07/10/2026")
    }

    /// The popover footer's "last update" renders through this (spec §8), so its
    /// shape is user-visible: zero-padded day/month/year and 24-hour time in Rome
    /// local time, not UTC.
    func testFormatDateTime() {
        XCTAssertEqual(formatDateTime(calendarDate(y: 2026, m: 10, d: 7, h: 14, min: 5)),
                       "07/10/2026 14:05")
        XCTAssertEqual(formatDateTime(calendarDate(y: 2026, m: 1, d: 1, h: 9, min: 0)),
                       "01/01/2026 09:00")
    }

    /// The footer renders in `Europe/Rome`, not UTC, and the two differ by an hour
    /// or two depending on the season — so a value read from the UTC-based
    /// `Timestamp` storage would be displayed at the wrong hour half the year.
    func testFormatDateTimeUsesRomeNotUTC() {
        // Midnight UTC is 02:00 in Rome under CEST.
        XCTAssertEqual(formatDateTime(dateOnly(y: 2026, m: 7, d: 7)), "07/07/2026 02:00")
        // ...and 01:00 under CET.
        XCTAssertEqual(formatDateTime(dateOnly(y: 2026, m: 1, d: 7)), "07/01/2026 01:00")
    }

    private func calendarDate(y: Int, m: Int, d: Int, h: Int, min: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = romeTimeZone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Low-data signal

    /// `isLowData` drives the orange tint on the remaining figure. It is a
    /// *remaining* threshold, independent of `barClass`'s *used* one, and the
    /// boundary is inclusive because "at or below the threshold" is what the
    /// notification policy uses too.
    func testIsLowData() {
        XCTAssertTrue(isLowData(remaining: 5, allowance: 100, threshold: 10))
        XCTAssertTrue(isLowData(remaining: 10, allowance: 100, threshold: 10), "inclusive boundary")
        XCTAssertTrue(isLowData(remaining: 0, allowance: 100, threshold: 10))
        XCTAssertFalse(isLowData(remaining: 10.1, allowance: 100, threshold: 10))
        XCTAssertFalse(isLowData(remaining: 50, allowance: 100, threshold: 10))
        // Nothing to compare against: an unknown allowance is not "low".
        XCTAssertFalse(isLowData(remaining: 0, allowance: 0, threshold: 10))
    }

    func testBarClassAndIsLowDataAreIndependentSignals() {
        // 85% used, 15% remaining: yellow bar (70-90% used) but not yet low.
        XCTAssertEqual(barClass(usedPct: 85), "warn")
        XCTAssertFalse(isLowData(remaining: 15, allowance: 100, threshold: 10))
        // 95% used: red bar, and low data at a 10% threshold.
        XCTAssertEqual(barClass(usedPct: 95), "danger")
        XCTAssertTrue(isLowData(remaining: 5, allowance: 100, threshold: 10))
    }
}
