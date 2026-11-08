import SwiftUI
import BridgeCore

/// Settings → Pads: the list of pads in swipe order. Every operation is
/// reachable three ways — VoiceOver actions on the row, a context menu, and
/// (for delete and reorder) the list's own edit mode — so none depends on a
/// gesture only some users can make.
struct PadListView: View {
    let store: PadStore

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
                    .contextMenu { rowActions(pad) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { pendingDelete = pad }
                    }
                    .swipeActions(edge: .leading) {
                        Button(pad.isVisible ? "Hide" : "Show") { toggleVisible(pad) }
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
            "Delete \(pendingDelete?.title ?? "pad")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pad in
            Button("Delete pad", role: .destructive) {
                store.delete(pad.id)
                postQueuedAnnouncement("\(pad.title) deleted")
            }
        } message: { _ in
            Text("The pad is deleted on all your devices.")
        }
    }

    private func row(_ pad: Pad) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pad.title)
            Text(sizeText(pad) + (pad.isVisible ? "" : " · Hidden"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // Label is the visible title, so Voice Control can name the row; the
        // details ride in the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pad.title)
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
            if store.duplicate(pad.id) != nil { postQueuedAnnouncement("\(pad.title) duplicated") }
        }
        Button("Delete", role: .destructive) { pendingDelete = pad }
    }

    private func toggleVisible(_ pad: Pad) {
        store.edit(pad.id) { $0.isVisible.toggle() }
        postQueuedAnnouncement("\(pad.title) \(pad.isVisible ? "hidden" : "shown")")
    }

    private func move(_ pad: Pad, by offset: Int) {
        guard store.move(pad.id, by: offset),
              let index = store.pads.firstIndex(where: { $0.id == pad.id }) else { return }
        postQueuedAnnouncement("Moved to position \(index + 1) of \(store.pads.count)")
    }
}
