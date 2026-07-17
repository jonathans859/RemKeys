import CoreGraphics

/// Named `CGKeyCode` (Apple virtual key code) constants used by the capture
/// layer. These are the ANSI/`kVK_*` codes from Carbon `HIToolbox/Events.h`,
/// reproduced here so we don't pull in Carbon just for the enum.
enum MacKeyCode {
    static let capsLock: CGKeyCode = 0x39   // 57
    static let f11: CGKeyCode = 0x67        // 103
    static let escape: CGKeyCode = 0x35     // 53 — cancels shortcut recording
}
