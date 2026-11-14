import XCTest
@testable import BridgeCore

/// Keystrokes typed while there is no live connection: reported as not sent,
/// never remembered as held, and cued once per burst. No transport is ever
/// made — with no target address, turning forwarding on fails straight away.
@MainActor
final class DroppedKeystrokeTests: XCTestCase {
    private var settings: AppSettings!
    private var client: BridgeClient!
    private var cues = 0

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "DroppedKeystrokeTests")!
        defaults.removePersistentDomain(forName: "DroppedKeystrokeTests")
        settings = AppSettings(defaults: defaults)
        client = BridgeClient(settings: settings, transportFactory: { _, _ in
            preconditionFailure("no target address, so no transport")
        })
        cues = 0
        client.keystrokeWasDropped = { [unowned self] in self.cues += 1 }
    }

    func testNothingIsSentOrCuedWhileForwardingIsOff() {
        XCTAssertFalse(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertFalse(client.sendCharacter("a"))
        XCTAssertEqual(cues, 0)
    }

    func testDroppedPressIsReportedAndCued() {
        client.forwardingEnabled = true
        XCTAssertFalse(client.status.isConnected)
        XCTAssertFalse(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertEqual(cues, 1)
    }

    func testBurstOfDropsCuesOnce() {
        client.forwardingEnabled = true
        for _ in 0..<20 {
            client.sendKey(vk: VK.a, pressed: true)
            client.sendKey(vk: VK.a, pressed: false)
        }
        for scalar in "hello".unicodeScalars { client.sendCharacter(scalar) }
        XCTAssertEqual(cues, 1)
    }

    func testEachDropCuesOnceTheIntervalHasPassed() {
        client.dropCueInterval = .zero
        client.forwardingEnabled = true
        client.sendKey(vk: VK.a, pressed: true)
        client.sendCharacter("b")
        XCTAssertEqual(cues, 2)
    }

    func testReleasesNeverCue() {
        client.dropCueInterval = .zero
        client.forwardingEnabled = true
        XCTAssertFalse(client.sendKey(vk: VK.menu, pressed: false))
        client.releaseHeldKeys()
        XCTAssertEqual(cues, 0)
    }

    func testDisabledSettingSilencesTheCue() {
        settings.dropCueEnabled = false
        client.forwardingEnabled = true
        XCTAssertFalse(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertEqual(cues, 0)
    }
}
