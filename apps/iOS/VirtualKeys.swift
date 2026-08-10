import Foundation
import BridgeCore

/// One key offered on the virtual-input screen.
struct VirtualKey: Identifiable, Equatable {
    /// Visible name ("Enter", "Page Up", "["). Kept short: on the keyboard
    /// layout it has to read inside a key-sized box.
    let name: String
    /// The Windows VK sent for it. Virtual input picks *Windows* keys
    /// directly, so no ModifierMapping is involved anywhere on this screen.
    let vk: UInt16
    /// What VoiceOver says, when the visible name doesn't survive being
    /// spoken — punctuation mostly ("[" → "Left bracket"), plus abbreviations
    /// the pad shortens to fit ("Caps" → "Caps Lock").
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

    // MARK: - Keyboard layout (landscape)

    /// The keys that toggle on lift instead of sending, wherever they appear.
    /// Caps Lock is one of them for the same reason it sits in the modifiers
    /// band: on a PC running NVDA it *is* a modifier.
    static let modifierVKs: Set<UInt16> = [
        VK.control, VK.shift, VK.menu, VK.lwin, VK.rmenu, VK.capital,
    ]

    /// A full PC key block, laid out as it is on a real keyboard.
    ///
    /// Why this exists: the bands layout asks you to learn "third band, fifth
    /// key". A keyboard asks you to remember where W is, which anyone who
    /// types already does — so in the one orientation whose proportions can
    /// hold it, the pad shows the layout the muscle memory is already in. It
    /// also finally puts letters and digits on the pad, which is what turns
    /// single-letter screen-reader navigation on the PC into one drag and lift
    /// instead of the text field plus Send.
    ///
    /// Shape notes:
    /// - **Every row sums to exactly 15 units**, so keys line up in a common
    ///   grid across rows and Q really does sit above A. Rows are equal height
    ///   (a real keyboard's shorter function row would only shrink targets).
    /// - The **main block keeps its real shape and is anchored to the bottom
    ///   edge**: Ctrl/Space is the bottom row, the left column really is
    ///   Shift / Caps / Tab / backtick / Esc going up. Optional rows are added
    ///   at the *top* so none of that moves when a setting changes.
    /// - The nav/edit cluster (Insert, Home, Page Up …) sits in a row of its
    ///   own rather than in a block to the right: unrolling it is the only way
    ///   to fit it without stealing width from the letters.
    /// - Arrows run flat along the bottom row, as they do on 60 % boards — an
    ///   inverted T needs half-height keys, which would break the row grid.
    /// - Both Shifts send the same generic VK, so latching one lights up both.
    ///   That is honest: what is latched is *Shift*, not a side.
    static func keyboardRows(
        layout: PCKeyboardLayout,
        includeExtendedFKeys: Bool
    ) -> [PadRow] {
        let n = names(for: layout)
        /// Letters, digits and punctuation carry a US-position VK: the pad
        /// names it per the PC's layout, the agent injects it by scancode, and
        /// the PC's layout resolves the character. Same contract as physical
        /// capture.
        func key(_ vk: UInt16, _ units: Double = 1) -> PadKey {
            PadKey(key: n[vk] ?? VirtualKey(name: "?", vk: vk), units: units)
        }

        var rows: [PadRow] = []
        if includeExtendedFKeys {
            rows.append(PadRow(title: "Extended function keys", keys: (13...24).map {
                PadKey(key: VirtualKey(name: "F\($0)", vk: VK.f13 + UInt16($0 - 13)), units: 1.25)
            }))
        }
        rows.append(PadRow(title: "Navigation and editing", keys: [
            key(VK.insert, 2), key(VK.home, 2), key(VK.prior, 2),
            key(VK.delete, 2), key(VK.end, 2), key(VK.next, 2),
            key(VK.snapshot, 3),
        ]))
        rows.append(PadRow(title: "Function keys", keys:
            [key(VK.escape, 3)] + (0..<12).map { key(VK.f1 + UInt16($0)) }
        ))
        rows.append(PadRow(title: "Number row", keys:
            [key(VK.oem3)]
            + [VK.d1, VK.d2, VK.d3, VK.d4, VK.d5, VK.d6, VK.d7, VK.d8, VK.d9, VK.d0].map { key($0) }
            + [key(VK.oemMinus), key(VK.oemPlus), key(VK.back, 2)]
        ))
        rows.append(PadRow(title: "Top letter row", keys:
            [key(VK.tab, 1.5)]
            + [VK.q, VK.w, VK.e, VK.r, VK.t, VK.y, VK.u, VK.i, VK.o, VK.p].map { key($0) }
            + [key(VK.oem4), key(VK.oem6), key(VK.oem5, 1.5)]
        ))
        rows.append(PadRow(title: "Home row", keys:
            [key(VK.capital, 1.75)]
            + [VK.a, VK.s, VK.d, VK.f, VK.g, VK.h, VK.j, VK.k, VK.l].map { key($0) }
            + [key(VK.oem1), key(VK.oem7), key(VK.return, 2.25)]
        ))
        // German boards are ISO: the 102nd key sits between left Shift and the
        // bottom letter row, so left Shift gives up a unit to make room for it.
        let bottomLetters = [VK.x, VK.c, VK.v, VK.b, VK.n, VK.m].map { key($0) }
        // The leftmost letter is the same *physical* key either way (US VK Z);
        // only its name changes, to Y, because that is what a QWERTZ PC types.
        let leadIn: [PadKey] = layout == .german
            ? [key(VK.shift, 1.25), key(VK.oem102), key(VK.z)]
            : [key(VK.shift, 2.25), key(VK.z)]
        rows.append(PadRow(title: "Bottom letter row", keys:
            leadIn + bottomLetters
            + [key(VK.oemComma), key(VK.oemPeriod), key(VK.oem2), key(VK.shift, 2.75)]
        ))
        rows.append(PadRow(title: "Bottom row", keys: [
            key(VK.control, 1.25), key(VK.lwin, 1.25), key(VK.menu, 1.25),
            key(VK.space, 5),
            key(VK.rmenu, 1.25), key(VK.apps),
            key(VK.left), key(VK.down), key(VK.up), key(VK.right),
        ]))
        #if DEBUG
        // The one invariant a future edit can silently break: rows are laid
        // out by normalising to their own total, so they only line up with
        // each other while every one of them adds up to the same number.
        for row in rows {
            let total = row.keys.reduce(0) { $0 + $1.units }
            assert(
                abs(total - 15) < 0.001,
                "Keyboard row \"\(row.title)\" sums to \(total) units, not 15 — its keys will no longer line up with the rows above and below."
            )
        }
        #endif
        return rows
    }

    /// Every key the keyboard layout can show, named for one PC layout. The
    /// VK is what is sent; only the name and the spoken form differ between
    /// layouts, so "the key that types z" is announced as z on a QWERTZ PC.
    private static func names(for layout: PCKeyboardLayout) -> [UInt16: VirtualKey] {
        func k(_ name: String, _ vk: UInt16, _ spoken: String? = nil) -> (UInt16, VirtualKey) {
            (vk, VirtualKey(name: name, vk: vk, spoken: spoken))
        }
        // Built step by step with explicit types: one big concatenated literal
        // is exactly the shape that makes the type checker give up.
        var table: [UInt16: VirtualKey] = [:]
        let fixed: [(UInt16, VirtualKey)] = [
            // Layout-independent keys.
            k("Esc", VK.escape, "Escape"),
            k("Tab", VK.tab),
            k("Caps", VK.capital, "Caps Lock"),
            k("Shift", VK.shift),
            k("Ctrl", VK.control, "Control"),
            k("Alt", VK.menu),
            k("Win", VK.lwin, "Windows"),
            k("AltGr", VK.rmenu),
            k("Menu", VK.apps, "Context menu"),
            k("Space", VK.space),
            k("Enter", VK.return),
            k("Bksp", VK.back, "Backspace"),
            k("Ins", VK.insert, "Insert"),
            k("Del", VK.delete, "Delete"),
            k("Home", VK.home),
            k("End", VK.end),
            k("PgUp", VK.prior, "Page Up"),
            k("PgDn", VK.next, "Page Down"),
            k("PrtSc", VK.snapshot, "Print Screen"),
            k("Left", VK.left),
            k("Right", VK.right),
            k("Up", VK.up),
            k("Down", VK.down),
        ]
        for entry in fixed { table[entry.0] = entry.1 }
        for index in 0..<12 {
            let entry = k("F\(index + 1)", VK.f1 + UInt16(index))
            table[entry.0] = entry.1
        }
        for digit in 0...9 {
            let entry = k("\(digit)", VK.d0 + UInt16(digit))
            table[entry.0] = entry.1
        }
        for index in 0..<26 {
            let letter = String(UnicodeScalar(UInt8(65 + index)))
            let entry = k(letter, VK.a + UInt16(index))
            table[entry.0] = entry.1
        }

        // Punctuation, named for the PC's layout. Spoken forms exist because
        // a lone symbol is read unpredictably (and sometimes not at all).
        let punctuation: [(UInt16, VirtualKey)]
        switch layout {
        case .us:
            punctuation = [
                k("`", VK.oem3, "Backtick"),
                k("-", VK.oemMinus, "Minus"),
                k("=", VK.oemPlus, "Equals"),
                k("[", VK.oem4, "Left bracket"),
                k("]", VK.oem6, "Right bracket"),
                k("\\", VK.oem5, "Backslash"),
                k(";", VK.oem1, "Semicolon"),
                k("'", VK.oem7, "Apostrophe"),
                k(",", VK.oemComma, "Comma"),
                k(".", VK.oemPeriod, "Period"),
                k("/", VK.oem2, "Slash"),
                k("\\", VK.oem102, "Backslash, 102nd key"),
            ]
        case .german:
            punctuation = [
                k("^", VK.oem3, "Circumflex"),
                k("ß", VK.oemMinus, "Sharp S"),
                k("´", VK.oemPlus, "Acute accent"),
                k("Ü", VK.oem4, "U umlaut"),
                k("+", VK.oem6, "Plus"),
                k("#", VK.oem5, "Hash"),
                k("Ö", VK.oem1, "O umlaut"),
                k("Ä", VK.oem7, "A umlaut"),
                k(",", VK.oemComma, "Comma"),
                k(".", VK.oemPeriod, "Period"),
                k("-", VK.oem2, "Minus"),
                k("<", VK.oem102, "Less than"),
            ]
        }
        for (vk, key) in punctuation { table[vk] = key }

        // QWERTZ swaps the two letters; everything else keeps its position.
        if layout == .german {
            table[VK.y] = VirtualKey(name: "Z", vk: VK.y)
            table[VK.z] = VirtualKey(name: "Y", vk: VK.z)
        }
        return table
    }
}
