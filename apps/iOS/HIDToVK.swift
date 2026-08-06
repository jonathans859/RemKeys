import UIKit
import os
import BridgeCore

/// Maps a UIKit `UIKey` (HID usage code) to a Windows virtual-key code.
///
/// Built as an explicit, complete table rather than a "common subset": full
/// alphanumerics, every modifier individually, F1–F24, numpad, the nav/edit
/// cluster, and media keys UIKit exposes. Anything with no Windows equivalent
/// returns nil and is logged by the caller, so coverage gaps are visible
/// during on-device testing instead of silently swallowed.
enum HIDToVK {
    private static let log = Logger(subsystem: "com.jonathan859.keybridge", category: "HIDToVK")

    static func vk(
        for key: UIKey,
        leftOptionMapping: ModifierMapping,
        rightOptionMapping: ModifierMapping,
        leftCommandMapping: ModifierMapping,
        rightCommandMapping: ModifierMapping
    ) -> UInt16? {
        vk(
            for: key.keyCode,
            leftOptionMapping: leftOptionMapping,
            rightOptionMapping: rightOptionMapping,
            leftCommandMapping: leftCommandMapping,
            rightCommandMapping: rightCommandMapping
        )
    }

    /// Usage-based entry point. The table is keyed on the HID usage alone so
    /// GameController (`GCKeyCode` raw values *are* HID usages) resolves
    /// through exactly the same mapping as UIKit's `UIKey`.
    static func vk(
        for usage: UIKeyboardHIDUsage,
        leftOptionMapping: ModifierMapping,
        rightOptionMapping: ModifierMapping,
        leftCommandMapping: ModifierMapping,
        rightCommandMapping: ModifierMapping
    ) -> UInt16? {
        switch usage {
        // MARK: Letters
        case .keyboardA: return VK.a
        case .keyboardB: return VK.b
        case .keyboardC: return VK.c
        case .keyboardD: return VK.d
        case .keyboardE: return VK.e
        case .keyboardF: return VK.f
        case .keyboardG: return VK.g
        case .keyboardH: return VK.h
        case .keyboardI: return VK.i
        case .keyboardJ: return VK.j
        case .keyboardK: return VK.k
        case .keyboardL: return VK.l
        case .keyboardM: return VK.m
        case .keyboardN: return VK.n
        case .keyboardO: return VK.o
        case .keyboardP: return VK.p
        case .keyboardQ: return VK.q
        case .keyboardR: return VK.r
        case .keyboardS: return VK.s
        case .keyboardT: return VK.t
        case .keyboardU: return VK.u
        case .keyboardV: return VK.v
        case .keyboardW: return VK.w
        case .keyboardX: return VK.x
        case .keyboardY: return VK.y
        case .keyboardZ: return VK.z

        // MARK: Top-row digits
        case .keyboard1: return VK.d1
        case .keyboard2: return VK.d2
        case .keyboard3: return VK.d3
        case .keyboard4: return VK.d4
        case .keyboard5: return VK.d5
        case .keyboard6: return VK.d6
        case .keyboard7: return VK.d7
        case .keyboard8: return VK.d8
        case .keyboard9: return VK.d9
        case .keyboard0: return VK.d0

        // MARK: Editing / whitespace
        case .keyboardReturnOrEnter: return VK.return
        case .keyboardEscape: return VK.escape
        case .keyboardDeleteOrBackspace: return VK.back
        case .keyboardTab: return VK.tab
        case .keyboardSpacebar: return VK.space

        // MARK: Punctuation (US layout meanings)
        case .keyboardHyphen: return VK.oemMinus
        case .keyboardEqualSign: return VK.oemPlus
        case .keyboardOpenBracket: return VK.oem4
        case .keyboardCloseBracket: return VK.oem6
        case .keyboardBackslash: return VK.oem5
        case .keyboardNonUSPound: return VK.oem5
        case .keyboardSemicolon: return VK.oem1
        case .keyboardQuote: return VK.oem7
        case .keyboardGraveAccentAndTilde: return VK.oem3
        case .keyboardComma: return VK.oemComma
        case .keyboardPeriod: return VK.oemPeriod
        case .keyboardSlash: return VK.oem2
        case .keyboardNonUSBackslash: return VK.oem102

        // MARK: Locks
        case .keyboardCapsLock: return VK.capital
        case .keypadNumLock: return VK.numlock
        case .keyboardScrollLock: return VK.scroll

        // MARK: Function keys
        case .keyboardF1: return VK.f1
        case .keyboardF2: return VK.f2
        case .keyboardF3: return VK.f3
        case .keyboardF4: return VK.f4
        case .keyboardF5: return VK.f5
        case .keyboardF6: return VK.f6
        case .keyboardF7: return VK.f7
        case .keyboardF8: return VK.f8
        case .keyboardF9: return VK.f9
        case .keyboardF10: return VK.f10
        case .keyboardF11: return VK.f11
        case .keyboardF12: return VK.f12
        case .keyboardF13: return VK.f13
        case .keyboardF14: return VK.f14
        case .keyboardF15: return VK.f15
        case .keyboardF16: return VK.f16
        case .keyboardF17: return VK.f17
        case .keyboardF18: return VK.f18
        case .keyboardF19: return VK.f19
        case .keyboardF20: return VK.f20
        case .keyboardF21: return VK.f21
        case .keyboardF22: return VK.f22
        case .keyboardF23: return VK.f23
        case .keyboardF24: return VK.f24

        // MARK: Navigation / editing cluster
        case .keyboardPrintScreen: return VK.snapshot
        case .keyboardPause: return VK.pause
        case .keyboardInsert: return VK.insert
        case .keyboardHome: return VK.home
        case .keyboardPageUp: return VK.prior
        case .keyboardDeleteForward: return VK.delete
        case .keyboardEnd: return VK.end
        case .keyboardPageDown: return VK.next
        case .keyboardRightArrow: return VK.right
        case .keyboardLeftArrow: return VK.left
        case .keyboardDownArrow: return VK.down
        case .keyboardUpArrow: return VK.up
        case .keyboardApplication: return VK.apps

        // MARK: Numpad
        case .keypad0: return VK.numpad0
        case .keypad1: return VK.numpad1
        case .keypad2: return VK.numpad2
        case .keypad3: return VK.numpad3
        case .keypad4: return VK.numpad4
        case .keypad5: return VK.numpad5
        case .keypad6: return VK.numpad6
        case .keypad7: return VK.numpad7
        case .keypad8: return VK.numpad8
        case .keypad9: return VK.numpad9
        case .keypadSlash: return VK.divide
        case .keypadAsterisk: return VK.multiply
        case .keypadHyphen: return VK.subtract
        case .keypadPlus: return VK.add
        case .keypadEnter: return VK.return
        case .keypadPeriod: return VK.decimal
        case .keypadEqualSign: return VK.oemPlus

        // MARK: Modifiers (individually, not as flags)
        case .keyboardLeftShift, .keyboardRightShift:
            return VK.shift
        case .keyboardLeftControl, .keyboardRightControl:
            return VK.control
        // Option and Command map per physical side: PC-style keyboards
        // present their right-of-space cluster as the *right* variants, and
        // e.g. AltGr only makes sense on the right key.
        case .keyboardLeftAlt: return leftOptionMapping.vk
        case .keyboardRightAlt: return rightOptionMapping.vk
        case .keyboardLeftGUI: return leftCommandMapping.vk
        case .keyboardRightGUI: return rightCommandMapping.vk

        default:
            return nil
        }
    }

    /// Log a key we couldn't map so testing surfaces the gap.
    static func logUnmapped(_ key: UIKey) {
        log.notice("Unmapped key: hidUsage=\(key.keyCode.rawValue, privacy: .public) chars=\(key.characters, privacy: .public)")
    }

    /// Same, for a source that only knows the usage (GameController).
    static func logUnmapped(usage: UIKeyboardHIDUsage) {
        log.notice("Unmapped key: hidUsage=\(usage.rawValue, privacy: .public)")
    }

    // MARK: Toggle-shortcut support

    /// True if the key is a modifier — never valid as a shortcut's *main* key.
    static func isModifier(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    /// Translate a key event's live modifier flags into the platform-neutral set.
    static func modifiers(from flags: UIKeyModifierFlags) -> Set<ShortcutModifier> {
        var mods: Set<ShortcutModifier> = []
        if flags.contains(.alphaShift) { mods.insert(.capsLock) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.alternate) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        return mods
    }

    /// Readable name of a key for labeling a recorded shortcut. Special/function
    /// keys come from a table; printable keys use the character they produce.
    static func keyName(for key: UIKey) -> String {
        if let special = specialNames[key.keyCode] { return special }
        let chars = key.charactersIgnoringModifiers
        if let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F {
            return chars.uppercased()
        }
        return "Key \(key.keyCode.rawValue)"
    }

    /// Readable name from a bare usage — the GameController path has no
    /// `UIKey`, so letters and digits are derived from the usage ranges.
    static func keyName(forUsage usage: UIKeyboardHIDUsage) -> String {
        if let special = specialNames[usage] { return special }
        let raw = usage.rawValue
        let firstLetter = UIKeyboardHIDUsage.keyboardA.rawValue
        if raw >= firstLetter, raw <= UIKeyboardHIDUsage.keyboardZ.rawValue {
            let scalar = Unicode.Scalar(UInt8(ascii: "A") + UInt8(raw - firstLetter))
            return String(Character(scalar))
        }
        if raw >= UIKeyboardHIDUsage.keyboard1.rawValue, raw <= UIKeyboardHIDUsage.keyboard0.rawValue {
            let digit = raw == UIKeyboardHIDUsage.keyboard0.rawValue
                ? 0
                : raw - UIKeyboardHIDUsage.keyboard1.rawValue + 1
            return String(digit)
        }
        return "Key \(raw)"
    }

    private static let specialNames: [UIKeyboardHIDUsage: String] = [
        // Modifiers first — the Diagnostics "Last key seen" row uses these to
        // reveal what a physical key actually sends (e.g. an MX Keys
        // Win-labeled key arriving as Command).
        .keyboardLeftShift: "Left Shift", .keyboardRightShift: "Right Shift",
        .keyboardLeftControl: "Left Control", .keyboardRightControl: "Right Control",
        .keyboardLeftAlt: "Left Option", .keyboardRightAlt: "Right Option",
        .keyboardLeftGUI: "Left Command", .keyboardRightGUI: "Right Command",
        .keyboardCapsLock: "Caps Lock",
        .keyboardReturnOrEnter: "Return", .keyboardTab: "Tab",
        .keyboardSpacebar: "Space", .keyboardDeleteOrBackspace: "Delete",
        .keyboardEscape: "Escape", .keyboardDeleteForward: "Forward Delete",
        .keyboardHome: "Home", .keyboardEnd: "End",
        .keyboardPageUp: "Page Up", .keyboardPageDown: "Page Down",
        .keyboardLeftArrow: "Left", .keyboardRightArrow: "Right",
        .keyboardDownArrow: "Down", .keyboardUpArrow: "Up",
        .keyboardF1: "F1", .keyboardF2: "F2", .keyboardF3: "F3",
        .keyboardF4: "F4", .keyboardF5: "F5", .keyboardF6: "F6",
        .keyboardF7: "F7", .keyboardF8: "F8", .keyboardF9: "F9",
        .keyboardF10: "F10", .keyboardF11: "F11", .keyboardF12: "F12",
        .keyboardF13: "F13", .keyboardF14: "F14", .keyboardF15: "F15",
        .keyboardF16: "F16", .keyboardF17: "F17", .keyboardF18: "F18",
        .keyboardF19: "F19", .keyboardF20: "F20", .keyboardF21: "F21",
        .keyboardF22: "F22", .keyboardF23: "F23", .keyboardF24: "F24",
    ]
}
