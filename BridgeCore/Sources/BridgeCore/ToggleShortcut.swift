import Foundation

/// A modifier that can take part in the forwarding-toggle shortcut. Stored in a
/// platform-neutral form; each capture layer translates its own live modifier
/// state into this set when recording and when matching.
public enum ShortcutModifier: String, Codable, CaseIterable, Sendable, Identifiable {
    case capsLock
    case control
    case option
    case shift
    case command

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    /// Stable order for building a readable label ("Caps Lock + Control + …").
    public static let displayOrder: [ShortcutModifier] = [.capsLock, .control, .option, .shift, .command]
}

/// An optional, user-recorded keyboard chord that turns forwarding on and off.
///
/// There is intentionally no built-in default — forwarding is controlled by the
/// on-screen button unless the user records a shortcut here. The `keyCode` is a
/// **platform-native** raw code (macOS `CGKeyCode`, or iOS `UIKeyboardHIDUsage`
/// raw value); it is only ever compared against codes produced on the same
/// platform, so it never needs to be portable across the two apps.
public struct ToggleShortcut: Codable, Equatable, Sendable {
    /// Platform-native raw key code of the main (non-modifier) key.
    public var keyCode: Int
    /// Modifiers that must be held together with the main key.
    public var modifiers: Set<ShortcutModifier>
    /// Human-readable name of the main key ("F11", "A", "Space"), for display.
    public var keyName: String

    public init(keyCode: Int, modifiers: Set<ShortcutModifier>, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Full label, e.g. "Caps Lock + F11". Doubles as the VoiceOver value.
    public var displayString: String {
        let mods = ShortcutModifier.displayOrder
            .filter { modifiers.contains($0) }
            .map(\.displayName)
        return (mods + [keyName]).joined(separator: " + ")
    }
}
