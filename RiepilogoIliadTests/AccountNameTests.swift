import XCTest
@testable import RiepilogoIliad

final class AccountNameTests: XCTestCase {
    private func account(_ name: String) -> Account {
        Account(name: name, username: "user@example.com", renewalDay: nil)
    }

    func testBlankNameIsRejected() {
        XCTAssertEqual(AccountName.validate("", existing: []), AccountName.emptyMessage)
    }

    func testWhitespaceOnlyNameIsRejected() {
        // A name that trims to nothing cannot key an `Entry` or a `readings`
        // series: the card would be nameless and the History picker entry useless.
        XCTAssertEqual(AccountName.validate("   ", existing: []), AccountName.emptyMessage)
        XCTAssertEqual(AccountName.validate("\t\n ", existing: []), AccountName.emptyMessage)
        XCTAssertEqual(AccountName.validate("\u{00A0}", existing: []), AccountName.emptyMessage,
                       "a non-breaking space is whitespace too")
    }

    /// Two SIMs named `SIM 1` — the editor's own placeholder — collapse into one
    /// dictionary key: one card instead of two, one card's worth in the totals,
    /// and both accounts' readings interleaved under a single history series.
    func testDuplicateNameIsRejected() {
        let existing = [account("SIM 1"), account("SIM 2")]
        XCTAssertEqual(AccountName.validate("SIM 1", existing: existing), AccountName.duplicateMessage)
    }

    /// Names are labels, not identifiers: to a human `sim 1` and `SIM 1` are the
    /// same SIM, and letting both exist would reproduce the merge silently.
    func testDuplicateIsCaseInsensitive() {
        let existing = [account("SIM 1")]
        XCTAssertEqual(AccountName.validate("sim 1", existing: existing), AccountName.duplicateMessage)
        XCTAssertEqual(AccountName.validate("sIm 1", existing: existing), AccountName.duplicateMessage)
        XCTAssertEqual(AccountName.validate("SIM 1", existing: [account("sim 1")]),
                       AccountName.duplicateMessage)
    }

    /// Surrounding whitespace must not be a way to sneak a third spelling of an
    /// existing name past the check.
    func testSurroundingWhitespaceDoesNotHideADuplicate() {
        let existing = [account("SIM 1")]
        XCTAssertEqual(AccountName.validate("  SIM 1  ", existing: existing),
                       AccountName.duplicateMessage)
    }

    /// Re-saving a SIM without renaming it is the common case; the account's own
    /// id must be excluded or every edit would be rejected.
    func testEditingAnAccountMayKeepItsOwnName() {
        let existing = [account("SIM 1")]
        XCTAssertNil(AccountName.validate("SIM 1", existing: existing, excludingID: existing[0].id))
        // ... including a re-typed one that differs only by case or padding.
        XCTAssertNil(AccountName.validate("  sim 1 ", existing: existing, excludingID: existing[0].id))
    }

    /// The check must not see the edited account as a duplicate of a *sibling*:
    /// excluding one id cannot excuse a collision with another.
    func testEditingStillRejectsAnotherAccountsName() {
        let first = account("SIM 1")
        let second = account("SIM 2")
        XCTAssertEqual(AccountName.validate("SIM 2", existing: [first, second], excludingID: first.id),
                       AccountName.duplicateMessage)
    }

    func testDistinctNamesAreAccepted() {
        let existing = [account("SIM 1"), account("SIM 2")]
        XCTAssertNil(AccountName.validate("SIM 3", existing: existing))
        XCTAssertNil(AccountName.validate("SIM 10", existing: existing))
        // Substring similarity is not a collision: the key is the whole name.
        XCTAssertNil(AccountName.validate("SIM 1 b", existing: existing))
    }

    func testNormalizedTrimsSurroundingWhitespace() {
        XCTAssertEqual(AccountName.normalized("  SIM 1 \n"), "SIM 1")
        XCTAssertEqual(AccountName.normalized("   "), "")
    }
}
