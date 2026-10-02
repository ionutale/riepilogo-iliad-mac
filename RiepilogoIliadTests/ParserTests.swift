import XCTest
@testable import RiepilogoIliad

final class ParserTests: XCTestCase {
    private let now = dateOnly(y: 2026, m: 10, d: 2)

    private func fixture(_ name: String) throws -> String {
        let url = Bundle(for: ParserTests.self).url(forResource: name, withExtension: "html")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testStandardFixture() throws {
        let data = try parseAccountPage(html: fixture("standard"), now: now, renewalDay: nil)
        XCTAssertEqual(data.usedGB, 42.10)
        XCTAssertEqual(data.allowanceGB, 100)
        XCTAssertEqual(data.remainingGB, 57.9)
        XCTAssertEqual(data.creditEUR, 12.34)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 10, d: 17))
        XCTAssertEqual(data.periodStart, dateOnly(y: 2026, m: 9, d: 17))
        XCTAssertEqual(data.periodEnd, dateOnly(y: 2026, m: 10, d: 16))
        XCTAssertEqual(data.phoneNumber, "3511234567")
        XCTAssertEqual(data.offerName, "iliad voLTE 100GB")
    }

    func testCommaAndMBUnits() throws {
        let data = try parseAccountPage(html: fixture("comma_mb"), now: now, renewalDay: nil)
        XCTAssertEqual(data.usedGB, 0.95)
        XCTAssertEqual(data.allowanceGB, 2)
        XCTAssertEqual(data.remainingGB, 1.05)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 11, d: 3))
    }

    func testPeriodFallbackAndGenericOfferFiltered() throws {
        let data = try parseAccountPage(html: fixture("period_fallback"), now: now, renewalDay: nil)
        XCTAssertEqual(data.remainingGB, 17.5)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 10, d: 30))
        XCTAssertEqual(data.offerName, "")
    }

    func testLoginPageIsParseError() throws {
        XCTAssertThrowsError(try parseAccountPage(html: fixture("login"), now: now, renewalDay: nil)) { error in
            guard case IliadError.parse = error else { return XCTFail("got \(error)") }
        }
    }

    func testOfferScanningSkipsGenericLabels() throws {
        let data = try parseAccountPage(html: fixture("offerta"), now: now, renewalDay: nil)
        XCTAssertEqual(data.offerName, "GIGA 200")
    }

    func testRenewalInference() throws {
        let base = #"<html><body><span class="red">1 GB / 10 GB</span>"#
        let textual = try parseAccountPage(html: base + "<p>Si rinnova il 17 ottobre.</p></body></html>", now: now, renewalDay: nil)
        XCTAssertEqual(textual.renewalDate, dateOnly(y: 2026, m: 10, d: 17))

        let past = try parseAccountPage(html: base + "<p>Si rinnova il 1 settembre.</p></body></html>", now: now, renewalDay: nil)
        XCTAssertEqual(past.renewalDate, dateOnly(y: 2027, m: 9, d: 1))

        let override = try parseAccountPage(html: base + "</body></html>", now: now, renewalDay: 17)
        XCTAssertEqual(override.renewalDate, dateOnly(y: 2026, m: 10, d: 17))

        let nextMonth = try parseAccountPage(html: base + "</body></html>", now: now, renewalDay: 1)
        XCTAssertEqual(nextMonth.renewalDate, dateOnly(y: 2026, m: 11, d: 1))
    }

    func testNumberSeparators() {
        XCTAssertEqual(parseNumber("42,10"), 42.10)
        XCTAssertEqual(parseNumber("43.2"), 43.2)
        XCTAssertEqual(parseNumber("1.234,56"), 1234.56)
        XCTAssertEqual(parseNumber("1,234.56"), 1234.56)
        XCTAssertEqual(parseNumber("100"), 100)
    }

    func testSizeToGB() {
        for (unit, factor) in [("B", 1e-9), ("KB", 1e-6), ("MB", 1e-3), ("GB", 1.0), ("TB", 1e3)] {
            XCTAssertEqual(sizeToGB(2, unit: unit), 2 * factor, accuracy: factor * 1e-12)
        }
    }

    func testEmptyPageIsParseError() throws {
        XCTAssertThrowsError(try parseAccountPage(html: "<html><body><p>niente</p></body></html>", now: dateOnly(y: 2026, m: 10, d: 2), renewalDay: nil)) { error in
            guard case IliadError.parse = error else { return XCTFail("got \(error)") }
        }
    }
}
