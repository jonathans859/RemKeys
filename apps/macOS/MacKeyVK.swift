import CoreGraphics
import os
import BridgeCore

/// Maps a macOS `CGKeyCode` to a Windows virtual-key code.
///
/// Complete table, not a common subset: full alphanumerics, every modifier
/// individually (left/right Option and Command routed through the configurable
/// mappings), F1–F20, numpad, the nav/edit cluster, and the media keys the Mac
/// exposes as key codes. Unmapped codes return nil and are logged so gaps show
/// up during testing rather than vanishing.
enum MacKeyVK {
    private static let log = Logger(subsystem: "com.jonathan859.keybridge", category: "MacKeyVK")

    static func vk(
        forKeyCode keyCode: CGKeyCode,
        leftOptionMapping: ModifierMapping,
        rightOptionMapping: ModifierMapping,
        leftCommandMapping: ModifierMapping,
        rightCommandMapping: ModifierMapping
    ) -> UInt16? {
        switch keyCode {
        // MARK: Letters
        case 0x00: return VK.a
        case 0x0B: return VK.b
        case 0x08: return VK.c
        case 0x02: return VK.d
        case 0x0E: return VK.e
        case 0x03: return VK.f
        case 0x05: return VK.g
        case 0x04: return VK.h
        case 0x22: return VK.i
        case 0x26: return VK.j
        case 0x28: return VK.k
        case 0x25: return VK.l
        case 0x2E: return VK.m
        case 0x2D: return VK.n
        case 0x1F: return VK.o
        case 0x23: return VK.p
        case 0x0C: return VK.q
        case 0x0F: return VK.r
        case 0x01: return VK.s
        case 0x11: return VK.t
        case 0x20: return VK.u
        case 0x09: return VK.v
        case 0x0D: return VK.w
        case 0x07: return VK.x
        case 0x10: return VK.y
        case 0x06: return VK.z

        // MARK: Top-row digits
        case 0x12: return VK.d1
        case 0x13: return VK.d2
        case 0x14: return VK.d3
        case 0x15: return VK.d4
        case 0x17: return VK.d5
        case 0x16: return VK.d6
        case 0x1A: return VK.d7
        case 0x1C: return VK.d8
        case 0x19: return VK.d9
        case 0x1D: return VK.d0

        // MARK: Punctuation (US layout meanings)
        case 0x1B: return VK.oemMinus     // - _
        case 0x18: return VK.oemPlus      // = +
        case 0x21: return VK.oem4         // [ {
        case 0x1E: return VK.oem6         // ] }
        case 0x2A: return VK.oem5         // \ |
        case 0x29: return VK.oem1         // ; :
        case 0x27: return VK.oem7         // ' "
        case 0x2B: return VK.oemComma     // , <
        case 0x2F: return VK.oemPeriod    // . >
        case 0x2C: return VK.oem2         // / ?
        case 0x32: return VK.oem3         // ` ~
        case 0x0A: return VK.oem102       // ISO § / < >

        // MARK: Editing / whitespace
        case 0x24: return VK.return
        case 0x30: return VK.tab
        case 0x31: return VK.space
        case 0x33: return VK.back          // Delete (Backspace)
        case 0x35: return VK.escape
        case 0x75: return VK.delete        // Forward Delete
        case 0x72: return VK.insert        // Help / Insert

        // MARK: Navigation cluster
        case 0x73: return VK.home
        case 0x77: return VK.end
        case 0x74: return VK.prior         // Page Up
        case 0x79: return VK.next          // Page Down
        case 0x7B: return VK.left
        case 0x7C: return VK.right
        case 0x7D: return VK.down
        case 0x7E: return VK.up

        // MARK: Function keys F1–F20
        case 0x7A: return VK.f1
        case 0x78: return VK.f2
        case 0x63: return VK.f3
        case 0x76: return VK.f4
        case 0x60: return VK.f5
        case 0x61: return VK.f6
        case 0x62: return VK.f7
        case 0x64: return VK.f8
        case 0x65: return VK.f9
        case 0x6D: return VK.f10
        case 0x67: return VK.f11
        case 0x6F: return VK.f12
        case 0x69: return VK.f13
        case 0x6B: return VK.f14
        case 0x71: return VK.f15
        case 0x6A: return VK.f16
        case 0x40: return VK.f17
        case 0x4F: return VK.f18
        case 0x50: return VK.f19
        case 0x5A: return VK.f20

        // MARK: Numpad
        case 0x52: return VK.numpad0
        case 0x53: return VK.numpad1
        case 0x54: return VK.numpad2
        case 0x55: return VK.numpad3
        case 0x56: return VK.numpad4
        case 0x57: return VK.numpad5
        case 0x58: return VK.numpad6
        case 0x59: return VK.numpad7
        case 0x5B: return VK.numpad8
        case 0x5C: return VK.numpad9
        case 0x41: return VK.decimal
        case 0x43: return VK.multiply
        case 0x45: return VK.add
        case 0x4B: return VK.divide
        case 0x4C: return VK.return        // Keypad Enter
        case 0x4E: return VK.subtract
        case 0x51: return VK.oemPlus       // Keypad = (no VK_NUMPAD equal)
        case 0x47: return VK.numlock       // Keypad Clear ≈ Num Lock

        // MARK: Media keys exposed as key codes
        case 0x48: return VK.volumeUp
        case 0x49: return VK.volumeDown
        case 0x4A: return VK.volumeMute

        // MARK: Modifiers (individually)
        case 0x38, 0x3C: return VK.shift        // Left / Right Shift
        case 0x3B, 0x3E: return VK.control      // Left / Right Control
        case 0x3A: return leftOptionMapping.vk  // Left Option
        case 0x3D: return rightOptionMapping.vk // Right Option
        case 0x37: return leftCommandMapping.vk  // Left Command
        case 0x36: return rightCommandMapping.vk // Right Command
        // Caps Lock is handled via the HID hook (real down/up); it never
        // reaches this table for forwarding.

        default:
            log.notice("Unmapped macOS key code: \(keyCode, privacy: .public)")
            return nil
        }
    }
}
