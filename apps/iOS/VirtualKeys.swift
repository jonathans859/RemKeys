import Foundation
import BridgeCore

/// One key offered on the virtual-input screen.
struct VirtualKey: Identifiable, Equatable {
    /// Visible and VoiceOver name ("Enter", "Page Up", …).
    let name: String
    /// The Windows VK sent for it. Virtual input picks *Windows* keys
    /// directly, so no ModifierMapping is involved anywhere on this screen.
    let vk: UInt16

    var id: UInt16 { vk }
}

/// A titled row of keys ("slider" in the UI spec): rows stack vertically,
/// each scrolling horizontally.
struct VirtualKeyCategory: Identifiable {
    let title: String
    let keys: [VirtualKey]

    var id: String { title }
}

enum VirtualKeys {
    /// Modifiers are multi-selectable (checkable) and sent as held keys
    /// around the rest of the combination. Order here is the display and
    /// announcement order.
    ///
    /// Caps Lock lives here rather than among the ordinary keys because on the
    /// PC it is a *modifier* in the case that matters: NVDA's default desktop
    /// layout uses it as the screen-reader key (Caps Lock + H for headings),
    /// which only works if it wraps the key it modifies. A plain Caps Lock
    /// press — the one that flips the lock — is still reachable: hold the zone
    /// until the pad presses the key down, then lift.
    static let modifiers: [VirtualKey] = [
        VirtualKey(name: "Control", vk: VK.control),
        VirtualKey(name: "Shift", vk: VK.shift),
        VirtualKey(name: "Alt", vk: VK.menu),
        VirtualKey(name: "Windows", vk: VK.lwin),
        VirtualKey(name: "AltGr", vk: VK.rmenu),
        VirtualKey(name: "Caps Lock", vk: VK.capital),
    ]

    /// Non-modifier keys: exactly one can be selected as the combination's
    /// main key.
    static let categories: [VirtualKeyCategory] = [
        VirtualKeyCategory(title: "Editing", keys: [
            VirtualKey(name: "Enter", vk: VK.return),
            VirtualKey(name: "Tab", vk: VK.tab),
            VirtualKey(name: "Space", vk: VK.space),
            VirtualKey(name: "Backspace", vk: VK.back),
            VirtualKey(name: "Delete", vk: VK.delete),
            VirtualKey(name: "Escape", vk: VK.escape),
            VirtualKey(name: "Insert", vk: VK.insert),
            VirtualKey(name: "Context menu", vk: VK.apps),
            VirtualKey(name: "Print Screen", vk: VK.snapshot),
        ]),
        VirtualKeyCategory(title: "Navigation", keys: [
            VirtualKey(name: "Up", vk: VK.up),
            VirtualKey(name: "Down", vk: VK.down),
            VirtualKey(name: "Left", vk: VK.left),
            VirtualKey(name: "Right", vk: VK.right),
            VirtualKey(name: "Home", vk: VK.home),
            VirtualKey(name: "End", vk: VK.end),
            VirtualKey(name: "Page Up", vk: VK.prior),
            VirtualKey(name: "Page Down", vk: VK.next),
        ]),
        VirtualKeyCategory(title: "Function keys", keys: (1...12).map {
            VirtualKey(name: "F\($0)", vk: VK.f1 + UInt16($0 - 1))
        }),
    ]

    /// Spoken form of a hold timing: "0.6 seconds", "1 second". Used by both
    /// the Settings sliders and the info sheet, which must agree word for word
    /// — they describe the same number to the same user.
    static func secondsDescription(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        if rounded == 1 { return "1 second" }
        let value = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(value) seconds"
    }

    /// F13–F24, offered only as an extra key-pad band and only when enabled
    /// in Settings — an always-on fifth band would shrink every other zone.
    static let extendedFunctionKeys: [VirtualKey] = (13...24).map {
        VirtualKey(name: "F\($0)", vk: VK.f13 + UInt16($0 - 13))
    }
}
