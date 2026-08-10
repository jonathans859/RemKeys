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
                switch settings.virtualPadLayout {
                case .bands:
                    Text("The pad shows key bands — modifiers, editing, navigation and the function keys — in both orientations. Choose one of the keyboard options to get letters, digits and punctuation as well, arranged as they are on a real PC keyboard.")
                case .keyboardInLandscape:
                    Text("The pad shows key bands while the device is upright and a whole PC keyboard once it is turned sideways. Sideways is where that fits: the screen is then close to a keyboard's proportions, and the keys come out about the size of the ones on the on-screen keyboard. Upright there is no room, so the bands stay.")
                case .keyboardAlways:
                    Text("The pad always shows a whole PC keyboard. Upright its keys are narrow — dragging still finds them, but sideways is where they reach a comfortable size.")
                }
                if settings.virtualPadLayout != .bands {
                    Text("The keyboard is named for a \(settings.pcKeyboardLayout.displayName) PC. Keys travel by position and the PC's own layout decides the character, so this setting only changes what you see and hear — set it to match the PC and the letter you hear is the letter that arrives.")
                }
                Text(settings.virtualPadSliderMode
                     ? "The key pad currently uses slider gestures: swipe between rows and through keys, tap to send. Turn the toggle off for the grid, where dragging explores the keys and lifting sends."
                     : "The key pad currently uses the grid: dragging explores the keys and lifting sends. Turn the slider toggle on for row-based swiping instead — an alternative if the grid zones feel too small.")
                Text(settings.virtualPadExtendedFKeys
                     ? "F13 to F24 are shown as an extra row, which makes every other row a bit shorter."
                     : "F13 to F24 are hidden; enable them to add a row at the cost of shorter ones elsewhere.")
                Text(settings.virtualPadRichHaptics
                     ? "Vibrations report state by how hard they are: the usual light tick for a key that is off, a firmer knock for one that is turned on, and a hard knock for a key held down on the PC. Always one vibration per key."
                     : "Vibrations are plain: the same light tick for every key, whatever its state.")
            }
            Section("Hold a key on the pad") {
                Text(settings.virtualPadHoldEnabled
                     ? "Holding a key on the pad for \(secondsLabel(settings.virtualPadLatchDelay)) turns it on like a modifier, so it wraps everything you send afterwards — Caps Lock lives in that row too, for screen-reader keys such as NVDA's. Keep holding for another \(secondsLabel(settings.virtualPadHoldDelay)) and the key is pressed down on the PC and repeats until you lift, which also turns it off again."
                     : "Holding is off, so the pad only acts when you lift: modifiers toggle, other keys send. Turn it on to hold a key down on the PC for key repeat, or to turn a key on without sending it.")
                Text("Vibrations mark every stage whether or not the spoken cues are on: a gentle one when the key turns on, a firmer one when it goes down on the PC, a light one when it is released.")
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
            Picker("Key pad layout", selection: Binding(
                get: { settings.virtualPadLayout },
                set: { settings.virtualPadLayout = $0 }
            )) {
                ForEach(VirtualPadLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Key bands are the modifier, editing, navigation and function-key rows. The keyboard is a whole PC key block including letters and digits, which only has room for usable keys when the device is sideways.")

            if settings.virtualPadLayout != .bands {
                Picker("PC keyboard layout", selection: Binding(
                    get: { settings.pcKeyboardLayout },
                    set: { settings.pcKeyboardLayout = $0 }
                )) {
                    ForEach(PCKeyboardLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityHint("Names the keys on the keyboard layout after the layout your PC is set to. It never changes what is sent — keys always travel by position, and the PC decides the character.")
            }

            Toggle("Key pad uses slider gestures", isOn: Binding(
                get: { settings.virtualPadSliderMode },
                set: { settings.virtualPadSliderMode = $0 }
            ))
            .accessibilityHint("Off: drag on the pad to hear keys and lift to send. On: swipe left or right to choose a row, up or down to choose its key, tap to send.")
            Toggle("Key pad includes F13 to F24", isOn: Binding(
                get: { settings.virtualPadExtendedFKeys },
                set: { settings.virtualPadExtendedFKeys = $0 }
            ))
            .accessibilityHint("Adds a row of F13 to F24 to the key pad. Every other row gets less room.")
            Toggle("Vibrations report key state", isOn: Binding(
                get: { settings.virtualPadRichHaptics },
                set: { settings.virtualPadRichHaptics = $0 }
            ))
            .accessibilityHint("On: exploring the pad vibrates harder over a key that is turned on, and harder still over one held down on the PC. Off: the same light tick for every key.")
        } header: {
            Text("Key pad")
        } footer: {
            Text("Keys sent from the key pad are always wrapped in the keys currently turned on.")
        }
    }

    /// The hold gesture's timings. Sliders rather than steppers: one
    /// adjustable element per value beats a dozen taps, and the value is
    /// spoken in real units.
    private var holdSection: some View {
        Section {
            Toggle("Hold a key to turn it on", isOn: Binding(
                get: { settings.virtualPadHoldEnabled },
                set: { settings.virtualPadHoldEnabled = $0 }
            ))
            .accessibilityHint("On: holding a key on the pad turns it on like a modifier, and holding longer presses it down on the PC until you lift. Off: the pad only sends on lift.")

            if settings.virtualPadHoldEnabled {
                delaySlider(
                    title: "Turns on after",
                    value: Binding(
                        get: { settings.virtualPadLatchDelay },
                        set: { settings.virtualPadLatchDelay = $0 }
                    ),
                    range: AppSettings.latchDelayRange,
                    hint: "How long a key has to be held before it turns on. Default 0.6 seconds."
                )
                delaySlider(
                    title: "Then presses down after",
                    value: Binding(
                        get: { settings.virtualPadHoldDelay },
                        set: { settings.virtualPadHoldDelay = $0 }
                    ),
                    range: AppSettings.holdDelayRange,
                    hint: "Further time, counted from the moment the key turned on, before it is pressed down on the PC. Default 0.6 seconds."
                )

                Toggle("Speak the hold stages", isOn: Binding(
                    get: { settings.virtualPadHoldSpeech },
                    set: { settings.virtualPadHoldSpeech = $0 }
                ))
                .accessibilityHint("On: the pad says when a key turns on, is pressed down, and is released. Off: only the vibrations mark the stages.")
            }
        } header: {
            Text("Hold a key on the pad")
        } footer: {
            Text("Holding a key turns it on like a modifier; holding longer presses it down on the PC so it repeats, until you lift your finger — lifting from there turns it off again. A gentle vibration marks turning on, a firmer one the press.")
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
