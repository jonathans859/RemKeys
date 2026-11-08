import SwiftUI
import BridgeCore

/// The sheet for adding or editing one key: which Windows key it sends, any
/// modifiers pressed with it every time (a fixed chord such as Ctrl+C), its
/// name, colour, width and height.
struct PadKeyEditor: View {
    let title: String
    let maxColumns: Int
    let maxRows: Int
    /// The key, its width and its height in cells.
    let onSave: (PadKey, Int, Int) -> Void
    let onDelete: (() -> Void)?

    @State private var key: PadKey
    @State private var columns: Int
    @State private var rows: Int
    @State private var labelText: String
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        initial: PadKey,
        initialColumns: Int,
        initialRows: Int,
        maxColumns: Int,
        maxRows: Int,
        onSave: @escaping (PadKey, Int, Int) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.title = title
        self.maxColumns = max(maxColumns, 1)
        self.maxRows = max(maxRows, 1)
        self.onSave = onSave
        self.onDelete = onDelete
        _key = State(initialValue: initial)
        _columns = State(initialValue: min(initialColumns, max(maxColumns, 1)))
        _rows = State(initialValue: min(initialRows, max(maxRows, 1)))
        _labelText = State(initialValue: initial.customLabel ?? "")
    }

    /// The key as it would be saved.
    private var result: PadKey {
        PadKey(
            id: key.id,
            vk: key.vk,
            modifiers: key.modifiers,
            customLabel: labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : labelText,
            color: key.color
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        KeyPickerView(selection: Binding(
                            get: { key.vk },
                            set: { vk in
                                key.vk = vk
                                // A key is never its own modifier.
                                key.modifiers.remove(vk)
                            }
                        ))
                    } label: {
                        LabeledContent("Key", value: KeyCatalog.spokenName(for: key.vk))
                    }
                    LabeledContent("Sends", value: KeyCatalog.spokenComboName(vk: key.vk, modifiers: key.modifiers))
                } header: {
                    SectionHeader("Key", systemImage: "keyboard")
                }

                Section {
                    ForEach(KeyCatalog.modifiers) { modifier in
                        Toggle(modifier.spokenName, isOn: Binding(
                            get: { key.modifiers.contains(modifier.vk) },
                            set: { on in
                                if on { key.modifiers.insert(modifier.vk) } else { key.modifiers.remove(modifier.vk) }
                            }
                        ))
                        .disabled(modifier.vk == key.vk)
                    }
                } header: {
                    SectionHeader("Pressed together with", systemImage: "option")
                }

                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $labelText, prompt: Text(KeyCatalog.comboName(vk: key.vk, modifiers: key.modifiers)))
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityHint("Shown on the key and spoken for it. Leave empty to use the key's own name.")
                    Picker("Colour", selection: $key.color) {
                        ForEach(PadKeyColor.allCases) { colour in
                            Text(colour.displayName).tag(colour)
                        }
                    }
                    .pickerStyle(.menu)
                    if maxColumns > 1 {
                        Stepper("Width: \(columns) \(columns == 1 ? "column" : "columns")", value: $columns, in: 1...maxColumns)
                            .accessibilityHint("How many columns the key covers. At most \(maxColumns) here.")
                    }
                    if maxRows > 1 {
                        Stepper("Height: \(rows) \(rows == 1 ? "row" : "rows")", value: $rows, in: 1...maxRows)
                            .accessibilityHint("How many rows the key covers. At most \(maxRows) here.")
                    }
                } header: {
                    SectionHeader("Look", systemImage: "paintpalette")
                }

                if let onDelete {
                    Section {
                        Button("Remove key", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(result, columns, rows)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Every key a pad can send, grouped and searchable. Rows show the spoken
/// name first so the visible text is what VoiceOver and Voice Control say
/// ("Minus", with "-" beside it).
struct KeyPickerView: View {
    @Binding var selection: UInt16
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var categories: [KeyCategory] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return KeyCatalog.categories }
        return KeyCatalog.categories.compactMap { category in
            let keys = category.keys.filter {
                $0.spokenName.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
            }
            return keys.isEmpty ? nil : KeyCategory(title: category.title, keys: keys)
        }
    }

    var body: some View {
        List {
            ForEach(categories) { category in
                Section {
                    ForEach(category.keys) { key in
                        Button {
                            selection = key.vk
                            dismiss()
                        } label: {
                            HStack {
                                Text(key.spokenName)
                                    .foregroundStyle(.primary)
                                if key.name != key.spokenName {
                                    Text(key.name)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                Spacer()
                                if key.vk == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(key.vk == selection ? .isSelected : [])
                    }
                } header: {
                    SectionHeader(category.title, systemImage: "keyboard")
                }
            }
        }
        .searchable(text: $query, prompt: "Search keys")
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}
