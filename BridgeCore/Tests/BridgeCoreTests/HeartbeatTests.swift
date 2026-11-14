import XCTest
@testable import BridgeCore

/// The `alive` lease line, mirrored by `WireProtocol.IsAlive` in the agent.
final class HeartbeatTests: XCTestCase {
    func testWireLine() {
        XCTAssertEqual(Heartbeat.wireLine, "alive\n")
        XCTAssertEqual(Heartbeat.wireData, Data("alive\n".utf8))
    }

    func testParseRoundTripsAndTolerates() {
        XCTAssertTrue(Heartbeat.parse(Heartbeat.wireLine))
        XCTAssertTrue(Heartbeat.parse("  alive\r\n"))
    }

    func testParseRejectsAnythingElse() {
        XCTAssertFalse(Heartbeat.parse(""))
        XCTAssertFalse(Heartbeat.parse("alive 1"))
        XCTAssertFalse(Heartbeat.parse("Alive"))
        XCTAssertFalse(Heartbeat.parse("key 65 pressed=1"))
        XCTAssertNil(KeyEvent.parse("alive"), "never mistaken for a key line")
        XCTAssertNil(CharEvent.parse("alive"))
    }
}
