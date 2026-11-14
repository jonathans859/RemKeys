import XCTest
@testable import BridgeCore

/// One iCloud account; each `FakeConnectionCloud` sharing a backing is one device.
private final class CloudBacking { var values: [String: Data] = [:] }

private final class FakeConnectionCloud: PadCloudStore {
    let backing: CloudBacking
    init(_ backing: CloudBacking) { self.backing = backing }
    func cloudData(forKey key: String) -> Data? { backing.values[key] }
    func setCloudData(_ data: Data, forKey key: String) { backing.values[key] = data }
    func removeCloudValue(forKey key: String) { backing.values[key] = nil }
    var cloudKeys: [String] { Array(backing.values.keys) }
    func cloudSynchronize() {}
}

private final class TickClock {
    var time = Date(timeIntervalSince1970: 1_000_000)
    func tick() -> Date { time += 1; return time }
}

final class ConnectionStoreTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ConnectionStoreTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func device(_ backing: CloudBacking?, _ clock: TickClock, defaults: UserDefaults? = nil) -> ConnectionStore {
        ConnectionStore(
            defaults: defaults ?? freshDefaults(),
            cloud: backing.map { FakeConnectionCloud($0) },
            now: clock.tick
        )
    }

    private let tailscale = SavedConnection(host: "100.64.0.1", port: 5391)
    private let lan = SavedConnection(host: "192.168.1.20", port: 6000)

    func testAddSkipsDuplicatesAndPersistsWithoutCloud() {
        let defaults = freshDefaults()
        let store = device(nil, TickClock(), defaults: defaults)
        XCTAssertTrue(store.add(tailscale))
        XCTAssertFalse(store.add(tailscale), "no duplicates")
        XCTAssertTrue(store.add(lan))
        XCTAssertFalse(store.syncFromCloud(), "no cloud, nothing to merge")

        XCTAssertEqual(device(nil, TickClock(), defaults: defaults).connections, [tailscale, lan])

        store.delete(tailscale)
        XCTAssertEqual(device(nil, TickClock(), defaults: defaults).connections, [lan])
    }

    func testAdditionsOnTwoDevicesBothSurviveInAddedOrder() {
        let cloud = CloudBacking()
        let clock = TickClock()
        let phone = device(cloud, clock)
        let pad = device(cloud, clock)

        phone.add(tailscale)
        pad.add(lan)
        XCTAssertTrue(phone.syncFromCloud())
        pad.syncFromCloud()

        XCTAssertEqual(phone.connections, [tailscale, lan])
        XCTAssertEqual(pad.connections, [tailscale, lan])
    }

    func testDeleteReachesTheOtherDevice() {
        let cloud = CloudBacking()
        let clock = TickClock()
        let phone = device(cloud, clock)
        let pad = device(cloud, clock)
        phone.add(tailscale)
        phone.add(lan)
        pad.syncFromCloud()

        pad.delete(tailscale)
        XCTAssertTrue(phone.syncFromCloud())
        XCTAssertEqual(phone.connections, [lan])
    }

    /// A fresh install has nothing; its first sync must take the account's
    /// list, not publish its empty one over it.
    func testFreshDeviceNeverWipesTheAccount() {
        let cloud = CloudBacking()
        let clock = TickClock()
        let phone = device(cloud, clock)
        phone.add(tailscale)

        let fresh = device(cloud, clock)
        fresh.syncFromCloud()
        XCTAssertEqual(fresh.connections, [tailscale])
        phone.syncFromCloud()
        XCTAssertEqual(phone.connections, [tailscale])
    }

    /// Deleted here while a copy is still in the cloud (another device
    /// re-pushed before seeing the delete): stays deleted.
    func testLocalDeleteIsNotResurrected() {
        let cloud = CloudBacking()
        let clock = TickClock()
        let phone = device(cloud, clock)
        phone.add(tailscale)
        phone.add(lan)

        phone.delete(tailscale)
        // Another device that never saw the delete adds it back to the cloud.
        device(cloud, clock).add(tailscale)
        phone.syncFromCloud()
        XCTAssertEqual(phone.connections, [lan])

        // Adding it again on purpose brings it back.
        XCTAssertTrue(phone.add(tailscale))
        XCTAssertTrue(phone.connections.contains(tailscale))
    }

    func testCloudKeyFitsKVSLimitForLongHostnames() {
        let long = SavedConnection(host: String(repeating: "a", count: 253), port: 65535)
        let key = ConnectionStore.cloudKey(long.id)
        XCTAssertLessThanOrEqual(key.utf8.count, 64)
        XCTAssertEqual(key, ConnectionStore.cloudKey(long.id), "stable")
        XCTAssertNotEqual(key, ConnectionStore.cloudKey(tailscale.id))
    }
}
