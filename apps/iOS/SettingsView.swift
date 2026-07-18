import SwiftUI
import BridgeCore

/// Modifier-mapping settings. There is no fixed correct mapping between the
/// Apple and Windows modifier layouts, so Option and Command are each routed
/// to a Windows modifier the user chooses.
struct SettingsView: View {
    let settings: AppSettings
    @State private var isRecordingShortcut = false

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
            }
            .navigationTitle("Settings")
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
