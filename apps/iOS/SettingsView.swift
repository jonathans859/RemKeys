import SwiftUI
import BridgeCore

/// The set-and-forget half of the app: modifier mapping, the optional physical
/// toggle shortcut, and the key pad's behaviour — including the pad editor
/// (Pads → `PadListView` → `PadEditorView`).
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
    let padStore: PadStore
    @State private var isRecordingShortcut = false
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            Form {
                toggleShortcutSection
                modifierMappingSection
                screenCurtainSection
                dropCueSection
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
                     : "Pressing \(settings.toggleShortcut?.displayString ?? "the recorded chord") on the physical keyboard flips forwarding, even while it is off. Caps Lock counts as part of the shortcut only while you hold it down, so switching the lock on or off doesn't change whether the shortcut works.")
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
                Text("The curtain blacks the display out; on iPhones with an OLED screen black pixels are switched off, which is where most of a long session's battery goes. It leaves the brightness alone, so the lock screen is never dark. Forwarding keeps running underneath it, and a double tap turns the screen back on.")
                Text(settings.autoScreenCurtain
                     ? "It is raised for you as soon as a session connects with a hardware keyboard attached, so starting a session is one press. Without a keyboard it stays down, since you will most likely use the Virtual Input pad; a keyboard connected later in the session raises it then. It happens once per session — dismiss it and it stays down until you start forwarding again — and never while you are on the Virtual Input tab."
                     : "It is raised only when you press Screen curtain on the Start tab. Turn the setting on to have it raised for you when a session connects with a hardware keyboard attached.")
                Text("Locking the phone or leaving the app takes the curtain down, so you come back to a normal screen. Control Center and notifications leave it up.")
            } header: {
                SectionHeader("Screen curtain", systemImage: "moon.stars")
            }
            Section {
                Text(settings.dropCueEnabled
                     ? "A key you type while forwarding is on but the PC can't be reached — the connection is down or being rebuilt — is lost, not saved up for later. The phone then vibrates and ticks, once per burst of typing rather than once per key, so you notice straight away instead of finding the text missing afterwards. The tick follows the silent switch; the vibration doesn't."
                     : "Keys typed while the PC can't be reached are lost silently. Turn the setting on for a vibration and a tick when that happens.")
                Text("No tick is not a promise that a key arrived: when the network vanishes without warning, the app needs up to about 25 seconds to notice, and keys typed in that time look sent.")
            } header: {
                SectionHeader("Dropped keys", systemImage: "exclamationmark.triangle")
            }
            Section {
                Text(padStore.visiblePads.isEmpty
                     ? "No pad is shown on Virtual Input right now. Open Pads to show one or add a new one."
                     : "The Virtual Input tab shows one pad at a time — \(pageCountLabel)." + (VirtualKeys.gestures(doing: .nextPad, in: settings).map { " A \($0) moves to the next one." } ?? ""))
                Text("Gestures sets what two- and three-finger swipes, taps and twists do on the pad: change pad, clear the modifiers, or send any key, with modifiers if you like — Alt + Tab on a twist, say. Wait for more fingers holds a touch silent for a moment, so a second finger landing a beat late still makes a gesture instead of sending the first finger's key.")
                Text("Pads opens the editor. Each pad is a grid of up to \(Pad.columnRange.upperBound) columns and \(Pad.rowRange.upperBound) rows; every key is a button there, laid out as on the pad, with its actions in a menu and as VoiceOver actions: edit what it sends, its name and colour, make it wider, move it, or pick it up and place it somewhere else. Empty spaces are dimmed on the pad and send nothing. Pads sync through iCloud, and Restore default pads brings back the four that ship with the app.")
                Text(settings.virtualPadModifiersAcrossPads
                     ? "A modifier you turn on stays on when you change to another pad, even one that doesn't show it."
                     : "Swiping to another pad turns every modifier off, so one can never be on without its key on screen.")
                Text(settings.virtualPadRichHaptics
                     ? "Vibrations report state by how hard they are: the usual light tick for a key that is off, a firmer knock for one that is turned on, and a hard knock for a key held down on the PC. Always one vibration per key."
                     : "Vibrations are plain: the same light tick for every key, whatever its state.")
                Text("Letters and digits can go on a pad, but the text field on the Virtual Input tab is usually faster for them: it is the iPhone's own keyboard.")
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
            // Field-found 2026-11: multi-OS boards swap the codes themselves.
            Text("Shift and Control always map straight across.\nSwitching a keyboard between Mac and Windows mode swaps Option and Command.")
        }
    }

    /// The curtain's own button lives on the Start tab; this is the
    /// set-and-forget half — whether a session raises it without being asked.
    private var screenCurtainSection: some View {
        Section {
            Toggle("Raise the curtain when a keyboard is connected", isOn: Binding(
                get: { settings.autoScreenCurtain },
                set: { settings.autoScreenCurtain = $0 }
            ))
            .accessibilityHint("On: once a forwarding session reaches the PC and a hardware keyboard is connected, the screen goes black by itself. Without a keyboard it stays on, for the Virtual Input pad. Off: raise it with the Screen curtain button on the Start tab.")
        } header: {
            SectionHeader("Screen curtain", systemImage: "moon.stars")
        }
    }

    private var dropCueSection: some View {
        Section {
            Toggle("Tick when a key can't be sent", isOn: Binding(
                get: { settings.dropCueEnabled },
                set: { settings.dropCueEnabled = $0 }
            ))
            .accessibilityHint("On: a key typed while the PC can't be reached gives a vibration and a tick, once per burst of typing. Off: such keys are lost silently.")
        } header: {
            SectionHeader("Dropped keys", systemImage: "exclamationmark.triangle")
        }
    }

    private var keyPadSection: some View {
        Section {
            NavigationLink {
                PadListView(store: padStore)
            } label: {
                LabeledContent("Pads", value: "\(padStore.visiblePads.count) of \(padStore.pads.count) shown")
            }
            .accessibilityHint("Add, remove, reorder and edit the pads of the Virtual Input tab")

            NavigationLink {
                PadGesturesView(settings: settings)
            } label: {
                LabeledContent("Gestures", value: "\(assignedGestureCount) assigned")
            }
            .accessibilityHint("Chooses what two- and three-finger swipes, taps and twists do on the pad")

            Toggle("Modifiers stay on across pads", isOn: Binding(
                get: { settings.virtualPadModifiersAcrossPads },
                set: { settings.virtualPadModifiersAcrossPads = $0 }
            ))
            .accessibilityHint("On: a modifier you turn on stays on when you swipe to another pad. Off: changing pads turns every modifier off.")

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
                SteppedSliderRow(
                    title: "Presses down after",
                    value: Binding(
                        get: { settings.virtualPadHoldDelay },
                        set: { settings.virtualPadHoldDelay = $0 }
                    ),
                    range: AppSettings.holdDelayRange,
                    step: 0.1,
                    valueText: secondsLabel,
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

    /// Names the visible pads for the info sheet, so it never lists one that
    /// isn't there.
    private var pageCountLabel: String {
        VirtualKeys.spokenList(padStore.visiblePads.map(\.title))
    }

    private var assignedGestureCount: Int {
        PadGesture.allCases.filter { settings.gestureAction(for: $0).kind != .nothing }.count
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
