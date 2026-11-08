import Foundation

/// One Windows key the pad editor offers, with the names it is shown and
/// spoken under.
public struct CatalogKey: Identifiable, Equatable, Sendable {
    /// The Windows VK it sends.
    public let vk: UInt16
    /// Visible name — short enough to sit inside a pad zone ("Page Up",
    /// "Ctrl").
    public let name: String
    /// What VoiceOver says when the visible name doesn't survive being
    /// spoken ("Ctrl" → "Control", "Menu" → "Context menu").
    private let spoken: String?

    public init(vk: UInt16, name: String, spoken: String? = nil) {
        self.vk = vk
        self.name = name
        self.spoken = spoken
    }

    public var spokenName: String { spoken ?? name }
    public var id: UInt16 { vk }
}

/// A heading in the key picker.
public struct KeyCategory: Identifiable, Sendable {
    public let title: String
    public let keys: [CatalogKey]
    public var id: String { title }

    public init(title: String, keys: [CatalogKey]) {
        self.title = title
        self.keys = keys
    }
}

/// Every key a pad can carry, and how keys and fixed combinations are named.
///
/// This is the pad's whole vocabulary: the editor's picker lists exactly
/// these, and a VK that is somehow not in here (a record written by a future
/// version) still gets a readable fallback name rather than a blank zone.
public enum KeyCatalog {
    /// The six keys that **toggle** on the pad instead of sending, in the
    /// order they are announced and pressed on the PC.
    ///
    /// Caps Lock is one of them because on the PC it *is* a modifier in the
    /// case that matters: NVDA's desktop layout uses it as the screen-reader
    /// key, which only works if it wraps the key it modifies. AltGr is right
    /// Alt (`VK_RMENU`) — virtual input picks Windows keys directly, so no
    /// `ModifierMapping` is involved.
    public static let modifiers: [CatalogKey] = [
        CatalogKey(vk: VK.control, name: "Ctrl", spoken: "Control"),
        CatalogKey(vk: VK.shift, name: "Shift"),
        CatalogKey(vk: VK.menu, name: "Alt"),
        CatalogKey(vk: VK.lwin, name: "Win", spoken: "Windows"),
        CatalogKey(vk: VK.rmenu, name: "AltGr"),
        CatalogKey(vk: VK.capital, name: "Caps", spoken: "Caps Lock"),
    ]

    public static let modifierVKs: Set<UInt16> = Set(modifiers.map(\.vk))

    public static func isModifier(_ vk: UInt16) -> Bool { modifierVKs.contains(vk) }

    /// `vks` in canonical modifier order, dropping anything that isn't one of
    /// the six. Used for both the press order and the name of a combination,
    /// so "Ctrl+Shift+Esc" is always spelled — and pressed — the same way.
    public static func orderedModifiers<S: Sequence>(_ vks: S) -> [UInt16] where S.Element == UInt16 {
        let set = Set(vks)
        return modifiers.map(\.vk).filter { set.contains($0) }
    }

    public static let categories: [KeyCategory] = [
        KeyCategory(title: "Navigation", keys: [
            CatalogKey(vk: VK.up, name: "Up"),
            CatalogKey(vk: VK.down, name: "Down"),
            CatalogKey(vk: VK.left, name: "Left"),
            CatalogKey(vk: VK.right, name: "Right"),
            CatalogKey(vk: VK.home, name: "Home"),
            CatalogKey(vk: VK.end, name: "End"),
            CatalogKey(vk: VK.prior, name: "Page Up"),
            CatalogKey(vk: VK.next, name: "Page Down"),
        ]),
        KeyCategory(title: "Editing", keys: [
            CatalogKey(vk: VK.return, name: "Enter"),
            CatalogKey(vk: VK.escape, name: "Escape"),
            CatalogKey(vk: VK.tab, name: "Tab"),
            CatalogKey(vk: VK.space, name: "Space"),
            CatalogKey(vk: VK.back, name: "Backspace"),
            CatalogKey(vk: VK.delete, name: "Delete"),
            CatalogKey(vk: VK.insert, name: "Insert"),
            CatalogKey(vk: VK.apps, name: "Menu", spoken: "Context menu"),
        ]),
        KeyCategory(title: "Modifiers", keys: modifiers),
        KeyCategory(title: "Function keys", keys: (1...24).map {
            CatalogKey(vk: VK.f1 + UInt16($0 - 1), name: "F\($0)")
        }),
        KeyCategory(title: "Letters", keys: (0..<26).map {
            let vk = VK.a + UInt16($0)
            return CatalogKey(vk: vk, name: String(UnicodeScalar(UInt8(vk))))
        }),
        KeyCategory(title: "Digits", keys: (0...9).map {
            CatalogKey(vk: VK.d0 + UInt16($0), name: "\($0)")
        }),
        // Named by their US-layout position, the same convention `USCharVK`
        // uses: the PC resolves the character against its own layout.
        KeyCategory(title: "Punctuation", keys: [
            CatalogKey(vk: VK.oemMinus, name: "-", spoken: "Minus"),
            CatalogKey(vk: VK.oemPlus, name: "=", spoken: "Equals"),
            CatalogKey(vk: VK.oem4, name: "[", spoken: "Left bracket"),
            CatalogKey(vk: VK.oem6, name: "]", spoken: "Right bracket"),
            CatalogKey(vk: VK.oem5, name: "\\", spoken: "Backslash"),
            CatalogKey(vk: VK.oem1, name: ";", spoken: "Semicolon"),
            CatalogKey(vk: VK.oem7, name: "'", spoken: "Apostrophe"),
            CatalogKey(vk: VK.oem3, name: "`", spoken: "Grave accent"),
            CatalogKey(vk: VK.oemComma, name: ",", spoken: "Comma"),
            CatalogKey(vk: VK.oemPeriod, name: ".", spoken: "Period"),
            CatalogKey(vk: VK.oem2, name: "/", spoken: "Slash"),
            CatalogKey(vk: VK.oem102, name: "ISO <>", spoken: "ISO angle bracket key"),
        ]),
        KeyCategory(title: "Numpad", keys: (0...9).map {
            CatalogKey(vk: VK.numpad0 + UInt16($0), name: "Num \($0)", spoken: "Numpad \($0)")
        } + [
            CatalogKey(vk: VK.multiply, name: "Num *", spoken: "Numpad multiply"),
            CatalogKey(vk: VK.add, name: "Num +", spoken: "Numpad plus"),
            CatalogKey(vk: VK.subtract, name: "Num -", spoken: "Numpad minus"),
            CatalogKey(vk: VK.divide, name: "Num /", spoken: "Numpad divide"),
            CatalogKey(vk: VK.decimal, name: "Num .", spoken: "Numpad decimal"),
            CatalogKey(vk: VK.numlock, name: "Num Lock"),
        ]),
        KeyCategory(title: "Media and volume", keys: [
            CatalogKey(vk: VK.mediaPlayPause, name: "Play/Pause", spoken: "Play pause"),
            CatalogKey(vk: VK.mediaStop, name: "Stop"),
            CatalogKey(vk: VK.mediaPrevTrack, name: "Previous Track"),
            CatalogKey(vk: VK.mediaNextTrack, name: "Next Track"),
            CatalogKey(vk: VK.volumeMute, name: "Mute"),
            CatalogKey(vk: VK.volumeDown, name: "Volume Down"),
            CatalogKey(vk: VK.volumeUp, name: "Volume Up"),
        ]),
        KeyCategory(title: "Other", keys: [
            CatalogKey(vk: VK.snapshot, name: "Print Screen"),
            CatalogKey(vk: VK.pause, name: "Pause"),
            CatalogKey(vk: VK.scroll, name: "Scroll Lock"),
        ]),
    ]

    private static let byVK: [UInt16: CatalogKey] = {
        var table: [UInt16: CatalogKey] = [:]
        for key in categories.flatMap(\.keys) where table[key.vk] == nil {
            table[key.vk] = key
        }
        return table
    }()

    public static func entry(for vk: UInt16) -> CatalogKey? { byVK[vk] }

    public static func name(for vk: UInt16) -> String {
        byVK[vk]?.name ?? "Key \(vk)"
    }

    public static func spokenName(for vk: UInt16) -> String {
        byVK[vk]?.spokenName ?? "Key \(vk)"
    }

    /// Visible name of a key plus fixed modifiers: "Ctrl+Shift+Esc".
    public static func comboName(vk: UInt16, modifiers: Set<UInt16>) -> String {
        (orderedModifiers(modifiers).filter { $0 != vk }.map(name(for:)) + [name(for: vk)])
            .joined(separator: "+")
    }

    /// Spoken name of the same: "Control + Shift + Escape". The separator is
    /// the one Send's hint already uses, so a combination sounds the same
    /// wherever it is described.
    public static func spokenComboName(vk: UInt16, modifiers: Set<UInt16>) -> String {
        (orderedModifiers(modifiers).filter { $0 != vk }.map(spokenName(for:)) + [spokenName(for: vk)])
            .joined(separator: " + ")
    }
}
