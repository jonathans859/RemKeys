import XCTest
import BridgeCore

/// The iOS two-source merge: `pressesBegan` and the GameController HID layer
/// both report the same keyboard, and each key must go out exactly once.
final class KeyHoldersTests: XCTestCase {
    enum Source { case uiKit, hid }
    private var holders = KeyHolders<Int, Source>()
    private let a = 4, cmd = 227

    func testOneSourceAloneCarriesTheKey() {
        XCTAssertTrue(holders.press(a, from: .uiKit))
        XCTAssertTrue(holders.isHeld(a))
        XCTAssertEqual(holders.release(a, from: .uiKit), .lastHolderReleased)
        XCTAssertFalse(holders.isHeld(a))
        XCTAssertTrue(holders.isEmpty)
    }

    func testBothSourcesCollapseIntoOneDownAndOneUp() {
        XCTAssertTrue(holders.press(a, from: .hid))     // sends the down
        XCTAssertFalse(holders.press(a, from: .uiKit))  // duplicate, swallowed
        XCTAssertEqual(holders.release(a, from: .hid), .stillHeld)
        XCTAssertEqual(holders.release(a, from: .uiKit), .lastHolderReleased)
    }

    func testReleaseOrderDoesNotMatter() {
        holders.press(a, from: .uiKit)
        holders.press(a, from: .hid)
        XCTAssertEqual(holders.release(a, from: .uiKit), .stillHeld)
        XCTAssertEqual(holders.release(a, from: .hid), .lastHolderReleased)
    }

    func testReleaseWithNoPressIsNotHeld() {
        // The key went down while forwarding was off: the PC never saw it.
        XCTAssertEqual(holders.release(a, from: .uiKit), .wasNotHeld)
        holders.press(a, from: .uiKit)
        holders.release(a, from: .uiKit)
        XCTAssertEqual(holders.release(a, from: .hid), .wasNotHeld)
    }

    func testRepeatedPressFromOneSourceIsNotASecondDown() {
        XCTAssertTrue(holders.press(a, from: .uiKit))
        XCTAssertFalse(holders.press(a, from: .uiKit))
        XCTAssertEqual(holders.release(a, from: .uiKit), .lastHolderReleased)
    }

    func testReleaseFromTheSourceThatMissedTheDown() {
        // HID went live mid-press: it reports the up but never saw the down.
        holders.press(a, from: .uiKit)
        XCTAssertEqual(holders.release(a, from: .hid), .stillHeld)
        XCTAssertEqual(holders.release(a, from: .uiKit), .lastHolderReleased)
    }

    func testKeysAreIndependent() {
        holders.press(cmd, from: .hid)
        XCTAssertTrue(holders.press(a, from: .hid))
        XCTAssertEqual(holders.release(a, from: .hid), .lastHolderReleased)
        XCTAssertTrue(holders.isHeld(cmd))
        XCTAssertEqual(Set(holders.heldKeys), [cmd])
    }

    func testForgetDropsEveryHolder() {
        holders.press(a, from: .uiKit)
        holders.press(a, from: .hid)
        holders.forget(a)
        XCTAssertEqual(holders.release(a, from: .hid), .wasNotHeld)
        XCTAssertTrue(holders.press(a, from: .uiKit), "the next press is a fresh down")
    }

    func testRemoveAllForgetsEverything() {
        holders.press(a, from: .uiKit)
        holders.press(cmd, from: .hid)
        holders.removeAll()
        XCTAssertTrue(holders.isEmpty)
        XCTAssertTrue(holders.press(a, from: .hid))
    }

    func testRecordTracksPhysicalState() {
        holders.record(a, pressed: true, from: .uiKit)
        holders.record(a, pressed: true, from: .hid)
        holders.record(a, pressed: false, from: .uiKit)
        XCTAssertTrue(holders.isHeld(a))
        holders.record(a, pressed: false, from: .hid)
        XCTAssertFalse(holders.isHeld(a))
        holders.record(a, pressed: false, from: .hid)  // stray up: harmless
        XCTAssertTrue(holders.isEmpty)
    }
}
