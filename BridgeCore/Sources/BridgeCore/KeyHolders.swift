/// Which sources are holding each key right now, for merging overlapping
/// capture sources into one stream.
///
/// The iOS capture reads one physical keyboard through two sources at once:
/// `pressesBegan` and the GameController HID layer. Normal keys show up on
/// both, Cmd chords only on HID, and on some devices nothing ever arrives
/// on HID. Counting *holders* for each key, instead of trusting either
/// source, means whichever source sees a key carries it. A key both sources
/// see still goes out exactly once: down when the first holder presses, up
/// when the last holder lets go.
///
/// Generic so it stays free of UIKit: the app uses it with
/// `UIKeyboardHIDUsage` and its own source enum.
public struct KeyHolders<Key: Hashable, Source: Hashable> {
    /// What one release did to a key.
    public enum Release: Equatable {
        /// No source held the key, so nothing was ever sent for it. The
        /// caller must not send an up.
        case wasNotHeld
        /// Another source still holds the key. Don't send the up yet.
        case stillHeld
        /// That was the last holder: send the up now.
        case lastHolderReleased
    }

    private var holders: [Key: Set<Source>] = [:]

    public init() {}

    /// Record a press. Returns true when `source` is the key's first holder,
    /// which is the one report that should send the down.
    @discardableResult
    public mutating func press(_ key: Key, from source: Source) -> Bool {
        let isFirst = holders[key] == nil
        holders[key, default: []].insert(source)
        return isFirst
    }

    /// Record a release from `source`.
    ///
    /// A release from a source that never reported the press still counts
    /// against the key while another source holds it. That matches the
    /// capture's behaviour: a source can miss a down (HID going live
    /// mid-press) and still see the up.
    @discardableResult
    public mutating func release(_ key: Key, from source: Source) -> Release {
        guard var set = holders[key] else { return .wasNotHeld }
        set.remove(source)
        if set.isEmpty {
            holders[key] = nil
            return .lastHolderReleased
        }
        holders[key] = set
        return .stillHeld
    }

    /// Record a transition without caring about the outcome. Used to track
    /// what is physically held.
    public mutating func record(_ key: Key, pressed: Bool, from source: Source) {
        if pressed { press(key, from: source) } else { release(key, from: source) }
    }

    public func isHeld(_ key: Key) -> Bool { holders[key] != nil }

    /// Every key at least one source holds.
    public var heldKeys: Dictionary<Key, Set<Source>>.Keys { holders.keys }

    public var isEmpty: Bool { holders.isEmpty }

    /// Forget one key entirely, whoever holds it.
    public mutating func forget(_ key: Key) { holders[key] = nil }

    public mutating func removeAll() { holders.removeAll() }
}
