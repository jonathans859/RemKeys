import SwiftUI
import BridgeCore

/// Settings → Key pad → Gestures: what each multi-finger gesture on the
/// Virtual Input pad does, plus the "wait for more fingers" window that keeps a
/// staggered two-finger landing from speaking or sending the first finger's key.
///
/// One row per gesture, value = its action, so the whole map is readable by
/// swiping down the list. Each row opens `PadGestureActionEditor`.
struct PadGesturesView: View {
    let settings: AppSettings
    @State private var confirmRestore = false

    private struct GestureGroup: Identifiable {
        let title: String
        let symbol: String
        let gestures: [PadGesture]
        var id: String { title }
    }

    private static let groups: [GestureGroup] = [
        GestureGroup(title: "Two-finger swipes", symbol: "hand.draw",
                     gestures: [.twoFingerSwipeUp, .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight]),
        GestureGroup(title: "Three-finger swipes", symbol: "hand.draw.fill",
                     gestures: [.threeFingerSwipeUp, .threeFingerSwipeDown, .threeFingerSwipeLeft, .threeFingerSwipeRight]),
        GestureGroup(title: "Two-finger taps", symbol: "hand.tap",
                     gestures: [.twoFingerTap, .twoFingerDoubleTap, .twoFingerTripleTap]),
        GestureGroup(title: "Three-finger taps", symbol: "hand.tap.fill",
                     gestures: [.threeFingerTap, .threeFingerDoubleTap, .threeFingerTripleTap]),
        GestureGroup(title: "Twist, like the VoiceOver rotor", symbol: "arrow.triangle.2.circlepath",
                     gestures: [.twistLeft, .twistRight]),
    ]

    var body: some View {
        Form {
            Section {
                graceSlider
            } header: {
                SectionHeader("Timing", systemImage: "timer")
            }

            ForEach(Self.groups) { group in
                Section {
                    ForEach(group.gestures) { gesture in
                        NavigationLink {
                            PadGestureActionEditor(gesture: gesture, settings: settings)
                        } label: {
                            LabeledContent(gesture.displayName, value: settings.gestureAction(for: gesture).spokenDescription)
                        }
                        .accessibilityHint("Chooses what this gesture does on the key pad")
                    }
                } header: {
                    SectionHeader(group.title, systemImage: group.symbol)
                }
            }

            Section {
                Button("Restore default gestures") { confirmRestore = true }
                    .accessibilityHint("Two-finger swipe left and right change the pad, two-finger tap clears the modifiers, every other gesture does nothing")
            }
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Restore default gestures?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore defaults", role: .destructive) {
                settings.virtualPadGestures = Dictionary(uniqueKeysWithValues: PadGesture.allCases.map {
                    ($0, PadGestureDefaults.actions[$0] ?? .nothing)
                })
                UIAccessibility.post(notification: .announcement, argument: "Default gestures restored")
            }
        } message: {
            Text("Every gesture you assigned goes back to its default.")
        }
    }

    // MARK: Grace window

    private var graceValue: String { Self.graceDescription(settings.virtualPadMultiFingerGrace) }

    static func graceDescription(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return ms == 0 ? "Off" : "\(ms) milliseconds"
    }

    /// One accessibility element with an adjustable action, for the same
    /// reason as the hold-delay slider in Settings: a bare `Slider` plus a
    /// caption announced the row twice.
    private var graceSlider: some View {
        let title = "Wait for more fingers"
        let range = AppSettings.multiFingerGraceRange
        let value = Binding(
            get: { settings.virtualPadMultiFingerGrace },
            set: { settings.virtualPadMultiFingerGrace = $0 }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(graceValue)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.05)
                .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(graceValue)
        .accessibilityHint("How long the pad waits after a finger lands before it speaks or sends that key. A second finger arriving in that time makes it a multi-finger gesture, so the first finger's key is never sent. Off reacts at once. Try 100 to 150 milliseconds if two-finger gestures sometimes send a key first.")
        .accessibilityAdjustableAction { direction in
            let delta: Double
            switch direction {
            case .increment: delta = 0.05
            case .decrement: delta = -0.05
            @unknown default: return
            }
            // Rounded to the 50 ms grid, so the spoken value stays the stored one.
            let stepped = ((value.wrappedValue + delta) * 20).rounded() / 20
            value.wrappedValue = min(max(stepped, range.lowerBound), range.upperBound)
        }
    }
}

/// What one gesture does: nothing, a pad action, or a key (with optional
/// fixed modifiers) sent exactly as a pad key would be — wrapped in whatever
/// modifiers are latched, and a bare modifier toggles rather than sends.
struct PadGestureActionEditor: View {
    let gesture: PadGesture
    let settings: AppSettings

    private var action: PadGestureAction { settings.gestureAction(for: gesture) }

    private func update(_ change: (inout PadGestureAction) -> Void) {
        var copy = action
        change(&copy)
        settings.virtualPadGestures[gesture] = PadGestureAction(kind: copy.kind, vk: copy.vk, modifiers: copy.modifiers)
    }

    var body: some View {
        Form {
            Section {
                Picker("Action", selection: Binding(
                    get: { action.kind },
                    set: { kind in update { $0.kind = kind } }
                )) {
                    ForEach(PadGestureAction.Kind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                SectionHeader("Action", systemImage: "hand.point.up.left")
            }

            if action.kind == .sendKey {
                Section {
                    NavigationLink {
                        KeyPickerView(selection: Binding(
                            get: { action.vk },
                            set: { vk in update { $0.vk = vk; $0.modifiers.remove(vk) } }
                        ))
                    } label: {
                        LabeledContent("Key", value: KeyCatalog.spokenName(for: action.vk))
                    }
                    LabeledContent("Sends", value: KeyCatalog.spokenComboName(vk: action.vk, modifiers: action.modifiers))
                } header: {
                    SectionHeader("Key", systemImage: "keyboard")
                }

                Section {
                    ForEach(KeyCatalog.modifiers) { modifier in
                        Toggle(modifier.spokenName, isOn: Binding(
                            get: { action.modifiers.contains(modifier.vk) },
                            set: { on in
                                update {
                                    if on { $0.modifiers.insert(modifier.vk) } else { $0.modifiers.remove(modifier.vk) }
                                }
                            }
                        ))
                        .disabled(modifier.vk == action.vk)
                    }
                } header: {
                    SectionHeader("Pressed together with", systemImage: "option")
                }
            }
        }
        .navigationTitle(gesture.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
