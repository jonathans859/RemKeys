import SwiftUI

/// The app's shared visual vocabulary.
///
/// Everything here exists so the three tabs look like one app rather than
/// three screens that happen to ship together. There is exactly one accent
/// (`AccentColor` in the asset catalog — indigo, with a lifted violet for dark
/// mode), one card treatment, and one section-header style, and every screen
/// uses those and nothing else. `UIView.tintColor` resolves to the same asset,
/// so the key pad's "modifier on" and "key down" washes pick it up for free.
enum Theme {
    /// Corner radius for the app's cards. Continuous (squircle) curvature
    /// everywhere — the plain circular radius reads as older iOS at this size.
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 18
    /// Gap between a card and the section around it.
    static let cardSpacing: CGFloat = 10
}

/// The one section header in the app: an SF Symbol, the title in sentence
/// case, semibold and at full contrast — and **an actual heading**.
///
/// The system default — small, grey, SHOUTED IN CAPS — is what a plain `Form`
/// gives you and is most of why a settings screen reads as unstyled. Sentence
/// case plus a glyph gives each section a landmark a sighted user can scan to.
///
/// `.isHeader` is the load-bearing line, not the styling. A `Form` gives its
/// *own* `Text` headers the heading trait, so VoiceOver's rotor can jump
/// section to section; a custom view handed to `header:` does not inherit
/// that, and the first version of this type shipped bold text that merely
/// looked like a heading and could not be navigated to (field-reported
/// 2026-08-23). Every screen in the app is built out of these, so losing the
/// trait cost rotor navigation everywhere at once — including inside the info
/// sheets, which are the longest reads in the app and need it most.
///
/// `children: .ignore` makes what VoiceOver reads exactly the title: `Label`
/// is one element already, but combining leaves the symbol free to contribute
/// a name of its own, and a heading has to be worth landing on.
struct SectionHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            // Overrides the uppercasing a Form section applies to its header.
            .textCase(nil)
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The app's card surface: a rounded panel with a hairline accent edge,
    /// meant to be dropped into a `Form` row whose own background is cleared.
    ///
    /// `active` swaps the flat grouped-background fill for a soft accent
    /// gradient and firms up the border, which is how the Start tab shows a
    /// live session without needing a second label to say so.
    func remKeysCard(active: Bool = false) -> some View {
        self
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(active ? 0.20 : 0),
                                        Color.accentColor.opacity(active ? 0.05 : 0),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(active ? 0.45 : 0.12),
                        lineWidth: active ? 1.5 : 1
                    )
            }
    }

    /// Turn a `Form` row into a bare canvas for a card: no separator, no grey
    /// plate behind it, and the standard side margin restored by hand.
    func cardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: Theme.cardSpacing,
                leading: 16,
                bottom: Theme.cardSpacing,
                trailing: 16
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
