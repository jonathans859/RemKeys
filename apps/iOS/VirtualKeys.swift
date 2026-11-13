import SwiftUI
import UIKit
import BridgeCore

/// App-side helpers for the key pad. What a pad *is* — its keys, grid and
/// defaults — lives in BridgeCore (`Pad`, `PadKey`, `KeyCatalog`,
/// `DefaultPads`), where it is unit-tested; this file holds only what needs
/// UIKit or is shared wording.
enum VirtualKeys {
    /// "two-finger swipe left and two-finger twist right", or nil — the pad
    /// gestures currently assigned to `kind`, worded for the middle of a
    /// sentence, so info text describes the pad as configured.
    static func gestures(doing kind: PadGestureAction.Kind, in settings: AppSettings) -> String? {
        let names = PadGesture.allCases
            .filter { settings.gestureAction(for: $0).kind == kind }
            .map { $0.displayName.lowercased() }
        return names.isEmpty ? nil : spokenList(names)
    }

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

    /// A coloured key is filled with its colour at **full strength**. A 38%
    /// wash was tried first and field-rejected (2026-11-08) as too grey to tell
    /// the colours apart; the text colour follows the fill instead
    /// (`restingText`), so readability doesn't depend on keeping it pale.
    var restingFill: UIColor {
        uiColor ?? .tertiarySystemFill
    }

    /// Black or white on a coloured key, whichever contrasts more with its
    /// fill in the current appearance; the ordinary label colour on a Default
    /// key.
    var restingText: UIColor {
        guard let uiColor else { return .label }
        return UIColor { traits in uiColor.resolvedColor(with: traits).highestContrastForeground }
    }
}

extension UIColor {
    /// Black or white, whichever contrasts more with this colour.
    ///
    /// Hardcoding white is fine while a fill is a dark blue and wrong the
    /// moment it isn't — the app's dark-mode accent is a light violet, and the
    /// palette has yellow and teal. Must be called on an already resolved
    /// colour; a dynamic one reports the components of whichever trait
    /// collection it happens to resolve against.
    var highestContrastForeground: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // WCAG relative luminance, then the two contrast ratios it implies.
        let l = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05) ? .black : .white
    }
}
