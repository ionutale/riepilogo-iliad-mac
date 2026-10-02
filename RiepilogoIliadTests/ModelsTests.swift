import XCTest
@testable import RiepilogoIliad

final class ModelsTests: XCTestCase {
    func testErrorClassification() {
        XCTAssertTrue(IliadError.network("x").isNetwork)
        XCTAssertFalse(IliadError.auth("x").isNetwork)
        XCTAssertFalse(IliadError.parse("x").isNetwork)
        XCTAssertFalse(IliadError.safariJSSetting("x").isNetwork)
    }

    func testFetchModeLabels() {
        XCTAssertEqual(FetchMode.allCases.count, 3)
        XCTAssertFalse(FetchMode.auto.label.isEmpty)
    }
}
