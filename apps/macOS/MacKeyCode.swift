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
