import Foundation
import Observation

/// Where a Mac/iOS modifier key lands on the Windows side. There is no fixed
/// correct mapping between the layouts, so every non-trivial modifier routes
/// through one of these, user-configurable per the spec.
public enum ModifierMapping: String, CaseIterable, Codable, Sendable, Identifiable {
    case alt        // Windows Alt (VK_MENU)
    case control    // Windows Ctrl (VK_CONTROL)
    case win        // Windows key (VK_LWIN)

    public var id: String { rawValue }

    /// Human label for pickers; doubles as the VoiceOver value.
    public var displayName: String {
        switch self {
        case .alt: return "Alt"
        case .control: return "Control"
        case .win: return "Windows key"
        }
    }

    /// The Windows VK this mapping targets.
    public var vk: UInt16 {
        switch self {
        case .alt: return VK.menu
        case .control: return VK.control
        case .win: return VK.lwin
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

    // MARK: iOS modifier mappings

    /// iOS Option (Alt) key → Windows modifier.
    public var optionMapping: ModifierMapping {
        didSet { defaults.set(optionMapping.rawValue, forKey: Keys.optionMapping) }
    }

    /// iOS Command (GUI) key → Windows modifier.
    public var commandMapping: ModifierMapping {
        didSet { defaults.set(commandMapping.rawValue, forKey: Keys.commandMapping) }
    }

    // MARK: macOS modifier mappings

    /// macOS left Option → Windows modifier.
    public var leftOptionMapping: ModifierMapping {
        didSet { defaults.set(leftOptionMapping.rawValue, forKey: Keys.leftOptionMapping) }
    }

    /// macOS right Option → Windows modifier.
    public var rightOptionMapping: ModifierMapping {
        didSet { defaults.set(rightOptionMapping.rawValue, forKey: Keys.rightOptionMapping) }
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
        self.optionMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.optionMapping) ?? "") ?? .alt
        self.commandMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.commandMapping) ?? "") ?? .control
        self.leftOptionMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.leftOptionMapping) ?? "") ?? .alt
        self.rightOptionMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.rightOptionMapping) ?? "") ?? .alt
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
        static let optionMapping = "optionMapping"
        static let commandMapping = "commandMapping"
        static let leftOptionMapping = "leftOptionMapping"
        static let rightOptionMapping = "rightOptionMapping"
        static let toggleShortcut = "toggleShortcut"
    }
}
