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
}
