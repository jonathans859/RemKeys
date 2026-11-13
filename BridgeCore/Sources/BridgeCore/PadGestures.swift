import Foundation

/// A multi-finger gesture on the Virtual Input key pad that the user can assign
/// an action to (Settings → Key pad → Gestures).
///
/// One-finger gestures are deliberately absent: a single finger is how every key
/// is found, by dragging, so a one-finger flick would be indistinguishable from a
/// fast drag that ends on a key. The "rotor" gestures are therefore the
/// two-finger **twist**, the motion VoiceOver's rotor uses.
public enum PadGesture: String, CaseIterable, Codable, Identifiable, Sendable {
    case twoFingerSwipeUp, twoFingerSwipeDown, twoFingerSwipeLeft, twoFingerSwipeRight
    case threeFingerSwipeUp, threeFingerSwipeDown, threeFingerSwipeLeft, threeFingerSwipeRight
    case twoFingerTap, twoFingerDoubleTap, twoFingerTripleTap
    case threeFingerTap, threeFingerDoubleTap, threeFingerTripleTap
    case twistLeft, twistRight

    public var id: String { rawValue }

    public enum Kind: Sendable, Equatable {
        case swipe(PadDirection)
        /// Taps in a row: 1, 2 or 3.
        case tap(Int)
        /// Twist: `clockwise` is "right", as on VoiceOver's rotor.
        case twist(clockwise: Bool)
    }

    public var kind: Kind {
        switch self {
        case .twoFingerSwipeUp, .threeFingerSwipeUp: return .swipe(.up)
        case .twoFingerSwipeDown, .threeFingerSwipeDown: return .swipe(.down)
        case .twoFingerSwipeLeft, .threeFingerSwipeLeft: return .swipe(.left)
        case .twoFingerSwipeRight, .threeFingerSwipeRight: return .swipe(.right)
        case .twoFingerTap, .threeFingerTap: return .tap(1)
        case .twoFingerDoubleTap, .threeFingerDoubleTap: return .tap(2)
        case .twoFingerTripleTap, .threeFingerTripleTap: return .tap(3)
        case .twistLeft: return .twist(clockwise: false)
        case .twistRight: return .twist(clockwise: true)
        }
    }

    public var fingers: Int {
        switch self {
        case .threeFingerSwipeUp, .threeFingerSwipeDown, .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerTap, .threeFingerDoubleTap, .threeFingerTripleTap:
            return 3
        default:
            return 2
        }
    }

    /// Shown and spoken — one string, so Voice Control can say what it sees.
    public var displayName: String {
        let count = fingers == 2 ? "Two-finger" : "Three-finger"
        switch kind {
        case .swipe(let direction): return "\(count) swipe \(direction.rawValue)"
        case .tap(1): return "\(count) tap"
        case .tap(2): return "\(count) double tap"
        case .tap(_): return "\(count) triple tap"
        case .twist(let clockwise): return "Two-finger twist \(clockwise ? "right" : "left")"
        }
    }
}

/// What a pad gesture does.
public struct PadGestureAction: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case nothing, nextPad, previousPad, clearModifiers, sendKey

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .nothing: return "Nothing"
            case .nextPad: return "Next pad"
            case .previousPad: return "Previous pad"
            case .clearModifiers: return "Clear modifiers"
            case .sendKey: return "Send a key"
            }
        }
    }

    public var kind: Kind
    /// Only meaningful for `.sendKey`.
    public var vk: UInt16
    /// Fixed modifiers pressed around `vk` (a chord such as Alt+Tab). Latched
    /// pad modifiers wrap it too, exactly as for a key on the pad.
    public var modifiers: Set<UInt16>

    public init(kind: Kind, vk: UInt16 = VK.tab, modifiers: Set<UInt16> = []) {
        self.kind = kind
        self.vk = vk
        self.modifiers = modifiers.intersection(KeyCatalog.modifierVKs).subtracting([vk])
    }

    public static let nothing = PadGestureAction(kind: .nothing)
    public static let nextPad = PadGestureAction(kind: .nextPad)
    public static let previousPad = PadGestureAction(kind: .previousPad)
    public static let clearModifiers = PadGestureAction(kind: .clearModifiers)

    public static func sendKey(vk: UInt16, modifiers: Set<UInt16> = []) -> PadGestureAction {
        PadGestureAction(kind: .sendKey, vk: vk, modifiers: modifiers)
    }

    /// The key a `.sendKey` action presses, as a pad key so it goes down the
    /// pad's own send path (a bare modifier toggles, anything else sends).
    public var padKey: PadKey? {
        kind == .sendKey ? PadKey(vk: vk, modifiers: modifiers) : nil
    }

    /// "Next pad", "Send Alt Tab".
    public var spokenDescription: String {
        guard kind == .sendKey else { return kind.displayName }
        return "Send \(KeyCatalog.spokenComboName(vk: vk, modifiers: modifiers))"
    }

    // Tolerant decoding: an action kind added by a newer version reads as
    // Nothing rather than throwing the whole gesture map away.
    private enum CodingKeys: String, CodingKey { case kind, vk, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.init(
            kind: Kind(rawValue: rawKind) ?? .nothing,
            vk: try c.decodeIfPresent(UInt16.self, forKey: .vk) ?? VK.tab,
            modifiers: Set(try c.decodeIfPresent([UInt16].self, forKey: .modifiers) ?? [])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(vk, forKey: .vk)
        try c.encode(modifiers.sorted(), forKey: .modifiers)
    }
}

public enum PadGestureDefaults {
    /// What the pad always did before gestures became configurable: two-finger
    /// swipe left/right pages, two-finger tap clears the modifiers.
    public static let actions: [PadGesture: PadGestureAction] = [
        .twoFingerSwipeLeft: .nextPad,
        .twoFingerSwipeRight: .previousPad,
        .twoFingerTap: .clearModifiers,
    ]
}
