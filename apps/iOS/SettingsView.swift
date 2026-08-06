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
            Section("Virtual input") {
                Text(settings.virtualPadSliderMode
                     ? "The key pad currently uses slider gestures: swipe between rows and through keys, tap to send. Turn the toggle off for the grid, where dragging explores the keys and lifting sends."
                     : "The key pad currently uses the grid: dragging explores the keys and lifting sends. Turn the slider toggle on for row-based swiping instead — an alternative if the grid zones feel too small.")
                Text(settings.virtualPadExtendedFKeys
                     ? "F13 to F24 are shown as a fifth band, which makes every zone a bit smaller."
                     : "F13 to F24 are hidden; enable them to add a fifth band at the cost of smaller zones.")
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
            Toggle("Key pad uses slider gestures", isOn: Binding(
                get: { settings.virtualPadSliderMode },
                set: { settings.virtualPadSliderMode = $0 }
            ))
            .accessibilityHint("Off: drag on the pad to hear keys and lift to send. On: swipe left or right to choose a row, up or down to choose its key, tap to send.")
            Toggle("Key pad includes F13 to F24", isOn: Binding(
                get: { settings.virtualPadExtendedFKeys },
                set: { settings.virtualPadExtendedFKeys = $0 }
            ))
            .accessibilityHint("Adds a fifth band to the key pad. The other bands get less room.")
        } header: {
            Text("Virtual input")
        } footer: {
            Text("Keys sent from the key pad are always wrapped in the modifiers currently toggled on.")
        }
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
