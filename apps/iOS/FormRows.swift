import SwiftUI
import BridgeCore

/// The "which key, pressed with which modifiers" part of a form: a key row
/// that opens `KeyPickerView`, a read-only "Sends" summary, and one toggle
/// per modifier. Shared by the pad key editor and the gesture action editor.
///
/// Changes come back through one callback carrying the whole chord, so a
/// caller backed by persisted settings writes once per change, and the rule
/// that a key is never its own modifier lives here only.
struct KeyChordSections: View {
    let vk: UInt16
    let modifiers: Set<UInt16>
    let onChange: (_ vk: UInt16, _ modifiers: Set<UInt16>) -> Void

    var body: some View {
        Section {
            NavigationLink {
                KeyPickerView(selection: Binding(
                    get: { vk },
                    set: { newVK in
                        var mods = modifiers
                        // A key is never its own modifier.
                        mods.remove(newVK)
                        onChange(newVK, mods)
                    }
                ))
            } label: {
                LabeledContent("Key", value: KeyCatalog.spokenName(for: vk))
            }
            LabeledContent("Sends", value: KeyCatalog.spokenComboName(vk: vk, modifiers: modifiers))
        } header: {
            SectionHeader("Key", systemImage: "keyboard")
        }

        Section {
            ForEach(KeyCatalog.modifiers) { modifier in
                Toggle(modifier.spokenName, isOn: Binding(
                    get: { modifiers.contains(modifier.vk) },
                    set: { on in
                        var mods = modifiers
                        if on { mods.insert(modifier.vk) } else { mods.remove(modifier.vk) }
                        onChange(vk, mods)
                    }
                ))
                .disabled(modifier.vk == vk)
            }
        } header: {
            SectionHeader("Pressed together with", systemImage: "option")
        }
    }
}

/// One timing row: a caption line carrying the current value for sighted
/// users (SwiftUI never draws a Slider's own label on iOS) over the slider
/// they can drag.
///
/// The whole row is collapsed into **one** accessibility element with an
/// adjustable action, rather than letting the `Slider` carry its own. Both
/// softer attempts still announced the row twice ("Then presses down after,
/// Then presses down after 0.5 seconds") — hiding the caption wasn't enough,
/// because the label ends up on a wrapper element as well as on the slider
/// inside it (field-reported twice, 2026-08-10). `children: .ignore` is the
/// only version that is deterministic: nothing inside the row is exposed, so
/// what VoiceOver reads is exactly the label/value/hint set here, and swipe
/// up/down steps the value.
struct SteppedSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// One notch, for dragging and for VoiceOver's swipe up/down alike.
    /// Should divide 1 evenly (0.1, 0.05, …): stepped values are rounded
    /// back onto that grid.
    let step: Double
    /// The value as shown and spoken, e.g. "0.8 seconds".
    let valueText: (Double) -> String
    let hint: String

    var body: some View {
        let text = valueText(value)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(text)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: step)
            case .decrement: nudge(by: -step)
            @unknown default: break
            }
        }
    }

    /// Step by one notch, rounded back onto the grid: repeated increments of
    /// 0.1 in binary drift to 0.7000000000000001, and the spoken value has to
    /// stay the value that is stored. Rounds via notches-per-unit (10, 20)
    /// rather than multiplying back by `step`, since 7 * 0.1 itself drifts.
    private func nudge(by delta: Double) {
        let perUnit = (1 / step).rounded()
        let stepped = ((value + delta) * perUnit).rounded() / perUnit
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}
