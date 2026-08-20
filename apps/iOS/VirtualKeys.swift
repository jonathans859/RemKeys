import Foundation
import BridgeCore

/// One key offered on the virtual-input screen.
struct VirtualKey: Identifiable, Equatable {
    /// Visible name ("Enter", "Page Up"). Kept short enough to read inside a
    /// zone, but the zones are large now, so nothing has to be abbreviated
    /// down to "Bksp".
    let name: String
    /// The Windows VK sent for it. Virtual input picks *Windows* keys
    /// directly, so no ModifierMapping is involved anywhere on this screen.
    let vk: UInt16
    /// What VoiceOver says, when the visible name doesn't survive being
    /// spoken.
    private let spoken: String?

    init(name: String, vk: UInt16, spoken: String? = nil) {
        self.name = name
        self.vk = vk
        self.spoken = spoken
    }

    /// The name to announce. Every announcement path uses this; only the drawn
    /// label uses `name`.
    var spokenName: String { spoken ?? name }

    var id: UInt16 { vk }
}

/// One screenful of the pad's upper block. Rows are normally
/// `VirtualKeys.columns` keys wide, but each row divides its own width, so a
/// short row simply gets wider zones — which is how the Editing page ends in
/// two half-width keys rather than a dead corner.
struct PadPage: Identifiable, Equatable {
    let title: String
    let rows: [[VirtualKey]]

    var id: String { title }
}

enum VirtualKeys {
    /// The pad is three zones wide, everywhere, always.
    ///
    /// This is the whole design, so it is worth stating why three: **every
    /// zone has to be reachable by a physical description rather than by a
    /// count.** On a three-wide grid each zone is a corner, an edge middle, or
    /// the centre — a landmark a finger can find on a sheet of glass. At four
    /// columns the outer rows grow interior zones that can only be described
    /// as "the second one along", which is a counting task, and counting is
    /// what made the old bands and the 60-key keyboard layout slow.
    ///
    /// It also keeps zones large: three across a phone in portrait is about
    /// 116 pt, against 29 pt for a twelve-key band and 23 pt for the keyboard
    /// layout's letters. Apple's minimum target is 44 pt. A zone under that
    /// cannot be aimed at, only searched for.
    static let columns = 3

    /// Modifiers are multi-selectable and sent as held keys around the rest of
    /// the combination. Order here is the announcement order and the order
    /// they are pressed on the PC.
    ///
    /// Caps Lock is one of them because on the PC it *is* a modifier in the
    /// case that matters: NVDA's default desktop layout uses it as the
    /// screen-reader key (Caps Lock + H for headings), which only works if it
    /// wraps the key it modifies. The plain press that flips the lock is still
    /// reachable — hold the zone until the key goes down, then lift.
    static let modifiers: [VirtualKey] = [
        VirtualKey(name: "Ctrl", vk: VK.control, spoken: "Control"),
        VirtualKey(name: "Shift", vk: VK.shift),
        VirtualKey(name: "Alt", vk: VK.menu),
        VirtualKey(name: "Win", vk: VK.lwin, spoken: "Windows"),
        VirtualKey(name: "AltGr", vk: VK.rmenu),
        VirtualKey(name: "Caps", vk: VK.capital, spoken: "Caps Lock"),
    ]

    /// The keys that toggle on lift instead of sending.
    static let modifierVKs: Set<UInt16> = Set(modifiers.map(\.vk))

    /// The permanent block at the bottom of the pad: the six modifiers as
    /// 2 × 3, in the order above.
    ///
    /// It is separate from the pages, and welded to the bottom edge, because a
    /// modifier is the one thing you always need *together with* something
    /// else. On a page, every combination would cost two page changes; against
    /// the bottom edge it costs one stab, at a position that never moves —
    /// not between pages, and not between sessions.
    static let modifierBlock: [[VirtualKey]] = stride(from: 0, to: modifiers.count, by: columns)
        .map { Array(modifiers[$0..<min($0 + columns, modifiers.count)]) }

    /// The pages of the upper block, in swipe order.
    static func pages(includeExtendedFKeys: Bool) -> [PadPage] {
        var result = [navigation, editing, functionKeys]
        if includeExtendedFKeys { result.append(extendedFunctionKeys) }
        return result
    }

    /// The page that justifies the whole shape. The arrows are laid out as
    /// they *mean*: up is the top edge, down is the bottom edge, left is the
    /// left edge. There is nothing to learn, because the position of the key
    /// is its meaning — the one thing a 60-key layout can never offer.
    ///
    /// The corners read the same way: start-of-line and start-of-page on the
    /// left, end-of-line and end-of-page on the right. Enter takes the centre,
    /// the easiest zone to find blind, because it is the key most often needed
    /// at the end of a run of arrowing.
    private static let navigation = PadPage(title: "Navigation", rows: [
        [
            VirtualKey(name: "Home", vk: VK.home),
            VirtualKey(name: "Up", vk: VK.up),
            VirtualKey(name: "Page Up", vk: VK.prior),
        ],
        [
            VirtualKey(name: "Left", vk: VK.left),
            VirtualKey(name: "Enter", vk: VK.return),
            VirtualKey(name: "Right", vk: VK.right),
        ],
        [
            VirtualKey(name: "End", vk: VK.end),
            VirtualKey(name: "Down", vk: VK.down),
            VirtualKey(name: "Page Down", vk: VK.next),
        ],
    ])

    /// Deleting keys flank Space in the middle row, on the sides they are on
    /// a real keyboard: Backspace deletes to the left, Delete to the right.
    /// Enter repeats here rather than being missing — it is the most-sent key
    /// on the pad, and a duplicate zone costs nothing.
    ///
    /// The bottom row is **two half-width zones, not three**. Print Screen was
    /// dropped as unused (field decision 2026-08-20), and rather than leave a
    /// dead corner the row splits in half: both zones are still bounded by a
    /// corner, so they stay describable, and Enter — the key sent most often —
    /// gets the largest target on the pad. Rows do not have to match column
    /// counts; each one divides its own width.
    private static let editing = PadPage(title: "Editing", rows: [
        [
            VirtualKey(name: "Escape", vk: VK.escape),
            VirtualKey(name: "Tab", vk: VK.tab),
            VirtualKey(name: "Insert", vk: VK.insert),
        ],
        [
            VirtualKey(name: "Backspace", vk: VK.back),
            VirtualKey(name: "Space", vk: VK.space),
            VirtualKey(name: "Delete", vk: VK.delete),
        ],
        [
            VirtualKey(name: "Menu", vk: VK.apps, spoken: "Context menu"),
            VirtualKey(name: "Enter", vk: VK.return),
        ],
    ])

    /// F1–F12 as 3 × 4, reading left to right and top to bottom, so the row a
    /// key is in is its number divided by three — the only page where counting
    /// is unavoidable, and the numbers do the counting for you.
    private static let functionKeys = PadPage(
        title: "Function keys",
        rows: rows(of: (1...12).map { VirtualKey(name: "F\($0)", vk: VK.f1 + UInt16($0 - 1)) })
    )

    /// F13–F24, an opt-in extra page (`virtualPadExtendedFKeys`) rather than
    /// extra rows: a page costs nothing to the pages you actually use, where
    /// an extra band used to shrink every zone on the screen.
    private static let extendedFunctionKeys = PadPage(
        title: "Extended function keys",
        rows: rows(of: (13...24).map { VirtualKey(name: "F\($0)", vk: VK.f13 + UInt16($0 - 13)) })
    )

    private static func rows(of keys: [VirtualKey]) -> [[VirtualKey]] {
        stride(from: 0, to: keys.count, by: columns)
            .map { Array(keys[$0..<min($0 + columns, keys.count)]) }
    }

    /// Spoken form of a hold timing: "0.6 seconds", "1 second". Used by both
    /// the Settings slider and the info sheet, which must agree word for word
    /// — they describe the same number to the same user.
    static func secondsDescription(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        if rounded == 1 { return "1 second" }
        let value = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(value) seconds"
    }
}
