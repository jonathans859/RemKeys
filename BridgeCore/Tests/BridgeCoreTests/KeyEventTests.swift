import XCTest
@testable import BridgeCore

final class KeyEventTests: XCTestCase {
    func testWireLineFormat() {
        XCTAssertEqual(KeyEvent(vk: 0x41, pressed: true).wireLine, "key 65 pressed=1\n")
        XCTAssertEqual(KeyEvent(vk: 0x41, pressed: false).wireLine, "key 65 pressed=0\n")
    }

    func testRoundTrip() {
        for vk in [VK.a, VK.f11, VK.numpad0, VK.oem102, VK.lwin] {
            for pressed in [true, false] {
                let event = KeyEvent(vk: vk, pressed: pressed)
                let parsed = KeyEvent.parse(event.wireLine)
                XCTAssertEqual(parsed, event)
            }
        }
    }

    func testParseTolerantOfCRLFAndWhitespace() {
        XCTAssertEqual(KeyEvent.parse("key 65 pressed=1\r\n"), KeyEvent(vk: 65, pressed: true))
        XCTAssertEqual(KeyEvent.parse("  key   65   pressed=0  "), KeyEvent(vk: 65, pressed: false))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(KeyEvent.parse(""))
        XCTAssertNil(KeyEvent.parse("hello world foo"))
        XCTAssertNil(KeyEvent.parse("key abc pressed=1"))
        XCTAssertNil(KeyEvent.parse("key 65 pressed=2"))
        XCTAssertNil(KeyEvent.parse("key 65"))
    }
}
