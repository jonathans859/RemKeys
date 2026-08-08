import Carbon.HIToolbox
import CoreGraphics

/// Named `CGKeyCode` (Apple virtual key code) constants used by the capture
/// layer. These are the ANSI/`kVK_*` codes from Carbon `HIToolbox/Events.h`,
/// reproduced here rather than read from the framework so the table reads the
/// same as `MacKeyVK`.
enum MacKeyCode {
    static let capsLock: CGKeyCode = 0x39   // 57
    static let f11: CGKeyCode = 0x67        // 103
    static let escape: CGKeyCode = 0x35     // 53 — cancels shortcut recording
}

/// Per-modifier-key flag bits, used to read a `flagsChanged` event's
/// **direction**.
///
/// A `flagsChanged` event says *which* modifier key changed (its key code) but
/// not whether it went down or up. The obvious workaround — toggle a set of
/// held key codes — is wrong in exactly the case that matters: any transition
/// the tap doesn't see (a chord swallowed by the toggle shortcut, a modifier
/// released while the tap was disabled, a key still held when capture starts)
/// inverts that key's direction for the rest of the session, so the *release*
/// of a modifier gets forwarded as a press and sticks on the remote.
///
/// The event carries the answer already: its `flags` are the state *after* the
/// transition, and each physical modifier key owns a bit
/// (`NX_DEVICE…KEYMASK`, IOKit `IOLLEvent.h`) that distinguishes left from
/// right. Testing this key's own bit gives the direction directly and can't
/// drift, because every event re-states the truth.
enum MacModifierFlag {
    /// Device-dependent (side-specific) mask per modifier key code, plus fn,
    /// which has no sides and uses the public `maskSecondaryFn`.
    private static let bits: [CGKeyCode: UInt64] = [
        0x38: 0x0000_0002,  // Left Shift    NX_DEVICELSHIFTKEYMASK
        0x3C: 0x0000_0004,  // Right Shift   NX_DEVICERSHIFTKEYMASK
        0x3B: 0x0000_0001,  // Left Control  NX_DEVICELCTLKEYMASK
        0x3E: 0x0000_2000,  // Right Control NX_DEVICERCTLKEYMASK
        0x3A: 0x0000_0020,  // Left Option   NX_DEVICELALTKEYMASK
        0x3D: 0x0000_0040,  // Right Option  NX_DEVICERALTKEYMASK
        0x37: 0x0000_0008,  // Left Command  NX_DEVICELCMDKEYMASK
        0x36: 0x0000_0010,  // Right Command NX_DEVICERCMDKEYMASK
        0x3F: CGEventFlags.maskSecondaryFn.rawValue,  // fn
    ]

    /// True/false if the event's own flags settle the direction for this
    /// modifier key; nil for a key code we have no bit for (caller falls back
    /// to inferring the direction).
    static func isPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool? {
        guard let bit = bits[keyCode] else { return nil }
        return flags.rawValue & bit != 0
    }
}

/// Whether the keyboard that produced an event has a physical **ISO** layout.
///
/// It matters for exactly two key codes — `0x32` and `0x0A` sit in opposite
/// positions on ISO and ANSI boards (see `MacKeyVK`). Read per event rather
/// than from `LMGetKbdType()` so a Mac with, say, an ANSI internal keyboard and
/// an external ISO one gets each keystroke right.
enum MacKeyboardLayout {
    static func isISO(_ event: CGEvent) -> Bool {
        let type = Int16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType))
        return KBGetLayoutType(type) == OSType(kKeyboardISO)
    }
}
