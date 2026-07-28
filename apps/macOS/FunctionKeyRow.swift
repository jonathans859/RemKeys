import Foundation
import os

/// Makes the Mac's function-key row send plain **F1–F12** while forwarding is
/// on, so the top row reaches the Windows PC without holding fn.
///
/// Why not a tap trick: with "Use F1, F2, etc. keys as standard function keys"
/// *off* (the macOS default), the fn row never becomes a key event at all. The
/// keyboard emits Apple-vendor / consumer HID usages instead — brightness down
/// is `0xFF00000005`, play/pause `0xC000000CD`, Mission Control
/// `0xFF0100000010` — and the system turns those into brightness / volume /
/// Mission Control actions *below* the event tap. There is no keyDown for a
/// `CGEventTap` to see, forward, or swallow.
///
/// The supported fix is HID usage remapping (Apple TN2450): `hidutil property
/// --set UserKeyMapping` rewrites those usages to the keyboard-page F1–F12
/// usages before anything above the HID layer sees them, so they arrive at the
/// tap as ordinary F-key events and travel the normal `MacKeyVK` path. It needs
/// no root, takes effect immediately, applies to every attached keyboard, and
/// is gone at reboot.
///
/// Because the mapping is **system-wide, one list per user**, it is installed
/// only while forwarding is active and cleared the moment forwarding stops (and
/// on quit). Clearing resets the list to empty, so a personal `hidutil`
/// remapping the user installed by hand goes with it.
enum FunctionKeyRow {
    private static let log = Logger(subsystem: "com.jonathan859.keybridge", category: "FunctionKeyRow")

    /// `hidutil` usage values are `(HID page << 32) | usage`.
    private enum FKey {
        static let f1: UInt64 = 0x70000003A
        static let f2: UInt64 = 0x70000003B
        static let f3: UInt64 = 0x70000003C
        static let f4: UInt64 = 0x70000003D
        static let f5: UInt64 = 0x70000003E
        static let f6: UInt64 = 0x70000003F
        static let f7: UInt64 = 0x700000040
        static let f8: UInt64 = 0x700000041
        static let f9: UInt64 = 0x700000042
        static let f10: UInt64 = 0x700000043
        static let f11: UInt64 = 0x700000044
        static let f12: UInt64 = 0x700000045
    }

    /// Special-function usage → F-key. Deliberately a superset: it covers the
    /// modern fn row (Spotlight / dictation / Do Not Disturb) *and* the older
    /// one (Launchpad / keyboard illumination), plus both spellings of the
    /// media transport keys. A source no attached keyboard emits is simply
    /// never hit, so extra rows cost nothing.
    private static let mappings: [(source: UInt64, fKey: UInt64)] = [
        (0xFF00000005, FKey.f1),    // Brightness down
        (0xFF00000004, FKey.f2),    // Brightness up
        (0xFF0100000010, FKey.f3),  // Mission Control (Exposé, all windows)
        (0xC00000221, FKey.f4),     // Spotlight (AC Search)
        (0xFF0100000002, FKey.f4),  // Launchpad (older fn rows)
        (0xC000000CF, FKey.f5),     // Dictation (voice command)
        (0xFF00000009, FKey.f5),    // Keyboard illumination down (older)
        (0x10000009B, FKey.f6),     // Do Not Disturb / Focus
        (0xFF00000008, FKey.f6),    // Keyboard illumination up (older)
        (0xC000000B4, FKey.f7),     // Rewind
        (0xC000000B6, FKey.f7),     // Scan previous track
        (0xC000000CD, FKey.f8),     // Play / pause
        (0xC000000B3, FKey.f9),     // Fast-forward
        (0xC000000B5, FKey.f9),     // Scan next track
        (0xC000000E2, FKey.f10),    // Mute
        (0xC000000EA, FKey.f11),    // Volume down
        (0xC000000E9, FKey.f12),    // Volume up
    ]

    /// Serialises the `hidutil` calls and keeps them off the main thread — the
    /// event tap is disabled by the system if the main run loop stalls.
    private static let queue = DispatchQueue(label: "com.jonathan859.keybridge.hidutil")

    /// Remap the fn row to F1–F12 for every attached keyboard.
    static func apply() {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":0x\(String($0.source, radix: 16))," +
            "\"HIDKeyboardModifierMappingDst\":0x\(String($0.fKey, radix: 16))}"
        }
        setProperty("{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}")
    }

    /// Hand the fn row back to macOS. `waitForCompletion` is for app
    /// termination: the remap outlives the process, so the reset must have run
    /// before we exit.
    static func clear(waitForCompletion: Bool = false) {
        setProperty("{\"UserKeyMapping\":[]}", waitForCompletion: waitForCompletion)
    }

    private static func setProperty(_ json: String, waitForCompletion: Bool = false) {
        let run = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            process.arguments = ["property", "--set", json]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log.error("hidutil exited with status \(process.terminationStatus, privacy: .public)")
                }
            } catch {
                log.error("Could not run hidutil: \(error.localizedDescription, privacy: .public)")
            }
        }
        if waitForCompletion {
            queue.sync(execute: run)
        } else {
            queue.async(execute: run)
        }
    }
}
