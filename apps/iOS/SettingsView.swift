import SwiftUI
import BridgeCore

/// Modifier-mapping settings. There is no fixed correct mapping between the
/// Apple and Windows modifier layouts, so Option and Command are each routed
/// to a Windows modifier the user chooses.
struct SettingsView: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isRecordingShortcut = false

    var body: some View {
        NavigationStack {
            Form {
                toggleShortcutSection
                Section {
                    mappingPicker(
                        title: "Option key",
                        selection: Binding(
                            get: { settings.optionMapping },
                            set: { settings.optionMapping = $0 }
                        ),
                        hint: "Where the Option key lands on the Windows PC"
                    )
                    mappingPicker(
                        title: "Command key",
                        selection: Binding(
                            get: { settings.commandMapping },
                            set: { settings.commandMapping = $0 }
                        ),
                        hint: "Where the Command key lands on the Windows PC"
                    )
                } header: {
                    Text("Modifier mapping")
                } footer: {
                    Text("Shift and Control always map to Windows Shift and Control.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
