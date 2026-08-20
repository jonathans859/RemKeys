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

    /// Whether the key pad includes an F13–F24 band. Off by default: the
    /// extra band shrinks every other zone, and F13+ is rarely needed.
    public var virtualPadExtendedFKeys: Bool {
        didSet { defaults.set(virtualPadExtendedFKeys, forKey: Keys.virtualPadExtendedFKeys) }
    }

    /// Whether the pad's vibrations carry more than "you crossed a boundary":
    /// a key that is already turned on answers with a double tick and one
    /// held down on the PC with a firm one, and moving between rows gets its
    /// own soft swell. On by default — with a dense keyboard layout under the
    /// finger this is the channel that reports state without waiting for
    /// speech, and it works with the phone in a pocket.
    public var virtualPadRichHaptics: Bool {
        didSet { defaults.set(virtualPadRichHaptics, forKey: Keys.virtualPadRichHaptics) }
    }

    /// Whether pressing and holding a key-pad zone presses that key *down* on
    /// the PC — where it stays until the finger lifts, so the agent's key
    /// repeat runs. On by default. Turning it off restores the plain "lift
    /// sends" pad, which is what a user who rests a finger on a zone before
    /// lifting will want.
    ///
    /// There used to be an earlier "latch the key on" stage before this one.
    /// It went with the 2026-08-20 rebuild: every modifier now has a permanent
    /// zone of its own, so latching an arbitrary key had nothing left to do,
    /// and one stage is one thing to learn.
    public var virtualPadHoldEnabled: Bool {
        didSet { defaults.set(virtualPadHoldEnabled, forKey: Keys.virtualPadHoldEnabled) }
    }

    // The delay clamps what it is given, which rules out a `didSet`:
    // under `@Observable` the stored property becomes a computed one, so
    // assigning the clamped value from inside its own observer re-enters the
    // setter forever and blows the stack (CI, signal 11, 2026-08-10). A
    // computed property over private storage clamps once, in the one place a
    // value can arrive, and the storage stays observable.

    /// Seconds a key-pad zone must be held, counted from the touch, before
    /// the key is pressed down on the PC.
    public var virtualPadHoldDelay: Double {
        get { holdDelayStorage }
        set {
            holdDelayStorage = Self.clamp(newValue, Self.holdDelayRange)
            defaults.set(holdDelayStorage, forKey: Keys.virtualPadHoldDelay)
        }
    }

    private var holdDelayStorage: Double

    /// Whether the hold is spoken as well as felt. The haptics alone are
    /// unambiguous once learned (hard knock = down on the PC, light =
    /// released), so this is the setting that makes the pad quiet again.
    public var virtualPadHoldSpeech: Bool {
        didSet { defaults.set(virtualPadHoldSpeech, forKey: Keys.virtualPadHoldSpeech) }
    }

    /// Allowed range for `virtualPadHoldDelay`, also the UI's slider bounds.
    /// Its floor is higher than the old two-stage latch delay's: this is now
    /// the *only* countdown, measured from the touch, so a finger that pauses
    /// while exploring must not trip it.
    public static let holdDelayRange: ClosedRange<Double> = 0.3...2.0

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

    /// Whether the Virtual Input text field is a **direct line to the PC**:
    /// every character typed into it goes out the moment it is typed, every
    /// deletion sends a Backspace, and Return sends Enter — no Send press
    /// anywhere. Off by default.
    ///
    /// This is the other half of "the iPhone's keyboard carries the letters".
    /// Composing a string and firing it is right for a shortcut; *typing* at
    /// the PC — a filename, a search box, a password field — wants every
    /// keystroke to land as it is made, and pressing Send between letters is
    /// the whole cost. Modifiers that are on keep wrapping each character and
    /// do **not** reset, which is what makes Caps Lock plus a letter repeatable
    /// for screen-reader navigation.
    public var virtualInputLiveTyping: Bool {
        didSet { defaults.set(virtualInputLiveTyping, forKey: Keys.virtualInputLiveTyping) }
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
        self.virtualPadExtendedFKeys = defaults.bool(forKey: Keys.virtualPadExtendedFKeys)
        self.virtualInputKeepText = defaults.bool(forKey: Keys.virtualInputKeepText)
        self.virtualInputLiveTyping = defaults.bool(forKey: Keys.virtualInputLiveTyping)
        self.virtualPadRichHaptics = defaults.object(forKey: Keys.virtualPadRichHaptics) as? Bool ?? true
        // Hold defaults are all "on" / non-zero, which `bool(forKey:)` and
        // `double(forKey:)` can't express — read the raw object and fall back
        // only when nothing was ever stored.
        self.virtualPadHoldEnabled = defaults.object(forKey: Keys.virtualPadHoldEnabled) as? Bool ?? true
        self.holdDelayStorage = Self.clamp(
            defaults.object(forKey: Keys.virtualPadHoldDelay) as? Double ?? 0.8,
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
        // Retired keys whose stored values are simply ignored now:
        // "virtualRowSendsModifiers" (the adjustable-rows wrap toggle),
        // "virtualPadSliderMode", "virtualPadLayout", "pcKeyboardLayout",
        // "interfaceOrientationLock" and "virtualPadLatchDelay" — all of them
        // belonged to arrangements the 2026-08-20 rebuild removed.
        static let virtualPadExtendedFKeys = "virtualPadExtendedFKeys"
        static let virtualInputKeepText = "virtualInputKeepText"
        static let virtualInputLiveTyping = "virtualInputLiveTyping"
        static let virtualPadHoldEnabled = "virtualPadHoldEnabled"
        // Deliberately not the old "virtualPadHoldDelay": that number was
        // counted from the moment a key latched, not from the touch, so an
        // inherited value would mean something else.
        static let virtualPadHoldDelay = "virtualPadHoldFromTouch"
        static let virtualPadHoldSpeech = "virtualPadHoldSpeech"
        static let virtualPadRichHaptics = "virtualPadRichHaptics"
        static let forwardFunctionKeyRow = "forwardFunctionKeyRow"
    }
}
