import Foundation

/// Maps a character to the US-layout key that produces it, for building key
/// *combinations* from typed text (e.g. text "c" + Control ⇒ Ctrl+C).
///
/// This is deliberately the US table: the whole VK path encodes *positions*
/// with US meanings, and the agent's scancode injection lets the PC's active
/// layout interpret them — identical to how physical capture is forwarded.
/// Plain text (no modifiers held) never goes through here; it uses the
/// layout-independent `CharEvent` unicode path instead.
public enum USCharVK {
    /// The key for a character, plus whether US Shift is needed to produce it.
    /// Returns nil for characters with no US key (umlauts, emoji, …).
    public static func key(for character: Character) -> (vk: UInt16, shift: Bool)? {
        // Letters: VK_A–VK_Z; the character's case decides Shift.
        if let ascii = character.asciiValue {
            switch ascii {
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                return (UInt16(ascii - UInt8(ascii: "a")) + VK.a, false)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return (UInt16(ascii - UInt8(ascii: "A")) + VK.a, true)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return (UInt16(ascii - UInt8(ascii: "0")) + VK.d0, false)
            default:
                break
            }
        }
        return table[character]
    }

    private static let table: [Character: (vk: UInt16, shift: Bool)] = [
        " ": (VK.space, false),
        "\n": (VK.return, false),
        "\t": (VK.tab, false),
        // Unshifted US punctuation row keys
        "-": (VK.oemMinus, false), "=": (VK.oemPlus, false),
        "[": (VK.oem4, false), "]": (VK.oem6, false), "\\": (VK.oem5, false),
        ";": (VK.oem1, false), "'": (VK.oem7, false), "`": (VK.oem3, false),
        ",": (VK.oemComma, false), ".": (VK.oemPeriod, false), "/": (VK.oem2, false),
        // Shifted digits
        "!": (VK.d1, true), "@": (VK.d2, true), "#": (VK.d3, true),
        "$": (VK.d4, true), "%": (VK.d5, true), "^": (VK.d6, true),
        "&": (VK.d7, true), "*": (VK.d8, true), "(": (VK.d9, true),
        ")": (VK.d0, true),
        // Shifted punctuation
        "_": (VK.oemMinus, true), "+": (VK.oemPlus, true),
        "{": (VK.oem4, true), "}": (VK.oem6, true), "|": (VK.oem5, true),
        ":": (VK.oem1, true), "\"": (VK.oem7, true), "~": (VK.oem3, true),
        "<": (VK.oemComma, true), ">": (VK.oemPeriod, true), "?": (VK.oem2, true),
    ]
}
