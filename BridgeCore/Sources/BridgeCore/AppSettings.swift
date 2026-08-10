import Foundation
import Observation

/// Where a Mac/iOS modifier key lands on the Windows side. There is no fixed
/// correct mapping between the layouts, so every non-trivial modifier routes
/// through one of these, user-configurable per the spec.
public enum ModifierMapping: String, CaseIterable, Codable, Sendable, Identifiable {
    case alt        // Windows Alt (VK_MENU)
    case control    // Windows Ctrl (VK_CONTROL)
    case win        // Windows key (VK_LWIN)
    case altGr      // Windows AltGr (right Alt, VK_RMENU) — on e.g. German
                    // layouts the only way to type @ € { } [ ] \ ~

    public var id: String { rawValue }

    /// Human label for pickers; doubles as the VoiceOver value.
    public var displayName: String {
        switch self {
        case .alt: return "Alt"
        case .control: return "Control"
        case .win: return "Windows key"
        case .altGr: return "AltGr (right Alt)"
        }
    }

    /// The Windows VK this mapping targets.
    public var vk: UInt16 {
        switch self {
        case .alt: return VK.menu
        case .control: return VK.control
        case .win: return VK.lwin
        case .altGr: return VK.rmenu
        }
    }
}

/// Shared, observable configuration persisted to `UserDefaults`. One instance
/// is created per app and injected into the capture layer and UI. Not actor
/// isolated — it's plain value-like state over the thread-safe `UserDefaults`,
/// so it can be constructed from `App.init` without hopping actors.
@Observable
public final class AppSettings {
    // MARK: Networking

    /// Target machine's Tailscale IP (or hostname). No discovery — the user
    /// types this in.
    public var targetHost: String {
        didSet { defaults.set(targetHost, forKey: Keys.targetHost) }
    }

    /// TCP port the Windows agent listens on. Must match `appsettings.json`.
    public var targetPort: Int {
        didSet { defaults.set(targetPort, forKey: Keys.targetPort) }
    }

    // MARK: Modifier mappings (per physical side, both platforms)

    // Left and right are mapped independently on every configurable modifier:
    // keyboards with a PC-style right-of-space cluster present those keys as
    // *right* Option/Command, and e.g. "right Option = AltGr, left Option =
    // Alt" is only expressible with per-side settings.

    /// Left Option (Alt) key → Windows modifier.
    public var leftOptionMapping: ModifierMapping {
        didSet { defaults.set(leftOptionMapping.rawValue, forKey: Keys.leftOptionMapping) }
    }

    /// Right Option (Alt) key → Windows modifier.
    public var rightOptionMapping: ModifierMapping {
        didSet { defaults.set(rightOptionMapping.rawValue, forKey: Keys.rightOptionMapping) }
    }

    /// Left Command (GUI) key → Windows modifier.
    public var leftCommandMapping: ModifierMapping {
        didSet { defaults.set(leftCommandMapping.rawValue, forKey: Keys.leftCommandMapping) }
    }

    /// Right Command (GUI) key → Windows modifier.
    public var rightCommandMapping: ModifierMapping {
        didSet { defaults.set(rightCommandMapping.rawValue, forKey: Keys.rightCommandMapping) }
    }

    // MARK: Virtual input (iOS)

    /// Whether the Virtual Input key pad interprets gestures as virtual
    /// sliders (swipe left/right between rows, up/down to step the value,
    /// tap to send) instead of the default touch-typing grid (drag to hear
    /// the key under the finger, lift to send). The slider mode exists as a
    /// fallback in case the grid's zone density doesn't work out on device.
    public var virtualPadSliderMode: Bool {
        didSet { defaults.set(virtualPadSliderMode, forKey: Keys.virtualPadSliderMode) }
    }

    /// Whether the key pad includes an F13–F24 band. Off by default: the
    /// extra band shrinks every other zone, and F13+ is rarely needed.
    public var virtualPadExtendedFKeys: Bool {
        didSet { defaults.set(virtualPadExtendedFKeys, forKey: Keys.virtualPadExtendedFKeys) }
    }

    /// Whether pressing and holding a key-pad zone runs the two-stage hold:
    /// hold past `virtualPadLatchDelay` and the key latches on (it then wraps
    /// everything sent afterwards, exactly like a modifier); keep holding for
    /// `virtualPadHoldDelay` more and it is pressed *down* on the PC and stays
    /// down until the finger lifts, so the PC's own key repeat runs. On by
    /// default. Turning it off restores the plain "lift sends" pad, which is
    /// what a user who rests a finger on a zone before lifting will want.
    public var virtualPadHoldEnabled: Bool {
        didSet { defaults.set(virtualPadHoldEnabled, forKey: Keys.virtualPadHoldEnabled) }
    }

    /// Seconds a key-pad zone must be held before the key latches on.
    public var virtualPadLatchDelay: Double {
        didSet {
            virtualPadLatchDelay = Self.clamp(virtualPadLatchDelay, Self.latchDelayRange)
            defaults.set(virtualPadLatchDelay, forKey: Keys.virtualPadLatchDelay)
        }
    }

    /// Further seconds — counted from the moment it latched, not from the
    /// touch — before the latched key is pressed down on the PC.
    public var virtualPadHoldDelay: Double {
        didSet {
            virtualPadHoldDelay = Self.clamp(virtualPadHoldDelay, Self.holdDelayRange)
            defaults.set(virtualPadHoldDelay, forKey: Keys.virtualPadHoldDelay)
        }
    }

    /// Whether the hold stages are spoken as well as felt. The haptics alone
    /// are unambiguous once learned (soft = latched, hard = down, light =
    /// released), so this is the setting that makes the pad quiet again.
    public var virtualPadHoldSpeech: Bool {
        didSet { defaults.set(virtualPadHoldSpeech, forKey: Keys.virtualPadHoldSpeech) }
    }

    /// Allowed range for `virtualPadLatchDelay`, also the UI's slider bounds.
    public static let latchDelayRange: ClosedRange<Double> = 0.2...2.0
    /// Allowed range for `virtualPadHoldDelay`, also the UI's slider bounds.
    public static let holdDelayRange: ClosedRange<Double> = 0.2...3.0

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether the Virtual Input text field keeps its contents after Send
    /// instead of clearing. Off by default (one combination, then a clean
    /// slate), but a screen-reader user driving single-letter navigation on
    /// the PC — "h" for headings, "k" for links — sends the *same* text over
    /// and over, and retyping it into the field after every send is the whole
    /// cost of the feature. Modifiers still reset either way; only the text
    /// is sticky.
    public var virtualInputKeepText: Bool {
        didSet { defaults.set(virtualInputKeepText, forKey: Keys.virtualInputKeepText) }
    }

    // MARK: Function-key row (macOS)

    /// Whether the Mac's fn-key row is remapped to send plain F1–F12 while
    /// forwarding. With macOS's default "special keys" behaviour the top row
    /// never produces a key event at all (it emits Apple-vendor/consumer HID
    /// usages that become brightness/volume/Mission Control below the event
    /// tap), so without this the user has to hold fn for every F-key. On by
    /// default; the remap is installed only while forwarding is on and removed
    /// again when it stops. Unused on iOS.
    public var forwardFunctionKeyRow: Bool {
        didSet { defaults.set(forwardFunctionKeyRow, forKey: Keys.forwardFunctionKeyRow) }
    }

    // MARK: Forwarding toggle shortcut

    /// Optional physical chord that turns forwarding on/off. `nil` means the
    /// on-screen button (and iOS magic tap) is the only toggle — there is no
    /// hard-wired default hotkey. Recorded in-app on each platform and stored as
    /// JSON so the whole value (key code, modifiers, display name) round-trips.
    public var toggleShortcut: ToggleShortcut? {
        didSet { persistToggleShortcut() }
    }

    // MARK: Storage

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targetHost = defaults.string(forKey: Keys.targetHost) ?? ""
        let storedPort = defaults.integer(forKey: Keys.targetPort)
        self.targetPort = storedPort == 0 ? 5391 : storedPort
        // Migration: installs that predate per-side mappings stored a single
        // value per modifier ("optionMapping"/"commandMapping"); it seeds both
        // sides so remapping one side is a fresh, deliberate act.
        func mapping(_ key: String, legacy: String, default def: ModifierMapping) -> ModifierMapping {
            ModifierMapping(rawValue: defaults.string(forKey: key) ?? "")
                ?? ModifierMapping(rawValue: defaults.string(forKey: legacy) ?? "")
                ?? def
        }
        self.leftOptionMapping = mapping(Keys.leftOptionMapping, legacy: Keys.legacyOptionMapping, default: .alt)
        self.rightOptionMapping = mapping(Keys.rightOptionMapping, legacy: Keys.legacyOptionMapping, default: .alt)
        self.leftCommandMapping = mapping(Keys.leftCommandMapping, legacy: Keys.legacyCommandMapping, default: .control)
        self.rightCommandMapping = mapping(Keys.rightCommandMapping, legacy: Keys.legacyCommandMapping, default: .control)
        self.virtualPadSliderMode = defaults.bool(forKey: Keys.virtualPadSliderMode)
        self.virtualPadExtendedFKeys = defaults.bool(forKey: Keys.virtualPadExtendedFKeys)
        self.virtualInputKeepText = defaults.bool(forKey: Keys.virtualInputKeepText)
        // Hold defaults are all "on" / non-zero, which `bool(forKey:)` and
        // `double(forKey:)` can't express — read the raw object and fall back
        // only when nothing was ever stored.
        self.virtualPadHoldEnabled = defaults.object(forKey: Keys.virtualPadHoldEnabled) as? Bool ?? true
        self.virtualPadLatchDelay = Self.clamp(
            defaults.object(forKey: Keys.virtualPadLatchDelay) as? Double ?? 0.6,
            Self.latchDelayRange
        )
        self.virtualPadHoldDelay = Self.clamp(
            defaults.object(forKey: Keys.virtualPadHoldDelay) as? Double ?? 0.6,
            Self.holdDelayRange
        )
        self.virtualPadHoldSpeech = defaults.object(forKey: Keys.virtualPadHoldSpeech) as? Bool ?? true
        // Defaults to true: `bool(forKey:)` can't express that, so read the raw
        // object and fall back only when nothing was ever stored.
        self.forwardFunctionKeyRow = defaults.object(forKey: Keys.forwardFunctionKeyRow) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.toggleShortcut),
           let decoded = try? JSONDecoder().decode(ToggleShortcut.self, from: data) {
            self.toggleShortcut = decoded
        } else {
            self.toggleShortcut = nil
        }
    }

    /// Persist (or clear) the recorded toggle shortcut as JSON.
    private func persistToggleShortcut() {
        if let toggleShortcut, let data = try? JSONEncoder().encode(toggleShortcut) {
            defaults.set(data, forKey: Keys.toggleShortcut)
        } else {
            defaults.removeObject(forKey: Keys.toggleShortcut)
        }
    }

    private enum Keys {
        static let targetHost = "targetHost"
        static let targetPort = "targetPort"
        static let leftOptionMapping = "leftOptionMapping"
        static let rightOptionMapping = "rightOptionMapping"
        static let leftCommandMapping = "leftCommandMapping"
        static let rightCommandMapping = "rightCommandMapping"
        // Pre-per-side keys, read once for migration, never written.
        static let legacyOptionMapping = "optionMapping"
        static let legacyCommandMapping = "commandMapping"
        static let toggleShortcut = "toggleShortcut"
        // "virtualRowSendsModifiers" was the retired adjustable-rows wrap
        // toggle; its stored value is simply ignored now.
        static let virtualPadSliderMode = "virtualPadSliderMode"
        static let virtualPadExtendedFKeys = "virtualPadExtendedFKeys"
        static let virtualInputKeepText = "virtualInputKeepText"
        static let virtualPadHoldEnabled = "virtualPadHoldEnabled"
        static let virtualPadLatchDelay = "virtualPadLatchDelay"
        static let virtualPadHoldDelay = "virtualPadHoldDelay"
        static let virtualPadHoldSpeech = "virtualPadHoldSpeech"
        static let forwardFunctionKeyRow = "forwardFunctionKeyRow"
    }
}
