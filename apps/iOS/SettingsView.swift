import SwiftUI
import BridgeCore

/// Modifier-mapping settings. There is no fixed correct mapping between the
/// Apple and Windows modifier layouts, so Option and Command are each routed
/// to a Windows modifier the user chooses.
struct SettingsView: View {
    let settings: AppSettings
    @State private var isRecordingShortcut = false
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            Form {
                toggleShortcutSection
                Section {
                    mappingPicker(
                        title: "Left Option",
                        selection: Binding(
                            get: { settings.leftOptionMapping },
                            set: { settings.leftOptionMapping = $0 }
                        ),
                        hint: "Where the left Option key lands on the Windows PC"
                    )
                    mappingPicker(
                        title: "Right Option",
                        selection: Binding(
                            get: { settings.rightOptionMapping },
                            set: { settings.rightOptionMapping = $0 }
                        ),
                        hint: "Where the right Option key lands on the Windows PC"
                    )
                    mappingPicker(
                        title: "Left Command",
                        selection: Binding(
                            get: { settings.leftCommandMapping },
                            set: { settings.leftCommandMapping = $0 }
                        ),
                        hint: "Where the left Command key lands on the Windows PC"
                    )
                    mappingPicker(
                        title: "Right Command",
                        selection: Binding(
                            get: { settings.rightCommandMapping },
                            set: { settings.rightCommandMapping = $0 }
                        ),
                        hint: "Where the right Command key lands on the Windows PC"
                    )
                } header: {
                    Text("Modifier mapping")
                } footer: {
                    Text("Left and right keys map independently — for a key right of Space that should act as AltGr, set only that side. Not sure which side a key reports as? Press it and check Last key seen in Diagnostics. Shift and Control always map to Windows Shift and Control.")
                }
                virtualInputSection
                holdSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    InfoButton { showInfo = true }
                }
            }
            .sheet(isPresented: $showInfo) { infoSheet }
        }
    }

    /// The teaching text for each setting, adapted to the current values so
    /// examples always describe what the app is doing right now.
    private var infoSheet: some View {
        InfoSheet(title: "Settings") {
            Section("Toggle shortcut") {
                Text(settings.toggleShortcut == nil
                     ? "No shortcut is recorded, so forwarding is toggled with the Start button or a two-finger double tap. Record a physical chord to flip forwarding straight from the keyboard."
                     : "Pressing \(settings.toggleShortcut?.displayString ?? "the recorded chord") on the physical keyboard flips forwarding, even while it is off. While forwarding is on, chords using the Command key are claimed for the PC, so prefer a shortcut without Command.")
            }
            Section("Modifier mapping") {
                Text("There is no single correct way to map Apple modifiers to Windows ones, so Option and Command each map per physical side. Multi-OS keyboards often present their Win-labeled key as Command — press a key and check Last key seen in the Start tab's info sheet to find out what it reports as. Shift and Control always map straight across. AltGr matters on layouts like German, where it is the only way to type characters such as @ and the braces.")
            }
            Section("Key pad") {
                Text("The pad is three zones wide and two blocks tall: one page of keys on top — \(pageCountLabel) — and the six modifiers permanently across the bottom two rows, where they never move. Two-finger swipe left or right on the pad changes the page; the page control at the top left of the Virtual Input screen does the same and can be flicked up or down.")
                Text(settings.virtualPadExtendedFKeys
                     ? "F13 to F24 are available as a further page. The other pages are unaffected — an extra page costs no room."
                     : "F13 to F24 are hidden. Adding them makes one more page and takes nothing away from the others.")
                Text(settings.virtualPadRichHaptics
                     ? "Vibrations report state by how hard they are: the usual light tick for a key that is off, a firmer knock for one that is turned on, and a hard knock for a key held down on the PC. Always one vibration per key."
                     : "Vibrations are plain: the same light tick for every key, whatever its state.")
                Text("Letters, digits and punctuation are deliberately not on the pad — they go in the text field, typed with the iPhone's own keyboard, which is faster than anything a three-wide pad could offer.")
            }
            Section("Hold a key on the pad") {
                Text(settings.virtualPadHoldEnabled
                     ? "Holding a key on the pad for \(secondsLabel(settings.virtualPadHoldDelay)) presses it down on the PC, where it stays — and repeats — until you lift your finger. That is how to delete a run of text with Backspace, or keep scrolling with Down. It works on modifiers too, which is how to send a plain Caps Lock press and flip the lock itself."
                     : "Holding is off, so the pad only acts when you lift: modifiers toggle, other keys send. Turn it on to hold a key down on the PC for key repeat.")
                Text("Vibrations mark the hold whether or not the spoken cues are on: a firm one when the key goes down on the PC, a light one when it is released.")
            }
        }
    }

    private var toggleShortcutSection: some View {
        Section {
            LabeledContent("Shortcut") {
                Text(settings.toggleShortcut?.displayString ?? "None")
                    .foregroundStyle(.secondary)
            }
            .accessibilityValue(settings.toggleShortcut?.displayString ?? "None")

            if isRecordingShortcut {
                HStack {
                    Text("Press the shortcut on your keyboard…")
                    Spacer()
                    Button("Cancel") { isRecordingShortcut = false }
                }
                // Invisible first responder that captures the next chord.
                ShortcutRecorder(
                    isRecording: $isRecordingShortcut,
                    shortcut: Binding(
                        get: { settings.toggleShortcut },
                        set: { settings.toggleShortcut = $0 }
                    )
                )
                .frame(height: 1)
                .accessibilityHidden(true)
            } else {
                Button(settings.toggleShortcut == nil ? "Record shortcut" : "Change shortcut") {
                    isRecordingShortcut = true
                }
                .accessibilityHint("Records a physical keyboard shortcut that turns forwarding on and off")

                if settings.toggleShortcut != nil {
                    Button("Clear shortcut", role: .destructive) {
                        settings.toggleShortcut = nil
                    }
                }
            }
        } header: {
            Text("Forwarding toggle shortcut")
        } footer: {
            Text("Optional. A physical keyboard shortcut that turns forwarding on and off. Leave as None to use the on-screen button or a two-finger double tap.")
        }
    }

    private var virtualInputSection: some View {
        Section {
            Toggle("Key pad includes F13 to F24", isOn: Binding(
                get: { settings.virtualPadExtendedFKeys },
                set: { settings.virtualPadExtendedFKeys = $0 }
            ))
            .accessibilityHint("Adds F13 to F24 as one more page on the key pad. The other pages keep their size.")
            Toggle("Vibrations report key state", isOn: Binding(
                get: { settings.virtualPadRichHaptics },
                set: { settings.virtualPadRichHaptics = $0 }
            ))
            .accessibilityHint("On: exploring the pad vibrates harder over a key that is turned on, and harder still over one held down on the PC. Off: the same light tick for every key.")
        } header: {
            Text("Key pad")
        } footer: {
            Text("The pad is three zones wide: one page of keys on top, the six modifiers fixed across the bottom. Keys sent from it are always wrapped in the modifiers that are on.")
        }
    }

    /// The hold gesture's timing. A slider rather than a stepper: one
    /// adjustable element beats a dozen taps, and the value is spoken in real
    /// units.
    private var holdSection: some View {
        Section {
            Toggle("Hold a key to press it down", isOn: Binding(
                get: { settings.virtualPadHoldEnabled },
                set: { settings.virtualPadHoldEnabled = $0 }
            ))
            .accessibilityHint("On: holding a key on the pad presses it down on the PC until you lift, so it repeats there. Off: the pad only sends on lift.")

            if settings.virtualPadHoldEnabled {
                delaySlider(
                    title: "Presses down after",
                    value: Binding(
                        get: { settings.virtualPadHoldDelay },
                        set: { settings.virtualPadHoldDelay = $0 }
                    ),
                    range: AppSettings.holdDelayRange,
                    hint: "How long a key has to be held, from the moment you touch it, before it is pressed down on the PC. Default 0.8 seconds."
                )

                Toggle("Speak the hold", isOn: Binding(
                    get: { settings.virtualPadHoldSpeech },
                    set: { settings.virtualPadHoldSpeech = $0 }
                ))
                .accessibilityHint("On: the pad says when a key is pressed down on the PC and when it is released. Off: only the vibrations mark it.")
            }
        } header: {
            Text("Hold a key on the pad")
        } footer: {
            Text("Holding a key presses it down on the PC, where it repeats until you lift your finger. A firm vibration marks the press. Modifiers are turned on by a plain lift instead, so holding one sends the key itself — that is how to flip Caps Lock on the PC.")
        }
    }

    /// One timing row: a caption line carrying the current value for sighted
    /// users (SwiftUI never draws a Slider's own label on iOS) over the
    /// slider they can drag.
    ///
    /// The whole row is collapsed into **one** accessibility element with an
    /// adjustable action, rather than letting the `Slider` carry its own.
    /// Both softer attempts still announced the row twice ("Then presses down
    /// after, Then presses down after 0.5 seconds") — hiding the caption
    /// wasn't enough, because the label ends up on a wrapper element as well
    /// as on the slider inside it (field-reported twice, 2026-08-10).
    /// `children: .ignore` is the only version that is deterministic: nothing
    /// inside the row is exposed, so what VoiceOver reads is exactly the
    /// label/value/hint set here, and swipe up/down steps the value.
    private func delaySlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(secondsLabel(value.wrappedValue))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 0.1)
                .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(secondsLabel(value.wrappedValue))
        .accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(value, by: 0.1, in: range)
            case .decrement: step(value, by: -0.1, in: range)
            @unknown default: break
            }
        }
    }

    /// Step a delay by one notch, rounded back to a tenth: repeated
    /// increments of 0.1 in binary drift to 0.7000000000000001, and the
    /// spoken value has to stay the value that is stored.
    private func step(_ value: Binding<Double>, by delta: Double, in range: ClosedRange<Double>) {
        let stepped = ((value.wrappedValue + delta) * 10).rounded() / 10
        value.wrappedValue = min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// Names the pad's pages for the info sheet, so it never lists a page
    /// that isn't there.
    private var pageCountLabel: String {
        let titles = VirtualKeys.pages(includeExtendedFKeys: settings.virtualPadExtendedFKeys)
            .map(\.title)
        guard let last = titles.last, titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " and " + last
    }

    private func secondsLabel(_ seconds: Double) -> String {
        VirtualKeys.secondsDescription(seconds)
    }

    private func mappingPicker(
        title: String,
        selection: Binding<ModifierMapping>,
        hint: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierMapping.allCases) { mapping in
                Text(mapping.displayName).tag(mapping)
            }
        }
        .pickerStyle(.menu)
        .accessibilityHint(hint)
    }
}
