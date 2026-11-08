import XCTest
@testable import BridgeCore

/// One iCloud account; each `FakeCloud` sharing a `Backing` is one device.
private final class Backing { var values: [String: Data] = [:] }

private final class FakeCloud: PadCloudStore {
    let backing: Backing
    init(_ backing: Backing) { self.backing = backing }
    func cloudData(forKey key: String) -> Data? { backing.values[key] }
    func setCloudData(_ data: Data, forKey key: String) { backing.values[key] = data }
    func removeCloudValue(forKey key: String) { backing.values[key] = nil }
    var cloudKeys: [String] { Array(backing.values.keys) }
    func cloudSynchronize() {}
}

/// A clock that only moves when told, so "newer wins" is deterministic.
private final class Clock {
    var time = Date(timeIntervalSince1970: 1_000_000)
    func tick() -> Date { time += 1; return time }
}

final class PadStoreTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshDefaults() -> UserDefaults {
        let name = "PadStoreTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func device(_ backing: Backing, _ clock: Clock, defaults: UserDefaults? = nil) -> PadStore {
        PadStore(defaults: defaults ?? freshDefaults(), cloud: FakeCloud(backing), now: clock.tick)
    }

    func testSeedsDefaultsAndMigratesTheExtendedFKeysToggle() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "virtualPadExtendedFKeys")
        let store = PadStore(defaults: defaults)
        XCTAssertEqual(store.pads.count, 4)
        XCTAssertEqual(store.visiblePads.count, 4)

        XCTAssertEqual(PadStore(defaults: freshDefaults()).visiblePads.count, 3)
    }

    func testEditsPersist() {
        let defaults = freshDefaults()
        let store = PadStore(defaults: defaults)
        store.edit(DefaultPads.navigationID) { $0.title = "Arrows" }
        let id = store.addPad()
        store.edit(id) { _ = $0.add(PadKey(vk: VK.a), row: 0, column: 0) }

        let reloaded = PadStore(defaults: defaults)
        XCTAssertEqual(reloaded.pads.first?.title, "Arrows")
        XCTAssertEqual(reloaded.pad(id)?.keys.count, 1)
        XCTAssertEqual(reloaded.pads.last?.id, id)
    }

    func testNoOpEditDoesNotStamp() {
        let store = PadStore(defaults: freshDefaults())
        store.edit(DefaultPads.navigationID) { $0.title = "Navigation" }
        XCTAssertEqual(store.pad(DefaultPads.navigationID)?.modified, Pad.neverEdited)
    }

    func testFreshDeviceDoesNotPublishOrOverwrite() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock)
        a.syncFromCloud()
        XCTAssertTrue(cloud.values.isEmpty, "untouched defaults must not be pushed")

        a.edit(DefaultPads.navigationID) { $0.title = "Mine" }
        let b = device(cloud, clock)
        b.syncFromCloud()
        XCTAssertEqual(b.pad(DefaultPads.navigationID)?.title, "Mine")
        XCTAssertEqual(b.pads.count, 4, "no duplicated defaults")
    }

    func testEditsToDifferentPadsOnTwoDevicesBothSurvive() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock), b = device(cloud, clock)
        a.edit(DefaultPads.navigationID) { $0.title = "From A" }
        b.edit(DefaultPads.editingID) { $0.title = "From B" }
        a.syncFromCloud(); b.syncFromCloud()
        for store in [a, b] {
            XCTAssertEqual(store.pad(DefaultPads.navigationID)?.title, "From A")
            XCTAssertEqual(store.pad(DefaultPads.editingID)?.title, "From B")
        }
    }

    func testNewerEditWinsTheSamePad() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock), b = device(cloud, clock)
        a.edit(DefaultPads.navigationID) { $0.title = "Older" }
        b.syncFromCloud()
        b.edit(DefaultPads.navigationID) { $0.title = "Newer" }
        a.syncFromCloud()
        XCTAssertEqual(a.pad(DefaultPads.navigationID)?.title, "Newer")
    }

    func testCreatedPadArrivesInOrder() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock), b = device(cloud, clock)
        let id = a.addPad(title: "Media")
        a.move(id, by: -4)
        b.syncFromCloud()
        XCTAssertEqual(b.pads.first?.title, "Media")
        XCTAssertEqual(b.pads.count, 5)
    }

    func testDeletionReachesOtherDeviceWithoutResurrection() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock), b = device(cloud, clock)
        let id = a.addPad(title: "Temp")
        b.syncFromCloud()
        XCTAssertNotNil(b.pad(id))

        a.delete(id)
        b.syncFromCloud()
        XCTAssertNil(b.pad(id))
        a.syncFromCloud()
        XCTAssertNil(a.pad(id))
    }

    func testDeletingAnUntouchedDefaultReachesAFreshDevice() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock)
        a.delete(DefaultPads.functionKeysID)
        let b = device(cloud, clock)
        b.syncFromCloud()
        XCTAssertNil(b.pad(DefaultPads.functionKeysID))
        XCTAssertEqual(b.pads.count, 3)
    }

    func testOfflineCreationSurvivesTheMerge() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock)
        a.addPad(title: "From A")
        // B never synced while creating its own.
        let b = device(cloud, clock)
        let mine = b.addPad(title: "From B")
        b.syncFromCloud()
        XCTAssertNotNil(b.pad(mine))
        XCTAssertTrue(b.pads.contains { $0.title == "From A" })
        a.syncFromCloud()
        XCTAssertNotNil(a.pad(mine))
    }

    func testRestoreDefaultsBeatsOlderEditsElsewhere() {
        let cloud = Backing(), clock = Clock()
        let a = device(cloud, clock), b = device(cloud, clock)
        a.edit(DefaultPads.navigationID) { $0.title = "Edited" }
        let extra = a.addPad(title: "Extra")
        b.syncFromCloud()

        b.restoreDefaults()
        a.syncFromCloud()
        XCTAssertEqual(a.pad(DefaultPads.navigationID)?.title, "Navigation")
        XCTAssertNil(a.pad(extra))
        XCTAssertEqual(a.pads.count, 4)
    }

    func testDuplicateGetsFreshIDsAndAUniqueTitle() {
        let store = PadStore(defaults: freshDefaults())
        let copy = store.duplicate(DefaultPads.navigationID)!
        let pad = store.pad(copy)!
        XCTAssertEqual(pad.title, "Navigation copy")
        XCTAssertEqual(store.pads[1].id, copy)
        let original = Set(store.pad(DefaultPads.navigationID)!.keys.map(\.id))
        XCTAssertTrue(original.isDisjoint(with: pad.keys.map(\.id)))
    }

    func testListReorder() {
        let store = PadStore(defaults: freshDefaults())
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.pads.map(\.id), [
            DefaultPads.editingID, DefaultPads.functionKeysID,
            DefaultPads.navigationID, DefaultPads.extendedFunctionKeysID,
        ])
    }
}
