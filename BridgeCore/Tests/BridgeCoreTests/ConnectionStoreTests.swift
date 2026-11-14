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
        XCTAssertEqual(store.save(tailscale), .added)
        XCTAssertEqual(store.save(tailscale), .unchanged, "no duplicates")
        XCTAssertEqual(store.save(lan), .added)
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

        phone.save(tailscale)
        pad.save(lan)
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
        phone.save(tailscale)
        phone.save(lan)
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
        phone.save(tailscale)

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
        phone.save(tailscale)
        phone.save(lan)

        phone.delete(tailscale)
        // Another device that never saw the delete adds it back to the cloud.
        device(cloud, clock).save(tailscale)
        phone.syncFromCloud()
        XCTAssertEqual(phone.connections, [lan])

        // Adding it again on purpose brings it back.
        XCTAssertEqual(phone.save(tailscale), .added)
        XCTAssertTrue(phone.connections.contains(tailscale))
    }

    func testSavingAnExistingAddressRenamesItAndTheNewerNameSyncs() {
        let cloud = CloudBacking()
        let clock = TickClock()
        let phone = device(cloud, clock)
        let pad = device(cloud, clock)
        phone.save(tailscale)
        pad.syncFromCloud()

        XCTAssertEqual(pad.save(SavedConnection(host: "100.64.0.1", port: 5391, name: " Office PC ")), .renamed)
        XCTAssertEqual(pad.connections.count, 1, "renamed, not added")
        XCTAssertTrue(phone.syncFromCloud())
        XCTAssertEqual(phone.connections.first?.displayName, "Office PC")
        XCTAssertEqual(phone.saved(SavedConnection(host: "100.64.0.1", port: 5391))?.name, "Office PC")

        // An older name on another device does not win back.
        let stale = device(cloud, clock)
        stale.syncFromCloud()
        phone.save(SavedConnection(host: "100.64.0.1", port: 5391, name: "Gaming PC"))
        stale.syncFromCloud()
        XCTAssertEqual(stale.connections.first?.name, "Gaming PC")
        pad.syncFromCloud()
        XCTAssertEqual(pad.connections.first?.name, "Gaming PC")
    }

    func testRecordWithoutNameOrModifiedDecodes() throws {
        let json = #"{"connection":{"host":"10.0.0.2","port":5391},"added":0}"#
        let cloud = CloudBacking()
        cloud.values[ConnectionStore.cloudKey("10.0.0.2:5391")] = Data(json.utf8)
        let store = device(cloud, TickClock())
        store.syncFromCloud()
        XCTAssertEqual(store.connections.map(\.displayName), ["10.0.0.2:5391"])
    }

    func testCloudKeyFitsKVSLimitForLongHostnames() {
        let long = SavedConnection(host: String(repeating: "a", count: 253), port: 65535)
        let key = ConnectionStore.cloudKey(long.id)
        XCTAssertLessThanOrEqual(key.utf8.count, 64)
        XCTAssertEqual(key, ConnectionStore.cloudKey(long.id), "stable")
        XCTAssertNotEqual(key, ConnectionStore.cloudKey(tailscale.id))
    }
}
