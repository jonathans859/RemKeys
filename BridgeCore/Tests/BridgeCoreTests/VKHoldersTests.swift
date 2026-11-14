import XCTest
@testable import BridgeCore

final class VKHoldersTests: XCTestCase {
    private var holders = VKHolders<String>()
    private let shift: UInt16 = 0x10
    private let control: UInt16 = 0x11

    func testOneKeySendsDownAndUp() {
        XCTAssertTrue(holders.press("lshift", vk: shift))
        XCTAssertEqual(holders.release("lshift"), shift)
        XCTAssertTrue(holders.isEmpty)
    }

    func testTwoKeysOnOneVKReleaseOnlyWhenBothAreUp() {
        XCTAssertTrue(holders.press("lshift", vk: shift))
        XCTAssertFalse(holders.press("rshift", vk: shift), "second key must not send a second down")
        XCTAssertNil(holders.release("lshift"), "Shift is still held by the other key")
        XCTAssertEqual(holders.release("rshift"), shift)
        XCTAssertTrue(holders.isEmpty)
    }

    func testReleaseOrderDoesNotMatter() {
        holders.press("control", vk: control)
        holders.press("command", vk: control)
        XCTAssertNil(holders.release("command"))
        XCTAssertEqual(holders.release("control"), control)
    }

    func testAutorepeatFromTheHolderResendsTheDown() {
        XCTAssertTrue(holders.press("a", vk: 0x41))
        XCTAssertTrue(holders.press("a", vk: 0x41))
        XCTAssertEqual(holders.release("a"), 0x41)
    }

    func testAutorepeatWhileAnotherKeyHoldsTheVK() {
        holders.press("return", vk: 0x0D)
        XCTAssertFalse(holders.press("enter", vk: 0x0D))
        XCTAssertTrue(holders.press("enter", vk: 0x0D), "a repeat of a held VK is still a repeat")
        XCTAssertNil(holders.release("enter"))
        XCTAssertEqual(holders.release("return"), 0x0D)
    }

    func testReleaseUsesTheVKFromPressTime() {
        // The modifier mapping changed mid-hold: the up must match the down.
        holders.press("lcommand", vk: control)
        XCTAssertFalse(holders.press("lcommand", vk: 0x5B), "a repeat can't move the key to a new VK")
        XCTAssertEqual(holders.release("lcommand"), control)
    }

    func testReleaseWithNoPressSendsNothing() {
        XCTAssertNil(holders.release("lshift"))
    }

    func testKeysOnDifferentVKsAreIndependent() {
        holders.press("lshift", vk: shift)
        XCTAssertTrue(holders.press("control", vk: control))
        XCTAssertEqual(holders.release("lshift"), shift)
        XCTAssertEqual(holders.release("control"), control)
    }

    func testForgetLetsTheOtherHolderCarryTheVK() {
        holders.press("lshift", vk: shift)
        holders.press("rshift", vk: shift)
        holders.forget("lshift")
        XCTAssertFalse(holders.isHeld("lshift"))
        XCTAssertEqual(holders.release("rshift"), shift)
        XCTAssertTrue(holders.isEmpty)
    }

    func testRemoveAllForgetsEverything() {
        holders.press("lshift", vk: shift)
        holders.press("rshift", vk: shift)
        holders.removeAll()
        XCTAssertTrue(holders.isEmpty)
        XCTAssertNil(holders.release("rshift"))
        XCTAssertTrue(holders.press("rshift", vk: shift))
    }
}
