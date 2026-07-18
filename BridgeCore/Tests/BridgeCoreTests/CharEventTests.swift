import XCTest
@testable import BridgeCore

final class CharEventTests: XCTestCase {
    func testWireLineFormat() {
        XCTAssertEqual(CharEvent(scalar: "a").wireLine, "char 97\n")
        XCTAssertEqual(CharEvent(scalar: "ü").wireLine, "char 252\n")
        XCTAssertEqual(CharEvent(scalar: "€").wireLine, "char 8364\n")
    }

    func testRoundTrip() {
        for scalar: Unicode.Scalar in ["a", "Z", "ü", "€", "🙂", " "] {
            let event = CharEvent(scalar: scalar)
            XCTAssertEqual(CharEvent.parse(event.wireLine), event)
        }
    }

    func testParseTolerantOfCRLFAndWhitespace() {
        XCTAssertEqual(CharEvent.parse("char 252\r\n"), CharEvent(scalar: "ü"))
        XCTAssertEqual(CharEvent.parse("  char   97  "), CharEvent(scalar: "a"))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(CharEvent.parse(""))
        XCTAssertNil(CharEvent.parse("char"))
        XCTAssertNil(CharEvent.parse("char abc"))
        XCTAssertNil(CharEvent.parse("char 97 extra"))
        XCTAssertNil(CharEvent.parse("key 97 pressed=1"))
        // Surrogate code points are not valid Unicode scalars.
        XCTAssertNil(CharEvent.parse("char 55296"))
        XCTAssertNil(CharEvent.parse("char 4294967295"))
    }

    func testKeyAndCharLinesAreDisjoint() {
        // A char line must never parse as a key event and vice versa.
        XCTAssertNil(KeyEvent.parse(CharEvent(scalar: "a").wireLine))
        XCTAssertNil(CharEvent.parse(KeyEvent(vk: VK.a, pressed: true).wireLine))
    }
}

final class USCharVKTests: XCTestCase {
    func testLettersCaseDecidesShift() {
        XCTAssertEqual(USCharVK.key(for: "a")?.vk, VK.a)
        XCTAssertEqual(USCharVK.key(for: "a")?.shift, false)
        XCTAssertEqual(USCharVK.key(for: "Z")?.vk, VK.z)
        XCTAssertEqual(USCharVK.key(for: "Z")?.shift, true)
    }

    func testDigitsAndShiftedSymbols() {
        XCTAssertEqual(USCharVK.key(for: "7")?.vk, VK.d7)
        XCTAssertEqual(USCharVK.key(for: "7")?.shift, false)
        XCTAssertEqual(USCharVK.key(for: "@")?.vk, VK.d2)
        XCTAssertEqual(USCharVK.key(for: "@")?.shift, true)
        XCTAssertEqual(USCharVK.key(for: "{")?.vk, VK.oem4)
        XCTAssertEqual(USCharVK.key(for: "{")?.shift, true)
    }

    func testWhitespaceKeys() {
        XCTAssertEqual(USCharVK.key(for: " ")?.vk, VK.space)
        XCTAssertEqual(USCharVK.key(for: "\n")?.vk, VK.return)
        XCTAssertEqual(USCharVK.key(for: "\t")?.vk, VK.tab)
    }

    func testNonUSCharactersReturnNil() {
        XCTAssertNil(USCharVK.key(for: "ü"))
        XCTAssertNil(USCharVK.key(for: "€"))
        XCTAssertNil(USCharVK.key(for: "🙂"))
    }
}
