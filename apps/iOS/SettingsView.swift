import SwiftUI
import BridgeCore

/// The set-and-forget half of the app: modifier mapping, the optional physical
/// toggle shortcut, and the key pad's behaviour.
///
/// **The rows here do not explain themselves.** Every section used to carry a
/// paragraph of footer saying what its controls were for, which turned a
/// twelve-control screen into a wall of text you had to read past to reach the
/// switch you came for (field-reported 2026-08-23). The teaching text lives in
/// exactly two places instead, both of them opt-in: the info sheet behind the
/// toolbar button — which says it better, because it describes the settings as
/// they are currently set — and the VoiceOver hint on each control, which
/// costs a sighted user no screen space at all. A footer survives here only
/// where a control would be genuinely ambiguous without one.
struct SettingsView: View {
    let settings: AppSettings
    @State private var isRecordingShortcut = false
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            Form {
                toggleShortcutSection
                modifierMappingSection
                screenCurtainSection
                keyPadSection
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
    /// examples always describe what the app is doing right now. This is where
    /// the screen's explanations live — see the note on the type.
    private var infoSheet: some View {
        InfoSheet(title: "Settings") {
            Section {
                Text(settings.toggleShortcut == nil
                     ? "No shortcut is recorded, so forwarding is toggled with the Start button or a two-finger double tap. Record a physical chord to flip forwarding straight from the keyboard."
                     : "Pressing \(settings.toggleShortcut?.displayString ?? "the recorded chord") on the physical keyboard flips forwarding, even while it is off. While forwarding is on, chords using the Command key are claimed for the PC, so prefer a shortcut without Command.")
            } header: {
                SectionHeader("Toggle shortcut", systemImage: "command")
            }
            Section {
                Text("There is no single correct way to map Apple modifiers to Windows ones, so Option and Command each map per physical side. Multi-OS keyboards often present their Win-labeled key as Command — press a key and check Last key seen in the Start tab's info sheet to find out what it reports as. Shift and Control always map straight across. AltGr matters on layouts like German, where it is the only way to type characters such as @ and the braces.")
                Text("Left and right map independently: for a key right of Space that should act as AltGr, set only that side.")
            } header: {
                SectionHeader("Modifier mapping", systemImage: "option")
            }
            Section {
                Text("The curtain blacks the display out and takes the brightness to zero, which is where most of a long session's battery goes. Forwarding keeps running underneath it, and a double tap turns the screen back on.")
                Text(settings.autoScreenCurtain
                     ? "It is raised for you as soon as a session connects, so starting a session is one press. It happens once per session — dismiss it and it stays down until you start forwarding again — and never while you are on the Virtual Input tab, where it would cover the key pad."
                     : "It is raised only when you press Screen curtain on the Start tab. Turn the setting on to have it raised for you the moment a session connects.")
            } header: {
                SectionHeader("Screen curtain", systemImage: "moon.stars")
            }
            Section {
                Text("The pad is three zones wide and two blocks tall: one page of keys on top — \(pageCountLabel) — and the six modifiers permanently across the bottom two rows, where they never move. Two-finger swipe left or right on the pad changes the page; the page control at the top left of the Virtual Input screen does the same and can be flicked up or down.")
                Text(settings.virtualPadExtendedFKeys
                     ? "F13 to F24 are available as a further page. The other pages are unaffected — an extra page costs no room."
                     : "F13 to F24 are hidden. Adding them makes one more page and takes nothing away from the others.")
                Text(settings.virtualPadRichHaptics
                     ? "Vibrations report state by how hard they are: the usual light tick for a key that is off, a firmer knock for one that is turned on, and a hard knock for a key held down on the PC. Always one vibration per key."
                     : "Vibrations are plain: the same light tick for every key, whatever its state.")
                Text("Letters, digits and punctuation are deliberately not on the pad — they go in the text field, typed with the iPhone's own keyboard, which is faster than anything a three-wide pad could offer.")
            } header: {
                SectionHeader("Key pad", systemImage: "square.grid.3x3.fill")
            }
            Section {
                Text(settings.virtualPadHoldEnabled
                     ? "Holding a key on the pad for \(secondsLabel(settings.virtualPadHoldDelay)) presses it down on the PC, where it stays — and repeats — until you lift your finger. That is how to delete a run of text with Backspace, or keep scrolling with Down. It works on modifiers too, which is how to send a plain Caps Lock press and flip the lock itself."
                     : "Holding is off, so the pad only acts when you lift: modifiers toggle, other keys send. Turn it on to hold a key down on the PC for key repeat.")
                Text("Vibrations mark the hold whether or not the spoken cues are on: a firm one when the key goes down on the PC, a light one when it is released.")
            } header: {
                SectionHeader("Hold a key", systemImage: "hand.tap.fill")
            }
        }
    }

    // MARK: Sections

    private var toggleShortcutSection: some View {
        Section {
            LabeledContent("Shortcut") {
                // A keycap pill rather than plain grey text: it echoes the app
                // icon, and it makes the one value on this screen that is a
                // *key* look like one.
                Text(settings.toggleShortcut?.displayString ?? "None")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(settings.toggleShortcut == nil ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(settings.toggleShortcut == nil ? 0.06 : 0.14))
                    }
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
                .accessibilityHint("Records a physical keyboard shortcut that turns forwarding on and off, whether it is currently on or not")

                if settings.toggleShortcut != nil {
                    Button("Clear shortcut", role: .destructive) {
                        settings.toggleShortcut = nil
                    }
                }
            }
        } header: {
            SectionHeader("Toggle shortcut", systemImage: "command")
        }
    }

    private var modifierMappingSection: some View {
        Section {
            mappingPicker(
                title: "Left Option",
                selection: Binding(
                    get: { settings.leftOptionMapping },
                    set: { settings.leftOptionMapping = $0 }
                ),
                hint: "Where the left Option key lands on the Windows PC. Sides map independently."
            )
            mappingPicker(
                title: "Right Option",
                selection: Binding(
                    get: { settings.rightOptionMapping },
                    set: { settings.rightOptionMapping = $0 }
                ),
                hint: "Where the right Option key lands on the Windows PC. Set this one to AltGr for a key right of Space."
            )
            mappingPicker(
                title: "Left Command",
                selection: Binding(
                    get: { settings.leftCommandMapping },
                    set: { settings.leftCommandMapping = $0 }
                ),
                hint: "Where the left Command key lands on the Windows PC. Multi-OS keyboards report their Windows-labeled key as Command."
            )
            mappingPicker(
                title: "Right Command",
                selection: Binding(
                    get: { settings.rightCommandMapping },
                    set: { settings.rightCommandMapping = $0 }
                ),
                hint: "Where the right Command key lands on the Windows PC. Multi-OS keyboards report their Windows-labeled key as Command."
            )
        } header: {
            SectionHeader("Modifier mapping", systemImage: "option")
        } footer: {
            // The one footer worth its space on this screen: without it the
            // section looks like it covers every modifier, and the reason two
            // of them are missing is not guessable from four pickers.
            Text("Shift and Control always map straight across.")
        }
    }

    /// The curtain's own button lives on the Start tab; this is the
    /// set-and-forget half — whether a session raises it without being asked.
    private var screenCurtainSection: some View {
        Section {
            Toggle("Raise the curtain on connecting", isOn: Binding(
                get: { settings.autoScreenCurtain },
                set: { settings.autoScreenCurtain = $0 }
            ))
            .accessibilityHint("On: the screen goes black by itself as soon as a forwarding session reaches the PC. Off: raise it with the Screen curtain button on the Start tab.")
        } header: {
            SectionHeader("Screen curtain", systemImage: "moon.stars")
        }
    }

    private var keyPadSection: some View {
        Section {
            Toggle("Include F13 to F24", isOn: Binding(
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
            SectionHeader("Key pad", systemImage: "square.grid.3x3.fill")
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
            SectionHeader("Hold a key", systemImage: "hand.tap.fill")
        }
    }

    // MARK: Row builders

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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(secondsLabel(value.wrappedValue))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
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
