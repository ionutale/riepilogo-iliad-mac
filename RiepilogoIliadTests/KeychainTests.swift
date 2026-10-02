import XCTest
@testable import RiepilogoIliad

final class KeychainTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        XCTAssertNil(try store.password(for: id))
        try store.setPassword("segreta", for: id)
        XCTAssertEqual(try store.password(for: id), "segreta")
        try store.deletePassword(for: id)
        XCTAssertNil(try store.password(for: id))
    }
}
