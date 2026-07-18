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
    static let modifiers: [VirtualKey] = [
        VirtualKey(name: "Control", vk: VK.control),
        VirtualKey(name: "Shift", vk: VK.shift),
        VirtualKey(name: "Alt", vk: VK.menu),
        VirtualKey(name: "Windows", vk: VK.lwin),
        VirtualKey(name: "AltGr", vk: VK.rmenu),
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
}
