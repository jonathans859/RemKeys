import SwiftUI
import BridgeCore

/// Edits one pad. The keys are **ordinary buttons laid out as they sit on the
/// pad** — the opposite of the live pad's single direct-touch element, because
/// here every key must be its own VoiceOver stop. Tapping one opens its
/// actions; the same actions are VoiceOver custom actions on it, so a key can
/// be moved, widened or recoloured without opening anything.
///
/// Moving has two ways, both announced: one step at a time (Move up / down /
/// left / right — swaps with the neighbour, says the new row and column), and
/// Pick up then Place here, for longer distances.
struct PadEditorView: View {
    let store: PadStore
    let padID: UUID

    /// The key being carried by Pick up, if any.
    @State private var pickedUp: UUID?
    @State private var keySheet: KeySheet?
    @State private var pendingResize: PendingResize?
    @AccessibilityFocusState private var focusedKey: UUID?

    private struct KeySheet: Identifiable {
        /// nil: adding a new key at `row`/`column`.
        let keyID: UUID?
        let row: Int
        let column: Int
        var id: String { keyID?.uuidString ?? "new-\(row)-\(column)" }
    }

    private struct PendingResize {
        let rows: Int
        let columns: Int
        let lost: Int
    }

    var body: some View {
        if let pad = store.pad(padID) {
            form(pad)
        } else {
            // Deleted on another device while open.
            Text("This pad no longer exists.")
                .foregroundStyle(.secondary)
                .navigationTitle("Pad")
        }
    }

    private func form(_ pad: Pad) -> some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: Binding(
                        get: { pad.title },
                        set: { title in store.edit(padID) { $0.title = title } }
                    ))
                    .multilineTextAlignment(.trailing)
                }
                Toggle("Show on Virtual Input", isOn: Binding(
                    get: { pad.isVisible },
                    set: { on in store.edit(padID) { $0.isVisible = on } }
                ))
                .accessibilityHint("Off: the pad is kept here but skipped when swiping between pads")
                Stepper("Columns: \(pad.columns)", value: Binding(
                    get: { pad.columns },
                    set: { requestResize(pad, rows: pad.rows, columns: $0) }
                ), in: Pad.columnRange)
                .accessibilityHint("Up to \(Pad.columnRange.upperBound). Keys in a removed column are deleted, after asking.")
                Stepper("Rows: \(pad.rows)", value: Binding(
                    get: { pad.rows },
                    set: { requestResize(pad, rows: $0, columns: pad.columns) }
                ), in: Pad.rowRange)
                .accessibilityHint("Up to \(Pad.rowRange.upperBound). Keys in a removed row are deleted, after asking.")
            } header: {
                SectionHeader("Pad", systemImage: "square.grid.3x3.fill")
            }

            Section {
                grid(pad)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                if let pickedUp, let placed = pad.placed(pickedUp) {
                    Button("Cancel moving \(placed.key.label)") { cancelPickUp() }
                }
            } header: {
                SectionHeader("Keys", systemImage: "keyboard")
            }
        }
        .navigationTitle(pad.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $keySheet) { sheet in
            keyEditor(sheet, pad)
        }
        .confirmationDialog(
            "Delete \(pendingResize?.lost ?? 0) \(pendingResize?.lost == 1 ? "key" : "keys")?",
            isPresented: Binding(get: { pendingResize != nil }, set: { if !$0 { pendingResize = nil } }),
            titleVisibility: .visible,
            presenting: pendingResize
        ) { resize in
            Button("Delete and resize", role: .destructive) {
                applyResize(rows: resize.rows, columns: resize.columns)
            }
        } message: { resize in
            Text("\(resize.columns) columns by \(resize.rows) rows leaves no room for them.")
        }
    }

    // MARK: Grid

    private enum Cell: Identifiable {
        case key(PlacedKey)
        case gap(row: Int, column: Int)

        var id: String {
            switch self {
            case .key(let placed): return placed.id.uuidString
            case .gap(let row, let column): return "gap-\(row)-\(column)"
            }
        }

        var span: Int {
            if case .key(let placed) = self { return placed.span }
            return 1
        }
    }

    private func cells(inRow row: Int, of pad: Pad) -> [Cell] {
        var result: [Cell] = []
        var column = 0
        while column < pad.columns {
            if let placed = pad.key(atRow: row, column: column) {
                result.append(.key(placed))
                column = placed.columnRange.upperBound
            } else {
                result.append(.gap(row: row, column: column))
                column += 1
            }
        }
        return result
    }

    private func grid(_ pad: Pad) -> some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<pad.rows, id: \.self) { row in
                GridRow {
                    ForEach(cells(inRow: row, of: pad)) { cell in
                        cellView(cell, pad)
                            .gridCellColumns(cell.span)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell, _ pad: Pad) -> some View {
        switch cell {
        case .key(let placed):
            keyCell(placed, pad)
        case .gap(let row, let column):
            gapCell(row: row, column: column, pad)
        }
    }

    private func keyCell(_ placed: PlacedKey, _ pad: Pad) -> some View {
        let isPicked = pickedUp == placed.id
        let face = KeyFace(text: placed.key.label, color: placed.key.color, isGap: false, isPicked: isPicked)
        return Group {
            if pickedUp != nil {
                // Carrying a key: every cell is a drop target, one tap away.
                Button {
                    if isPicked { cancelPickUp() } else { place(at: placed.row, placed.column, pad) }
                } label: { face }
            } else {
                Menu {
                    keyMenu(placed, pad)
                } label: { face }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(placed.key.label)
        .accessibilityValue(keyValue(placed, pad))
        .accessibilityHint(pickedUp == nil
            ? "Shows what you can do with this key"
            : (isPicked ? "Cancels the move" : "Swaps the picked-up key with this one"))
        .accessibilityActions {
            if pickedUp == nil { keyAccessibilityActions(placed, pad) }
        }
        .accessibilityFocused($focusedKey, equals: placed.id)
    }

    private func gapCell(row: Int, column: Int, _ pad: Pad) -> some View {
        let face = KeyFace(text: "Empty", color: .standard, isGap: true, isPicked: false)
        return Group {
            if pickedUp != nil {
                Button { place(at: row, column, pad) } label: { face }
            } else {
                Menu {
                    Button("Add key…") { keySheet = KeySheet(keyID: nil, row: row, column: column) }
                } label: { face }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Empty")
        .accessibilityValue("Row \(row + 1), column \(column + 1)")
        .accessibilityHint(pickedUp == nil ? "Adds a key here" : "Moves the picked-up key here")
    }

    private func keyValue(_ placed: PlacedKey, _ pad: Pad) -> String {
        var parts = ["Row \(placed.row + 1), column \(placed.column + 1)"]
        if placed.span > 1 { parts.append("\(placed.span) columns wide") }
        if placed.key.color != .standard { parts.append(placed.key.color.displayName) }
        // What it sends, whenever the label doesn't already say so: a custom
        // name ("Copy"), or an abbreviation ("Ctrl+C").
        let sends = KeyCatalog.spokenComboName(vk: placed.key.vk, modifiers: placed.key.modifiers)
        if sends != placed.key.label { parts.append("sends \(sends)") }
        if pickedUp == placed.id { parts.append("picked up") }
        return parts.joined(separator: ", ")
    }

    // MARK: Actions

    /// Whether an edit would succeed, tried on a copy — so impossible actions
    /// are disabled in the menu and absent from the VoiceOver actions, rather
    /// than offered and then refused.
    private func can(_ pad: Pad, _ edit: (inout Pad) -> PadEditRefusal?) -> Bool {
        var copy = pad
        return edit(&copy) == nil
    }

    @ViewBuilder
    private func keyMenu(_ placed: PlacedKey, _ pad: Pad) -> some View {
        Button("Edit key…") { keySheet = KeySheet(keyID: placed.id, row: placed.row, column: placed.column) }
        Picker("Colour", selection: Binding(
            get: { placed.key.color },
            set: { setColor($0, of: placed) }
        )) {
            ForEach(PadKeyColor.allCases) { colour in
                Text(colour.displayName).tag(colour)
            }
        }
        .pickerStyle(.menu)
        Section {
            Button("Wider") { setSpan(placed, placed.span + 1) }
                .disabled(!can(pad) { $0.setSpan(placed.id, to: placed.span + 1) })
            Button("Narrower") { setSpan(placed, placed.span - 1) }
                .disabled(placed.span <= 1)
        }
        Section {
            ForEach(PadDirection.allCases, id: \.self) { direction in
                Button(moveTitle(direction)) { move(placed, direction) }
                    .disabled(!can(pad) { $0.move(placed.id, direction) })
            }
            Button("Pick up to move") { pickUp(placed) }
        }
        Button("Remove key", role: .destructive) { remove(placed) }
    }

    @ViewBuilder
    private func keyAccessibilityActions(_ placed: PlacedKey, _ pad: Pad) -> some View {
        Button("Edit key") { keySheet = KeySheet(keyID: placed.id, row: placed.row, column: placed.column) }
        ForEach(PadDirection.allCases, id: \.self) { direction in
            if can(pad, { $0.move(placed.id, direction) }) {
                Button(moveTitle(direction)) { move(placed, direction) }
            }
        }
        Button("Pick up to move") { pickUp(placed) }
        if can(pad, { $0.setSpan(placed.id, to: placed.span + 1) }) {
            Button("Wider") { setSpan(placed, placed.span + 1) }
        }
        if placed.span > 1 {
            Button("Narrower") { setSpan(placed, placed.span - 1) }
        }
        Button("Next colour") { stepColor(of: placed, by: 1) }
        Button("Previous colour") { stepColor(of: placed, by: -1) }
        Button("Remove key") { remove(placed) }
    }

    private func moveTitle(_ direction: PadDirection) -> String {
        switch direction {
        case .up: return "Move up"
        case .down: return "Move down"
        case .left: return "Move left"
        case .right: return "Move right"
        }
    }

    private func move(_ placed: PlacedKey, _ direction: PadDirection) {
        let refusal: PadEditRefusal? = store.edit(padID) { $0.move(placed.id, direction) } ?? .notFound
        announcePosition(of: placed.id, refusal: refusal, verb: "Moved")
    }

    private func pickUp(_ placed: PlacedKey) {
        pickedUp = placed.id
        postQueuedAnnouncement("\(placed.key.label) picked up. Choose where to put it.")
    }

    private func cancelPickUp() {
        let id = pickedUp
        pickedUp = nil
        postQueuedAnnouncement("Move cancelled")
        focusedKey = id
    }

    private func place(at row: Int, _ column: Int, _ pad: Pad) {
        guard let id = pickedUp else { return }
        let refusal: PadEditRefusal? = store.edit(padID) { $0.place(id, atRow: row, column: column) } ?? .notFound
        if refusal == nil { pickedUp = nil }
        announcePosition(of: id, refusal: refusal, verb: "Placed")
    }

    private func setSpan(_ placed: PlacedKey, _ span: Int) {
        let refusal: PadEditRefusal? = store.edit(padID) { $0.setSpan(placed.id, to: span) } ?? .notFound
        if let refusal {
            postQueuedAnnouncement(refusal.announcement)
        } else {
            postQueuedAnnouncement("\(span) \(span == 1 ? "column" : "columns") wide")
        }
    }

    private func setColor(_ colour: PadKeyColor, of placed: PlacedKey) {
        var key = placed.key
        key.color = colour
        store.edit(padID) { $0.updateKey(key) }
    }

    private func stepColor(of placed: PlacedKey, by offset: Int) {
        let all = PadKeyColor.allCases
        let index = all.firstIndex(of: placed.key.color) ?? 0
        let next = all[(index + offset + all.count) % all.count]
        setColor(next, of: placed)
        postQueuedAnnouncement(next.displayName)
    }

    private func remove(_ placed: PlacedKey) {
        store.edit(padID) { $0.remove(placed.id) }
        postQueuedAnnouncement("\(placed.key.label) removed")
    }

    /// Says where the key is now (or why it didn't move), and keeps VoiceOver
    /// on the key that moved rather than on whatever took its old place.
    private func announcePosition(of id: UUID, refusal: PadEditRefusal?, verb: String) {
        if let refusal {
            postQueuedAnnouncement(refusal.announcement)
            return
        }
        if let placed = store.pad(padID)?.placed(id) {
            postQueuedAnnouncement("\(verb) to row \(placed.row + 1), column \(placed.column + 1)")
        }
        focusedKey = id
    }

    // MARK: Resize

    private func requestResize(_ pad: Pad, rows: Int, columns: Int) {
        let lost = pad.keysLost(rows: rows, columns: columns)
        if lost > 0 {
            pendingResize = PendingResize(rows: rows, columns: columns, lost: lost)
        } else {
            applyResize(rows: rows, columns: columns)
        }
    }

    private func applyResize(rows: Int, columns: Int) {
        store.edit(padID) { $0.resize(rows: rows, columns: columns) }
        if let pickedUp, store.pad(padID)?.placed(pickedUp) == nil { self.pickedUp = nil }
    }

    // MARK: Key sheet

    private func keyEditor(_ sheet: KeySheet, _ pad: Pad) -> some View {
        let existing = sheet.keyID.flatMap { pad.placed($0) }
        // Room a new key could grow into: the run of gaps from its cell.
        let newMaxSpan: Int = {
            var span = 0
            while sheet.column + span < pad.columns,
                  pad.key(atRow: sheet.row, column: sheet.column + span) == nil { span += 1 }
            return max(span, 1)
        }()
        return PadKeyEditor(
            title: existing == nil ? "Add key" : "Edit key",
            initial: existing?.key ?? PadKey(vk: VK.return),
            initialSpan: existing?.span ?? 1,
            maxSpan: existing.map { pad.maxSpan(of: $0.id) } ?? newMaxSpan,
            onSave: { key, span in
                if let existing {
                    store.edit(padID) { pad in
                        pad.updateKey(key)
                        _ = pad.setSpan(existing.id, to: span)
                    }
                } else {
                    store.edit(padID) { $0.add(key, row: sheet.row, column: sheet.column, span: span) }
                    focusedKey = key.id
                }
            },
            onDelete: existing.map { placed in { remove(placed) } }
        )
    }
}

/// How a cell looks in the editor — the same fill and colour treatment as the
/// live pad, so what you edit is what you will touch. State never rests on
/// colour alone: a gap says "Empty", a picked-up key gets a dashed outline
/// and "picked up" in its accessibility value.
private struct KeyFace: View {
    let text: String
    let color: PadKeyColor
    let isGap: Bool
    let isPicked: Bool

    var body: some View {
        Text(text)
            .font(isGap ? .subheadline : .body)
            .foregroundStyle(isGap ? .secondary : .primary)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGap ? Color(uiColor: .quaternarySystemFill) : color.restingFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isPicked ? Color.accentColor : border,
                        style: StrokeStyle(lineWidth: isPicked ? 3 : 1.5, dash: isPicked || isGap ? [6, 4] : [])
                    )
            }
            .contentShape(Rectangle())
    }

    private var border: Color {
        if isGap { return Color(uiColor: .label).opacity(0.2) }
        if let ui = color.uiColor { return Color(uiColor: ui) }
        return Color(uiColor: .label).opacity(0.45)
    }
}
