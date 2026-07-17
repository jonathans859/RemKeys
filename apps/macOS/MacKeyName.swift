import CoreGraphics

/// Human-readable names for `CGKeyCode`s, used only to label a recorded toggle
/// shortcut (e.g. "F11", "A", "Space"). Special/function/nav keys come from a
/// table; everything else falls back to the character the key would type, so
/// letters, digits, and punctuation read naturally without an exhaustive list.
enum MacKeyName {
    static func name(forKeyCode keyCode: CGKeyCode, event: CGEvent) -> String {
        if let special = special[keyCode] { return special }

        // Fall back to the produced character (display only). Strip modifiers so
        // e.g. Option+A still reads as "A" rather than an accented variant.
        let unmodified = event.copy()
        unmodified?.flags = []
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        (unmodified ?? event).keyboardGetUnicodeString(
            maxStringLength: 4, actualStringLength: &length, unicodeString: &chars
        )
        if length > 0 {
            let s = String(utf16CodeUnits: chars, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F {
                return s.uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    private static let special: [CGKeyCode: String] = [
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
        0x35: "Escape", 0x75: "Forward Delete",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]
}
