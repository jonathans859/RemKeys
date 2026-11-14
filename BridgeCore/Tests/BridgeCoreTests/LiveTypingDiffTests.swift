import XCTest
import BridgeCore

/// Virtual Input's live typing: what to send when the field changes.
final class LiveTypingDiffTests: XCTestCase {
    private func diff(_ old: String, _ new: String) -> (Int, String) {
        let d = LiveTypingDiff(from: old, to: new)
        return (d.backspaces, String(d.typed))
    }

    func testAppending() {
        XCTAssertTrue(diff("hel", "hello") == (0, "lo"))
        XCTAssertTrue(diff("", "hi") == (0, "hi"))
    }

    func testBackspacingOffTheEnd() {
        XCTAssertTrue(diff("hello", "hel") == (2, ""))
        XCTAssertTrue(diff("hi", "") == (2, ""))
    }

    func testNoChange() {
        XCTAssertTrue(LiveTypingDiff(from: "same", to: "same").isEmpty)
        XCTAssertTrue(LiveTypingDiff(from: "", to: "").isEmpty)
    }

    func testEditInTheMiddleRetypesTheTail() {
        XCTAssertTrue(diff("hello", "hallo") == (4, "allo"))
        XCTAssertTrue(diff("abc", "aXbc") == (2, "Xbc"))
    }

    func testAutocorrectReplacingTheLastWord() {
        XCTAssertTrue(diff("I teh", "I the ") == (2, "he "))
    }

    func testWholeFieldReplaced() {
        XCTAssertTrue(diff("abc", "xyz") == (3, "xyz"))
    }

    /// A combining mark joins the previous character: one Backspace removes
    /// the old one, then the combined character is typed.
    func testCombiningMarkReplacesTheCharacterItJoins() {
        XCTAssertTrue(diff("cafe", "cafe\u{301}") == (1, "e\u{301}"))
    }

    func testEmojiModifierReplacesTheEmoji() {
        XCTAssertTrue(diff("ok 👍", "ok 👍🏽") == (1, "👍🏽"))
    }

    func testDeletingAnEmojiIsOneBackspace() {
        XCTAssertTrue(diff("hi 👨‍👩‍👧", "hi ") == (1, ""))
        XCTAssertTrue(diff("🇩🇪x", "") == (2, ""))
    }

    func testCanonicallyEqualTextIsNoChange() {
        // Precomposed é and e + combining acute are the same text.
        XCTAssertTrue(LiveTypingDiff(from: "caf\u{E9}", to: "cafe\u{301}").isEmpty)
    }
}
