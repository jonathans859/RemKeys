/// Which physical keys are holding each Windows VK down, so several keys
/// that map to one VK go out as a single down/up pair.
///
/// The mapping tables send more than one physical key to the same VK: both
/// Shifts to `VK.shift`, Return and keypad Enter to `VK.return`, and — at the
/// default modifier mapping — Control and Command both to `VK.control`. The
/// PC only knows the VK, so tracking holds per *physical* key let the first
/// key released send the up while the other was still down: hold both
/// Shifts, lift one, and Shift was released on the PC. Counting holders per
/// VK means the down goes out when the first key presses it and the up only
/// when the last one lets go.
///
/// Each key's VK is remembered at press time and the up uses that one, so a
/// modifier mapping changed mid-hold still releases what was pressed.
///
/// Generic over the physical key type so it stays free of UIKit and
/// CoreGraphics: iOS keys it on `UIKeyboardHIDUsage`, macOS on `CGKeyCode`.
public struct VKHolders<Key: Hashable> {
    private var vkForKey: [Key: UInt16] = [:]
    private var keysOnVK: [UInt16: Set<Key>] = [:]

    public init() {}

    /// Record `key` going down as `vk`. Returns true when the down should be
    /// sent: `vk` wasn't held yet, or this is an autorepeat from the key
    /// already holding it (macOS forwards its own repeats, and the agent
    /// depends on them). False when another key already holds `vk`.
    @discardableResult
    public mutating func press(_ key: Key, vk: UInt16) -> Bool {
        if let held = vkForKey[key] {
            // Autorepeat: the key is already down. Repeat whatever it pressed.
            return held == vk
        }
        let isFirst = keysOnVK[vk] == nil
        vkForKey[key] = vk
        keysOnVK[vk, default: []].insert(key)
        return isFirst
    }

    /// Record `key` going up. Returns the VK to send the up for when `key`
    /// was the last one holding it, or nil when another key still holds that
    /// VK or `key` was never recorded as down.
    @discardableResult
    public mutating func release(_ key: Key) -> UInt16? {
        guard let vk = vkForKey.removeValue(forKey: key) else { return nil }
        guard var keys = keysOnVK[vk] else { return vk }
        keys.remove(key)
        if keys.isEmpty {
            keysOnVK[vk] = nil
            return vk
        }
        keysOnVK[vk] = keys
        return nil
    }

    public func isHeld(_ key: Key) -> Bool { vkForKey[key] != nil }

    public var isEmpty: Bool { vkForKey.isEmpty }

    /// Forget one key without sending anything, e.g. after the remote's held
    /// keys were flushed some other way.
    public mutating func forget(_ key: Key) {
        guard let vk = vkForKey.removeValue(forKey: key) else { return }
        keysOnVK[vk]?.remove(key)
        if keysOnVK[vk]?.isEmpty == true { keysOnVK[vk] = nil }
    }

    public mutating func removeAll() {
        vkForKey.removeAll()
        keysOnVK.removeAll()
    }
}
