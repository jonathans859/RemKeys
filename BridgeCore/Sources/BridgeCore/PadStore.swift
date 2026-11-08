import Foundation
import Observation

/// The slice of `NSUbiquitousKeyValueStore` the pad store uses, behind a
/// protocol so the merge can be tested against an in-memory fake: the real
/// store silently does nothing without an iCloud account, so tests against it
/// would pass vacuously.
public protocol PadCloudStore: AnyObject {
    func cloudData(forKey key: String) -> Data?
    func setCloudData(_ data: Data, forKey key: String)
    func removeCloudValue(forKey key: String)
    var cloudKeys: [String] { get }
    func cloudSynchronize()
}

#if canImport(Darwin)
extension NSUbiquitousKeyValueStore: PadCloudStore {
    public func cloudData(forKey key: String) -> Data? { data(forKey: key) }
    public func setCloudData(_ data: Data, forKey key: String) { set(data, forKey: key) }
    public func removeCloudValue(forKey key: String) { removeObject(forKey: key) }
    public var cloudKeys: [String] { Array(dictionaryRepresentation.keys) }
    public func cloudSynchronize() { _ = synchronize() }
}
#endif

/// The user's pads: the list Settings edits and the Virtual Input tab shows.
///
/// **UserDefaults is the source of truth for reads**; iCloud's key-value
/// store is a write-through mirror, so launch works offline and signed out.
/// The cloud layout follows the rules that keep KVS from eating data:
///
/// - **One key per pad** (`pad.<uuid>`) plus one for the order (`padOrder`),
///   never one key holding the array — KVS is last-writer-wins *per key*, so
///   editing two different pads on two phones must not lose one of them.
/// - **Newer `modified` wins**, pad by pad and for the order. A record is
///   only ever written over an older one.
/// - **Never-edited records are never pushed.** A fresh install seeds the
///   defaults with `Pad.neverEdited`; if it published them, it could
///   overwrite pads the user edited elsewhere before it had pulled them.
/// - **Deletes need no tombstones**: `cloudKnownIDs` remembers which pads
///   this device has seen in the cloud, so one that vanishes from there was
///   deleted elsewhere, while one that was never there is a local creation.
///   An untouched default missing from a newer remote order was deleted
///   elsewhere too.
@Observable
public final class PadStore {
    public private(set) var pads: [Pad]

    @ObservationIgnored private var orderModified: Date
    @ObservationIgnored private var cloudKnownIDs: Set<UUID>
    /// Pads deleted here, so a late copy still in the cloud is removed again
    /// instead of being resurrected.
    @ObservationIgnored private var locallyDeleted: Set<UUID>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: PadCloudStore?
    @ObservationIgnored private let now: () -> Date

    public init(
        defaults: UserDefaults = .standard,
        cloud: PadCloudStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.now = now
        if let data = defaults.data(forKey: Keys.local),
           let state = try? JSONDecoder().decode(LocalState.self, from: data) {
            pads = state.pads
            orderModified = state.orderModified
            cloudKnownIDs = Set(state.cloudKnownIDs)
            locallyDeleted = Set(state.locallyDeleted)
        } else {
            // First launch of the editable pads. The F13–F24 page used to be a
            // Settings toggle; its stored value decides whether that pad
            // starts visible, so an upgrade changes nothing on screen.
            pads = DefaultPads.all(showExtendedFunctionKeys: defaults.bool(forKey: Keys.legacyExtendedFKeys))
            orderModified = Pad.neverEdited
            cloudKnownIDs = []
            locallyDeleted = []
            save()
        }
    }

    // MARK: Reading

    public var visiblePads: [Pad] { pads.filter(\.isVisible) }

    public func pad(_ id: UUID) -> Pad? { pads.first { $0.id == id } }

    // MARK: Editing

    /// Apply an edit to one pad. Stamps, saves and pushes only if the pad
    /// actually changed, and hands back whatever the edit returned (so a
    /// refused move can be announced).
    @discardableResult
    public func edit<T>(_ id: UUID, _ change: (inout Pad) -> T) -> T? {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        var pad = pads[index]
        let result = change(&pad)
        if pad != pads[index] {
            pad.modified = now()
            pads[index] = pad
            commit()
        }
        return result
    }

    /// A new, empty 3 × 3 pad at the end of the list.
    @discardableResult
    public func addPad(title: String = "New pad") -> UUID {
        let pad = Pad(title: uniqueTitle(title), rows: 3, columns: 3, modified: now())
        pads.append(pad)
        orderModified = now()
        commit()
        return pad.id
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> UUID? {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = pads[index].duplicated(title: uniqueTitle("\(pads[index].title) copy"), modified: now())
        pads.insert(copy, at: index + 1)
        orderModified = now()
        commit()
        return copy.id
    }

    /// The one path that deletes from iCloud — reachable only from an
    /// explicit user deletion.
    public func delete(_ id: UUID) {
        guard pads.contains(where: { $0.id == id }) else { return }
        pads.removeAll { $0.id == id }
        locallyDeleted.insert(id)
        orderModified = now()
        commit()
    }

    /// Move one pad up (-1) or down (+1) in the swipe order.
    @discardableResult
    public func move(_ id: UUID, by offset: Int) -> Bool {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard pads.indices.contains(target) else { return false }
        pads.swapAt(index, target)
        orderModified = now()
        commit()
        return true
    }

    /// List-style reorder (drag in an edit-mode list).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { pads[$0] }
        var remaining = pads.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertAt, 0), remaining.count))
        guard remaining.map(\.id) != pads.map(\.id) else { return }
        pads = remaining
        orderModified = now()
        commit()
    }

    /// Replace every pad with fresh defaults. The defaults are stamped *now*,
    /// so the restore beats the old edits on every other device rather than
    /// being undone by them at the next sync.
    public func restoreDefaults() {
        let stamp = now()
        let fresh = DefaultPads.all(modified: stamp)
        let freshIDs = Set(fresh.map(\.id))
        for pad in pads where !freshIDs.contains(pad.id) {
            locallyDeleted.insert(pad.id)
        }
        locallyDeleted.subtract(freshIDs)
        pads = fresh
        orderModified = stamp
        commit()
    }

    private func uniqueTitle(_ base: String) -> String {
        let taken = Set(pads.map(\.title))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Sync

    /// Merge what is in iCloud into the local pads, then push whatever is
    /// newer here. Call at launch **and** on the store's external-change
    /// notification — changes made while the app wasn't running never arrive
    /// as notifications. Returns whether the local pads changed.
    @discardableResult
    public func syncFromCloud() -> Bool {
        guard let cloud else { return false }
        cloud.cloudSynchronize()

        let remoteOrder = cloud.cloudData(forKey: Keys.order)
            .flatMap { try? JSONDecoder().decode(PadOrder.self, from: $0) }
        var remote: [UUID: Pad] = [:]
        for key in cloud.cloudKeys where key.hasPrefix(Keys.padPrefix) {
            // One unreadable record must not block the rest.
            guard let data = cloud.cloudData(forKey: key),
                  let pad = try? JSONDecoder().decode(Pad.self, from: data) else { continue }
            remote[pad.id] = pad
        }

        var merged: [Pad] = []
        for local in pads {
            if let theirs = remote[local.id] {
                merged.append(theirs.modified >= local.modified ? theirs : local)
            } else if cloudKnownIDs.contains(local.id) {
                continue // was in the cloud, isn't now: deleted elsewhere
            } else if local.modified == Pad.neverEdited, let order = remoteOrder,
                      !order.ids.contains(local.id) {
                continue // untouched default the other device deleted
            } else {
                merged.append(local) // created here, not pushed yet
            }
        }
        let localIDs = Set(pads.map(\.id))
        let arrivals = remote.values
            .filter { !localIDs.contains($0.id) && !locallyDeleted.contains($0.id) }
            .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
        merged += arrivals

        if let order = remoteOrder, order.modified > orderModified {
            let rank = Dictionary(order.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            // Stable: anything the remote order doesn't name keeps its
            // relative place, after the ones it does.
            merged = merged.enumerated().sorted { a, b in
                (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
            }.map(\.element)
            orderModified = order.modified
        }

        cloudKnownIDs = Set(remote.keys)
        let changed = merged != pads
        pads = merged
        save()
        push()
        return changed
    }

    private func commit() {
        save()
        push()
    }

    /// Additive: writes pads and the order where this device is newer, and
    /// removes only what the user deleted here.
    private func push() {
        guard let cloud else { return }
        let encoder = JSONEncoder()

        for id in locallyDeleted {
            cloud.removeCloudValue(forKey: Keys.padPrefix + id.uuidString)
            cloudKnownIDs.remove(id)
        }

        for pad in pads where pad.modified > Pad.neverEdited {
            let key = Keys.padPrefix + pad.id.uuidString
            let theirs = cloud.cloudData(forKey: key)
                .flatMap { try? JSONDecoder().decode(Pad.self, from: $0) }
            if let theirs, theirs.modified >= pad.modified {
                cloudKnownIDs.insert(pad.id)
                continue
            }
            guard let data = try? encoder.encode(pad) else { continue }
            cloud.setCloudData(data, forKey: key)
            cloudKnownIDs.insert(pad.id)
        }

        if orderModified > Pad.neverEdited {
            let theirs = cloud.cloudData(forKey: Keys.order)
                .flatMap { try? JSONDecoder().decode(PadOrder.self, from: $0) }
            if theirs == nil || theirs!.modified < orderModified,
               let data = try? encoder.encode(PadOrder(ids: pads.map(\.id), modified: orderModified)) {
                cloud.setCloudData(data, forKey: Keys.order)
            }
        }
        save()
    }

    private func save() {
        let state = LocalState(
            pads: pads,
            orderModified: orderModified,
            cloudKnownIDs: cloudKnownIDs.sorted { $0.uuidString < $1.uuidString },
            locallyDeleted: locallyDeleted.sorted { $0.uuidString < $1.uuidString }
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Keys.local)
        }
    }

    private struct LocalState: Codable {
        var pads: [Pad]
        var orderModified: Date
        var cloudKnownIDs: [UUID]
        var locallyDeleted: [UUID]
    }

    private struct PadOrder: Codable {
        var ids: [UUID]
        var modified: Date
    }

    enum Keys {
        static let local = "virtualPads"
        /// The retired F13–F24 toggle, read once to seed the defaults.
        static let legacyExtendedFKeys = "virtualPadExtendedFKeys"
        static let padPrefix = "pad."
        static let order = "padOrder"
    }
}
