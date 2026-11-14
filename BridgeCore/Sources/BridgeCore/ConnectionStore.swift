import Foundation
import Observation

/// The saved connections list: the Start tab on iOS, the window on the Mac.
///
/// Same shape as `PadStore`, much smaller: **UserDefaults is the source of
/// truth for reads** and iCloud's key-value store a write-through mirror,
/// passed in only on iOS (the Mac target has no iCloud entitlement, see
/// `docs/ios.md` → "Sync"). The rules that keep KVS from eating data:
///
/// - **One key per connection** (`conn.<hash>`), never one key for the list,
///   so adding on two devices at once keeps both.
/// - **Push is additive**; the only removal is an explicit `delete`.
/// - **Newer `modified` wins** per connection — the name is the one thing
///   that changes, and a record is only written over an older one.
/// - **Deletes need no tombstones**: `cloudKnownIDs` remembers what this device
///   has seen in the cloud, so one that vanishes from there was deleted
///   elsewhere, while one that was never there is a local addition not yet
///   pushed. `locallyDeleted` stops a late cloud copy resurrecting a deletion.
/// - **An empty cloud proves nothing.** Every push also writes a marker key
///   (`connectionsInUse`) that deletes never remove, so a store with neither
///   the marker nor a record was emptied (signed out, account replaced) and
///   nothing is treated as deleted elsewhere. An account change starts the
///   bookkeeping over (`cloudAccountChanged`).
/// - **Order is by when each was added**, identical on every device, so a sync
///   never reshuffles the list under VoiceOver.
@Observable
public final class ConnectionStore {
    public var connections: [SavedConnection] { entries.map(\.connection) }

    private var entries: [Entry]
    @ObservationIgnored private var cloudKnownIDs: Set<String>
    @ObservationIgnored private var locallyDeleted: Set<String>

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
            entries = state.entries
            cloudKnownIDs = Set(state.cloudKnownIDs)
            locallyDeleted = Set(state.locallyDeleted)
        } else {
            entries = []
            cloudKnownIDs = []
            locallyDeleted = []
        }
    }

    // MARK: Editing

    public enum SaveResult: Equatable { case added, renamed, unchanged }

    /// Appends a connection, or — when that address and port are already
    /// saved — gives it the new name.
    @discardableResult
    public func save(_ connection: SavedConnection) -> SaveResult {
        if let index = entries.firstIndex(where: { $0.connection.id == connection.id }) {
            guard entries[index].connection.name != connection.name else { return .unchanged }
            entries[index].connection.name = connection.name
            entries[index].modified = now()
            push()
            return .renamed
        }
        let stamp = now()
        entries.append(Entry(connection: connection, added: stamp, modified: stamp))
        locallyDeleted.remove(connection.id)
        push()
        return .added
    }

    /// The saved entry for this address and port, name included.
    public func saved(_ connection: SavedConnection?) -> SavedConnection? {
        guard let connection else { return nil }
        return entries.first { $0.connection.id == connection.id }?.connection
    }

    /// The one path that deletes from iCloud — reachable only from an
    /// explicit user deletion.
    public func delete(_ connection: SavedConnection) {
        guard entries.contains(where: { $0.connection.id == connection.id }) else { return }
        entries.removeAll { $0.connection.id == connection.id }
        locallyDeleted.insert(connection.id)
        push()
    }

    // MARK: Sync

    /// Merge iCloud into the local list, then push what's new here. Call at
    /// launch **and** on the store's external-change notification — changes
    /// made while the app wasn't running never arrive as notifications.
    /// Returns whether the local list changed.
    @discardableResult
    public func syncFromCloud() -> Bool {
        guard let cloud else { return false }
        cloud.cloudSynchronize()

        let recordKeys = cloud.cloudKeys.filter { $0.hasPrefix(Keys.prefix) }
        // The marker outlives a delete of the last record, so its absence
        // too means the store was emptied rather than edited.
        let cloudIsEmpty = recordKeys.isEmpty && cloud.cloudData(forKey: Keys.marker) == nil
        var remote: [String: Entry] = [:]
        for key in recordKeys {
            // One unreadable record must not block the rest.
            guard let data = cloud.cloudData(forKey: key),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            remote[entry.connection.id] = entry
        }

        // A local one stays unless it was in the cloud and isn't any more
        // (and the cloud wasn't simply emptied); on both sides, newer wins.
        var merged: [Entry] = []
        for local in entries {
            if let theirs = remote[local.connection.id] {
                merged.append(theirs.modified > local.modified ? theirs : local)
            } else if cloudIsEmpty || !cloudKnownIDs.contains(local.connection.id) {
                merged.append(local)
            }
        }
        let localIDs = Set(entries.map(\.connection.id))
        merged += remote.values.filter {
            !localIDs.contains($0.connection.id) && !locallyDeleted.contains($0.connection.id)
        }
        merged.sort { ($0.added, $0.connection.id) < ($1.added, $1.connection.id) }

        cloudKnownIDs = Set(remote.keys)
        let changed = merged != entries
        entries = merged
        push()
        return changed
    }

    /// The device switched iCloud accounts, and Apple replaced the store's
    /// contents: forget what the old account held, then merge as a first
    /// sync. Every local connection is kept (and pushed), and deletions made
    /// under the old account aren't replayed onto the new one.
    @discardableResult
    public func cloudAccountChanged() -> Bool {
        cloudKnownIDs = []
        locallyDeleted = []
        return syncFromCloud()
    }

    /// Saves locally, then — with a cloud — writes the connections it lacks
    /// and removes only what the user deleted here.
    private func push() {
        defer { save() }
        guard let cloud else { return }
        for id in locallyDeleted {
            cloud.removeCloudValue(forKey: Self.cloudKey(id))
            cloudKnownIDs.remove(id)
        }
        for entry in entries {
            let key = Self.cloudKey(entry.connection.id)
            let theirs = cloud.cloudData(forKey: key)
                .flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            if theirs.map({ $0.modified < entry.modified }) ?? true,
               let data = try? JSONEncoder().encode(entry) {
                cloud.setCloudData(data, forKey: key)
            }
            cloudKnownIDs.insert(entry.connection.id)
        }
        if !(entries.isEmpty && locallyDeleted.isEmpty), cloud.cloudData(forKey: Keys.marker) == nil {
            cloud.setCloudData(Data([1]), forKey: Keys.marker)
        }
    }

    private func save() {
        let state = LocalState(
            entries: entries,
            cloudKnownIDs: cloudKnownIDs.sorted(),
            locallyDeleted: locallyDeleted.sorted()
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Keys.local)
        }
    }

    /// KVS keys are capped at 64 bytes and a hostname can run to 253, so the
    /// key is a stable hash of `host:port` (FNV-1a, 64 bit). The record itself
    /// carries the real host and port.
    static func cloudKey(_ id: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return Keys.prefix + String(repeating: "0", count: 16 - hex.count) + hex
    }

    private struct Entry: Codable, Equatable {
        var connection: SavedConnection
        var added: Date
        var modified: Date

        init(connection: SavedConnection, added: Date, modified: Date) {
            self.connection = connection
            self.added = added
            self.modified = modified
        }

        // Records written before names existed carry no `modified`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            connection = try c.decode(SavedConnection.self, forKey: .connection)
            added = try c.decode(Date.self, forKey: .added)
            modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? added
        }
    }

    private struct LocalState: Codable {
        var entries: [Entry]
        var cloudKnownIDs: [String]
        var locallyDeleted: [String]
    }

    enum Keys {
        static let local = "savedConnections"
        static let prefix = "conn."
        /// Written by every push, never removed: "this account has been used
        /// for connections". Deliberately outside `prefix`.
        static let marker = "connectionsInUse"
    }
}
