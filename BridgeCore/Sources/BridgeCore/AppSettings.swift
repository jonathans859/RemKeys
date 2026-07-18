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

    /// Whether selecting a key on a virtual-input row (which sends that key
    /// immediately) wraps it in the modifiers currently toggled on. Off means
    /// row selection sends the bare key and modifiers only apply through the
    /// Send button. A setting because both behaviors are legitimate: wrapped
    /// is fast Ctrl/Shift+Arrow navigation, bare keeps swiping across a row
    /// from firing modified chords on every stop.
    public var virtualRowSendsModifiers: Bool {
        didSet { defaults.set(virtualRowSendsModifiers, forKey: Keys.virtualRowSendsModifiers) }
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
        // Default true: `bool(forKey:)` can't express a true default, so read
        // the raw object.
        self.virtualRowSendsModifiers = defaults.object(forKey: Keys.virtualRowSendsModifiers) as? Bool ?? true
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
        static let virtualRowSendsModifiers = "virtualRowSendsModifiers"
    }
}
