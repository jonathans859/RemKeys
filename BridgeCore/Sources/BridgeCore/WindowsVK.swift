import Foundation

/// Windows virtual-key codes (the `VK_*` values from `winuser.h`).
///
/// This is the single source of truth for the numbers that travel over the
/// wire. The Windows agent injects exactly these codes via `SendInput`, so a
/// value here means "the physical Windows key with this VK". Every entry is a
/// real `UInt16` VK — nothing platform-specific about macOS/iOS leaks in.
public enum VK {
    // Control / editing
    public static let back: UInt16 = 0x08          // Backspace
    public static let tab: UInt16 = 0x09
    public static let clear: UInt16 = 0x0C
    public static let `return`: UInt16 = 0x0D       // Enter
    public static let pause: UInt16 = 0x13
    public static let capital: UInt16 = 0x14        // Caps Lock
    public static let escape: UInt16 = 0x1B
    public static let space: UInt16 = 0x20

    // Modifiers (generic + sided)
    public static let shift: UInt16 = 0x10
    public static let control: UInt16 = 0x11
    public static let menu: UInt16 = 0x12           // Alt
    public static let lshift: UInt16 = 0xA0
    public static let rshift: UInt16 = 0xA1
    public static let lcontrol: UInt16 = 0xA2
    public static let rcontrol: UInt16 = 0xA3
    public static let lmenu: UInt16 = 0xA4          // Left Alt
    public static let rmenu: UInt16 = 0xA5          // Right Alt (AltGr)
    public static let lwin: UInt16 = 0x5B
    public static let rwin: UInt16 = 0x5C
    public static let apps: UInt16 = 0x5D           // Menu / context key

    // Navigation cluster
    public static let prior: UInt16 = 0x21          // Page Up
    public static let next: UInt16 = 0x22           // Page Down
    public static let end: UInt16 = 0x23
    public static let home: UInt16 = 0x24
    public static let left: UInt16 = 0x25
    public static let up: UInt16 = 0x26
    public static let right: UInt16 = 0x27
    public static let down: UInt16 = 0x28
    public static let insert: UInt16 = 0x2D
    public static let delete: UInt16 = 0x2E         // Forward Delete
    public static let snapshot: UInt16 = 0x2C       // Print Screen

    // Digits (0-9 map to their ASCII code points)
    public static let d0: UInt16 = 0x30
    public static let d1: UInt16 = 0x31
    public static let d2: UInt16 = 0x32
    public static let d3: UInt16 = 0x33
    public static let d4: UInt16 = 0x34
    public static let d5: UInt16 = 0x35
    public static let d6: UInt16 = 0x36
    public static let d7: UInt16 = 0x37
    public static let d8: UInt16 = 0x38
    public static let d9: UInt16 = 0x39

    // Letters (A-Z map to their ASCII code points)
    public static let a: UInt16 = 0x41
    public static let b: UInt16 = 0x42
    public static let c: UInt16 = 0x43
    public static let d: UInt16 = 0x44
    public static let e: UInt16 = 0x45
    public static let f: UInt16 = 0x46
    public static let g: UInt16 = 0x47
    public static let h: UInt16 = 0x48
    public static let i: UInt16 = 0x49
    public static let j: UInt16 = 0x4A
    public static let k: UInt16 = 0x4B
    public static let l: UInt16 = 0x4C
    public static let m: UInt16 = 0x4D
    public static let n: UInt16 = 0x4E
    public static let o: UInt16 = 0x4F
    public static let p: UInt16 = 0x50
    public static let q: UInt16 = 0x51
    public static let r: UInt16 = 0x52
    public static let s: UInt16 = 0x53
    public static let t: UInt16 = 0x54
    public static let u: UInt16 = 0x55
    public static let v: UInt16 = 0x56
    public static let w: UInt16 = 0x57
    public static let x: UInt16 = 0x58
    public static let y: UInt16 = 0x59
    public static let z: UInt16 = 0x5A

    // Numpad
    public static let numpad0: UInt16 = 0x60
    public static let numpad1: UInt16 = 0x61
    public static let numpad2: UInt16 = 0x62
    public static let numpad3: UInt16 = 0x63
    public static let numpad4: UInt16 = 0x64
    public static let numpad5: UInt16 = 0x65
    public static let numpad6: UInt16 = 0x66
    public static let numpad7: UInt16 = 0x67
    public static let numpad8: UInt16 = 0x68
    public static let numpad9: UInt16 = 0x69
    public static let multiply: UInt16 = 0x6A
    public static let add: UInt16 = 0x6B
    public static let separator: UInt16 = 0x6C
    public static let subtract: UInt16 = 0x6D
    public static let decimal: UInt16 = 0x6E
    public static let divide: UInt16 = 0x6F
    public static let numlock: UInt16 = 0x90
    public static let scroll: UInt16 = 0x91         // Scroll Lock

    // Function keys F1-F24
    public static let f1: UInt16 = 0x70
    public static let f2: UInt16 = 0x71
    public static let f3: UInt16 = 0x72
    public static let f4: UInt16 = 0x73
    public static let f5: UInt16 = 0x74
    public static let f6: UInt16 = 0x75
    public static let f7: UInt16 = 0x76
    public static let f8: UInt16 = 0x77
    public static let f9: UInt16 = 0x78
    public static let f10: UInt16 = 0x79
    public static let f11: UInt16 = 0x7A
    public static let f12: UInt16 = 0x7B
    public static let f13: UInt16 = 0x7C
    public static let f14: UInt16 = 0x7D
    public static let f15: UInt16 = 0x7E
    public static let f16: UInt16 = 0x7F
    public static let f17: UInt16 = 0x80
    public static let f18: UInt16 = 0x81
    public static let f19: UInt16 = 0x82
    public static let f20: UInt16 = 0x83
    public static let f21: UInt16 = 0x84
    public static let f22: UInt16 = 0x85
    public static let f23: UInt16 = 0x86
    public static let f24: UInt16 = 0x87

    // OEM / punctuation (US layout meanings noted; the agent injects the VK,
    // Windows resolves the character against the *Windows* active layout).
    public static let oem1: UInt16 = 0xBA           // ; :
    public static let oemPlus: UInt16 = 0xBB        // = +
    public static let oemComma: UInt16 = 0xBC       // , <
    public static let oemMinus: UInt16 = 0xBD       // - _
    public static let oemPeriod: UInt16 = 0xBE      // . >
    public static let oem2: UInt16 = 0xBF           // / ?
    public static let oem3: UInt16 = 0xC0           // ` ~
    public static let oem4: UInt16 = 0xDB           // [ {
    public static let oem5: UInt16 = 0xDC           // \ |
    public static let oem6: UInt16 = 0xDD           // ] }
    public static let oem7: UInt16 = 0xDE           // ' "
    public static let oem102: UInt16 = 0xE2         // < > or \ | on ISO keyboards

    // Media / volume
    public static let volumeMute: UInt16 = 0xAD
    public static let volumeDown: UInt16 = 0xAE
    public static let volumeUp: UInt16 = 0xAF
    public static let mediaNextTrack: UInt16 = 0xB0
    public static let mediaPrevTrack: UInt16 = 0xB1
    public static let mediaStop: UInt16 = 0xB2
    public static let mediaPlayPause: UInt16 = 0xB3
}
