import XCTest
@testable import BridgeCore

/// The client's connection lifecycle and reconnect rules, driven through a fake
/// transport and a hand-fired recovery timer. See CLAUDE.md, "The link can die
/// without saying so": rule 3, *the client rebuilds rather than waits*, is
/// what most of these pin down.
@MainActor
final class BridgeClientTransportTests: XCTestCase {
    private var settings: AppSettings!
    private var factory: FakeTransportFactory!
    private var sleeper: ManualSleeper!
    private var heartbeats: ManualSleeper!
    private var client: BridgeClient!
    private var statuses: [BridgeClient.ConnectionStatus] = []

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "BridgeClientTransportTests")!
        defaults.removePersistentDomain(forName: "BridgeClientTransportTests")
        settings = AppSettings(defaults: defaults)
        settings.targetHost = " 100.64.0.7 "
        settings.targetPort = 5391
        factory = FakeTransportFactory()
        sleeper = ManualSleeper()
        heartbeats = ManualSleeper()
        let factory = factory!, sleeper = sleeper!, heartbeats = heartbeats!
        client = BridgeClient(settings: settings,
                              transportFactory: { factory.make(host: $0, port: $1) },
                              sleep: { try await sleeper.sleep($0) },
                              heartbeatSleep: { try await heartbeats.sleep($0) })
        statuses = []
        client.statusDidChange = { [unowned self] status, _ in statuses.append(status) }
    }

    /// Turn forwarding on and bring the first connection up. The `alive`
    /// announcement every ready connection opens with is checked once, then
    /// dropped from `sent` so the other tests read only what they did.
    private func connectReady() -> FakeTransport {
        client.forwardingEnabled = true
        let transport = factory.latest!
        transport.deliver(.ready)
        XCTAssertEqual(transport.sent, ["alive"])
        transport.clearSent()
        return transport
    }

    // MARK: Connecting

    func testForwardingOnStartsOneTransportToTheTrimmedTarget() {
        client.forwardingEnabled = true
        XCTAssertEqual(factory.made.count, 1)
        let transport = factory.latest!
        XCTAssertTrue(transport.started)
        XCTAssertEqual(transport.host, "100.64.0.7")
        XCTAssertEqual(transport.port, 5391)
        XCTAssertEqual(client.status, .connecting)
        transport.deliver(.ready)
        XCTAssertEqual(client.status, .connected)
    }

    func testMissingAddressFailsWithoutATransport() {
        settings.targetHost = "   "
        client.forwardingEnabled = true
        XCTAssertTrue(factory.made.isEmpty)
        XCTAssertEqual(client.status, .failed("No target address set"))
    }

    func testOutOfRangePortFailsWithoutATransport() {
        for port in [0, -1, 70_000] {
            settings.targetPort = port
            client.connect()
            XCTAssertTrue(factory.made.isEmpty, "port \(port)")
            XCTAssertEqual(client.status, .failed("Invalid port"), "port \(port)")
        }
    }

    func testForwardingOffCancelsAndGoesIdle() {
        let transport = connectReady()
        client.forwardingEnabled = false
        XCTAssertTrue(transport.cancelled)
        XCTAssertEqual(client.status, .idle)
    }

    // MARK: Recovery

    func testFailureRebuildsAfterTwoSecondsWithoutFlickeringToConnecting() async {
        let first = connectReady()
        first.deliver(.failed("Connection reset by peer"))
        await settle()
        XCTAssertEqual(client.status, .failed("Connection reset by peer"))
        XCTAssertEqual(sleeper.requested, [.seconds(2)])

        statuses.removeAll()
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(factory.latest!.started)
        // An automatic retry against a PC that is already known to be down
        // keeps the failure, instead of passing through `.connecting`.
        XCTAssertEqual(statuses, [])

        factory.latest!.deliver(.ready)
        XCTAssertEqual(client.status, .connected)
    }

    func testWaitingRebuildsAfterTenSeconds() async {
        client.forwardingEnabled = true
        factory.latest!.deliver(.waiting("No route to host"))
        await settle()
        XCTAssertEqual(client.status, .failed("No route to host"))
        XCTAssertEqual(sleeper.requested, [.seconds(10)])
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 2)
    }

    func testOverlappingTriggersScheduleOneRebuild() async {
        let transport = connectReady()
        transport.viabilityHandler?(false)
        transport.deliver(.failed("Network is down"))
        transport.betterPathHandler?(true)
        await settle()
        XCTAssertEqual(sleeper.pending, 1)
        XCTAssertEqual(sleeper.requested, [.seconds(3)])
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 2)
    }

    func testLostPathSaysSoAtOnce() async {
        let transport = connectReady()
        transport.viabilityHandler?(false)
        XCTAssertEqual(client.status, .failed("Network connection lost"))
        // Keystrokes into a non-viable path are dropped, not written.
        XCTAssertFalse(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testPathThatComesBackInTimeIsNotRebuilt() async {
        let transport = connectReady()
        transport.viabilityHandler?(false)
        transport.viabilityHandler?(true)
        XCTAssertEqual(client.status, .connected)
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertFalse(transport.cancelled)
    }

    func testBetterPathLeavesAHealthyConnectionAlone() async {
        let transport = connectReady()
        transport.betterPathHandler?(true)
        await settle()
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertFalse(transport.cancelled)
    }

    func testBetterPathRescuesAStuckConnectionQuickly() async {
        client.forwardingEnabled = true
        let transport = factory.latest!
        transport.betterPathHandler?(true)
        await settle()
        XCTAssertEqual(sleeper.requested, [.seconds(1)])
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 2)
    }

    func testCallbacksFromAReplacedTransportAreIgnored() async {
        let old = connectReady()
        client.connect()
        let current = factory.latest!
        XCTAssertNotIdentical(old, current)
        current.deliver(.ready)

        old.deliver(.failed("Connection reset by peer"))
        old.viabilityHandler?(false)
        old.betterPathHandler?(true)
        await settle()
        XCTAssertEqual(client.status, .connected)
        XCTAssertEqual(sleeper.pending, 0)
    }

    func testTimerFromASupersededConnectionDoesNothing() async {
        let transport = connectReady()
        transport.deliver(.failed("Connection reset by peer"))
        await settle()
        XCTAssertEqual(sleeper.pending, 1)
        // The user reconnects by hand before the timer goes off.
        client.connect()
        factory.latest!.deliver(.ready)
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertEqual(client.status, .connected)
    }

    func testSupersededTimerDoesNotBlockTheNextRecovery() async {
        let first = connectReady()
        first.deliver(.failed("Connection reset by peer"))
        await settle()
        client.connect()
        let second = factory.latest!
        second.deliver(.failed("Connection reset by peer"))
        await settle()
        XCTAssertEqual(sleeper.pending, 2)
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 3)
    }

    func testNoRebuildOnceForwardingIsOff() async {
        let transport = connectReady()
        transport.deliver(.failed("Connection reset by peer"))
        await settle()
        client.forwardingEnabled = false
        await sleeper.fireAll()
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(client.status, .idle)
    }

    // MARK: Sending

    func testKeysAreWrittenAsWireLines() {
        let transport = connectReady()
        XCTAssertTrue(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertTrue(client.sendKey(vk: VK.a, pressed: false))
        XCTAssertTrue(client.sendCharacter("é"))
        XCTAssertEqual(transport.sent, ["key 65 pressed=1", "key 65 pressed=0", "char 233"])
    }

    func testNothingIsWrittenBeforeReady() {
        client.forwardingEnabled = true
        XCTAssertFalse(client.sendKey(vk: VK.a, pressed: true))
        XCTAssertTrue(factory.latest!.sent.isEmpty)
    }

    func testForwardingOffReleasesHeldKeysFirst() {
        let transport = connectReady()
        client.sendKey(vk: VK.shift, pressed: true)
        client.forwardingEnabled = false
        XCTAssertEqual(transport.sent, ["key 16 pressed=1", "key 16 pressed=0"])
    }

    func testReconnectForgetsHeldKeys() {
        let first = connectReady()
        client.sendKey(vk: VK.menu, pressed: true)
        client.connect()
        let second = factory.latest!
        second.deliver(.ready)
        // The agent's new session holds nothing; a lone Alt up would focus
        // the menu bar.
        XCTAssertFalse(client.sendKey(vk: VK.menu, pressed: false))
        XCTAssertEqual(second.sent, ["alive"])
        XCTAssertEqual(first.sent, ["key 18 pressed=1"])
    }

    func testRefusedWriteCuesADrop() {
        var cues = 0
        client.keystrokeWasDropped = { cues += 1 }
        let transport = connectReady()
        transport.sendError = FakeSendError()
        client.sendKey(vk: VK.a, pressed: true)
        XCTAssertEqual(cues, 1)
    }

    // MARK: Held-key lease

    func testReadyConnectionAnnouncesTheLease() {
        client.forwardingEnabled = true
        let transport = factory.latest!
        XCTAssertTrue(transport.sent.isEmpty)
        transport.deliver(.ready)
        XCTAssertEqual(transport.sent, ["alive"])
    }

    func testNoHeartbeatWhileNothingIsHeld() async {
        let transport = connectReady()
        client.sendKey(vk: VK.a, pressed: true)
        client.sendKey(vk: VK.a, pressed: false)
        await settle()
        await heartbeats.fireAll()
        XCTAssertEqual(transport.sent, ["key 65 pressed=1", "key 65 pressed=0"])
        XCTAssertEqual(heartbeats.pending, 0)
    }

    func testHeldKeyBeatsEveryIntervalUntilReleased() async {
        let transport = connectReady()
        client.sendKey(vk: VK.back, pressed: true)
        await settle()
        XCTAssertEqual(heartbeats.requested, [Heartbeat.interval])
        await heartbeats.fireAll()
        await heartbeats.fireAll()
        XCTAssertEqual(transport.sent, ["key 8 pressed=1", "alive", "alive"])

        client.sendKey(vk: VK.back, pressed: false)
        await heartbeats.fireAll()
        XCTAssertEqual(transport.sent.last, "key 8 pressed=0")
        XCTAssertEqual(heartbeats.pending, 0)
    }

    func testOverlappingHoldsShareOneHeartbeat() async {
        let transport = connectReady()
        client.sendKey(vk: VK.shift, pressed: true)
        client.sendKey(vk: VK.a, pressed: true)
        await settle()
        XCTAssertEqual(heartbeats.pending, 1)
        // Releasing one key keeps the beat going for the other.
        client.sendKey(vk: VK.a, pressed: false)
        await heartbeats.fireAll()
        XCTAssertEqual(transport.sent.last, "alive")
        XCTAssertEqual(heartbeats.pending, 1)
    }

    func testReconnectStopsTheHeartbeat() async {
        let first = connectReady()
        client.sendKey(vk: VK.a, pressed: true)
        await settle()
        client.connect()
        await heartbeats.fireAll()
        XCTAssertEqual(first.sent, ["key 65 pressed=1"])
        XCTAssertEqual(heartbeats.pending, 0)
    }

    func testForwardingOffStopsTheHeartbeat() async {
        _ = connectReady()
        client.sendKey(vk: VK.a, pressed: true)
        await settle()
        client.forwardingEnabled = false
        await heartbeats.fireAll()
        XCTAssertEqual(heartbeats.pending, 0)
    }
}
