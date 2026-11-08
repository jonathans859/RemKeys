import SwiftUI
import UIKit
import BridgeCore

/// App-side helpers for the key pad. What a pad *is* — its keys, grid and
/// defaults — lives in BridgeCore (`Pad`, `PadKey`, `KeyCatalog`,
/// `DefaultPads`), where it is unit-tested; this file holds only what needs
/// UIKit or is shared wording.
enum VirtualKeys {
    /// Spoken form of a hold timing: "0.6 seconds", "1 second". Used by both
    /// the Settings slider and the info sheet, which must agree word for word
    /// — they describe the same number to the same user.
    static func secondsDescription(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        if rounded == 1 { return "1 second" }
        let value = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(value) seconds"
    }

    /// "Navigation, Editing and Function keys".
    static func spokenList(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension PadKeyColor {
    /// The fill colour for this palette entry, or nil for Default (which uses
    /// the pad's ordinary key fill). System colours, so each one already has a
    /// light- and a dark-mode variant.
    var uiColor: UIColor? {
        switch self {
        case .standard: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .brown: return .systemBrown
        case .gray: return .systemGray
        }
    }

    /// How strongly a coloured key is filled while it is off. Low enough that
    /// the ordinary label colour stays readable on it in light and dark mode,
    /// high enough to be told apart at a glance.
    static let restingAlpha: CGFloat = 0.38

    /// The resting fill as a SwiftUI colour, for the editor.
    var restingFill: Color {
        guard let uiColor else { return Color(uiColor: .tertiarySystemFill) }
        return Color(uiColor: uiColor.withAlphaComponent(Self.restingAlpha))
    }
}
