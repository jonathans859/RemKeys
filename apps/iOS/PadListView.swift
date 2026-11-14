import SwiftUI
import BridgeCore

/// Settings → Pads: the list of pads in swipe order.
///
/// **VoiceOver gets exactly one set of actions per row: the named
/// `accessibilityActions`.** Swipe actions are exposed to VoiceOver by
/// themselves, and with a context menu on the same row items showed up two
/// and three times ("Hide" three times, "Delete" twice — field-reported
/// 2026-11-08). So while VoiceOver runs, the swipe and context-menu builders
/// are left empty; touch users get the same operations there instead.
struct PadListView: View {
    let store: PadStore
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var confirmRestore = false
    @State private var pendingDelete: Pad?
    /// A pad just added: pushed straight into its editor.
    @State private var openedPad: UUID?

    var body: some View {
        List {
            Section {
                ForEach(store.pads) { pad in
                    NavigationLink {
                        PadEditorView(store: store, padID: pad.id)
                    } label: {
                        row(pad)
                    }
                    .accessibilityActions { rowActions(pad) }
                    // Empty while VoiceOver runs — see the note on the type.
                    .contextMenu {
                        if !voiceOverEnabled { rowActions(pad) }
                    }
                    .swipeActions(edge: .trailing) {
                        if !voiceOverEnabled {
                            Button("Delete", role: .destructive) { pendingDelete = pad }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !voiceOverEnabled {
                            Button(pad.isVisible ? "Hide" : "Show") { toggleVisible(pad) }
                        }
                    }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                SectionHeader("Pads", systemImage: "rectangle.stack.fill")
            }

            Section {
                Button("Add pad") { openedPad = store.addPad() }
                    .accessibilityHint("Adds an empty pad of three by three keys and opens it for editing")
                Button("Restore default pads", role: .destructive) { confirmRestore = true }
                    .accessibilityHint("Replaces every pad with the four that ship with the app, on all your devices")
            }
        }
        .navigationTitle("Pads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .navigationDestination(item: $openedPad) { id in
            PadEditorView(store: store, padID: id)
        }
        .confirmationDialog(
            "Restore the default pads?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Restore default pads", role: .destructive) {
                store.restoreDefaults()
                postQueuedAnnouncement("Default pads restored")
            }
        } message: {
            Text("Every pad is replaced by Navigation, Editing, Function keys and Extended function keys, on all your devices. Your own pads are deleted.")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayTitle ?? "pad")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pad in
            Button("Delete pad", role: .destructive) {
                store.delete(pad.id)
                postQueuedAnnouncement("\(pad.displayTitle) deleted")
            }
        } message: { _ in
            Text("The pad is deleted on all your devices.")
        }
    }

    private func row(_ pad: Pad) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pad.displayTitle)
            Text(sizeText(pad) + (pad.isVisible ? "" : " · Hidden"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // Label is the visible title, so Voice Control can name the row; the
        // details ride in the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pad.displayTitle)
        .accessibilityValue("\(pad.columns) columns, \(pad.rows) rows, \(pad.keys.count) keys\(pad.isVisible ? "" : ", hidden")")
    }

    private func sizeText(_ pad: Pad) -> String {
        "\(pad.columns) × \(pad.rows), \(pad.keys.count) \(pad.keys.count == 1 ? "key" : "keys")"
    }

    @ViewBuilder
    private func rowActions(_ pad: Pad) -> some View {
        Button(pad.isVisible ? "Hide on Virtual Input" : "Show on Virtual Input") { toggleVisible(pad) }
        if store.pads.first?.id != pad.id {
            Button("Move up") { move(pad, by: -1) }
        }
        if store.pads.last?.id != pad.id {
            Button("Move down") { move(pad, by: 1) }
        }
        Button("Duplicate") {
            if store.duplicate(pad.id) != nil { postQueuedAnnouncement("\(pad.displayTitle) duplicated") }
        }
        Button("Delete", role: .destructive) { pendingDelete = pad }
    }

    private func toggleVisible(_ pad: Pad) {
        store.edit(pad.id) { $0.isVisible.toggle() }
        postQueuedAnnouncement("\(pad.displayTitle) \(pad.isVisible ? "hidden" : "shown")")
    }

    private func move(_ pad: Pad, by offset: Int) {
        guard store.move(pad.id, by: offset),
              let index = store.pads.firstIndex(where: { $0.id == pad.id }) else { return }
        postQueuedAnnouncement("Moved to position \(index + 1) of \(store.pads.count)")
    }
}
