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
    /// While VoiceOver runs a cell is a plain button, never a `Menu`: the
    /// named actions are then the only list of operations it hears (a menu
    /// next to them was a second, duplicating source — field-reported
    /// 2026-11-08).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// One grid row's height in the editor; grows with Dynamic Type.
    @ScaledMetric private var rowHeight: CGFloat = 56

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

    /// Every key, plus every cell no key covers, in reading order of their
    /// top-left cell — which is also the VoiceOver order.
    private enum Cell: Identifiable {
        case key(PlacedKey)
        case gap(row: Int, column: Int)

        var id: String {
            switch self {
            case .key(let placed): return placed.id.uuidString
            case .gap(let row, let column): return "gap-\(row)-\(column)"
            }
        }

        var frame: PadCellFrame {
            switch self {
            case .key(let p): return PadCellFrame(row: p.row, column: p.column, columnSpan: p.columnSpan, rowSpan: p.rowSpan)
            case .gap(let row, let column): return PadCellFrame(row: row, column: column, columnSpan: 1, rowSpan: 1)
            }
        }
    }

    private func cells(of pad: Pad) -> [Cell] {
        var result: [Cell] = []
        for row in 0..<pad.rows {
            for column in 0..<pad.columns {
                if let placed = pad.key(atRow: row, column: column) {
                    if placed.row == row && placed.column == column { result.append(.key(placed)) }
                } else {
                    result.append(.gap(row: row, column: column))
                }
            }
        }
        return result
    }

    /// A custom layout rather than SwiftUI's `Grid`, which can span columns
    /// but not rows.
    private func grid(_ pad: Pad) -> some View {
        PadGridLayout(rows: pad.rows, columns: pad.columns, rowHeight: rowHeight) {
            ForEach(cells(of: pad)) { cell in
                cellView(cell, pad)
                    .layoutValue(key: PadCellPosition.self, value: cell.frame)
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
            } else if voiceOverEnabled {
                // Double tap edits; everything else is in the actions rotor.
                Button {
                    keySheet = KeySheet(keyID: placed.id, row: placed.row, column: placed.column)
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
            ? "Opens the key's settings. Swipe up or down for more actions."
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
            } else if voiceOverEnabled {
                Button { keySheet = KeySheet(keyID: nil, row: row, column: column) } label: { face }
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
        if placed.columnSpan > 1 { parts.append("\(placed.columnSpan) columns wide") }
        if placed.rowSpan > 1 { parts.append("\(placed.rowSpan) rows tall") }
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
        Menu("Size") {
            Section {
                ForEach(PadDirection.allCases, id: \.self) { edge in
                    Button(extendTitle(edge)) { resizeKey(placed, edge, grow: true) }
                        .disabled(!can(pad) { $0.extend(placed.id, edge) })
                }
            }
            Section {
                ForEach(PadDirection.allCases, id: \.self) { edge in
                    Button(shrinkTitle(edge)) { resizeKey(placed, edge, grow: false) }
                        .disabled(!can(pad) { $0.shrink(placed.id, from: edge) })
                }
            }
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
        ForEach(PadDirection.allCases, id: \.self) { edge in
            if can(pad, { $0.extend(placed.id, edge) }) {
                Button(extendTitle(edge)) { resizeKey(placed, edge, grow: true) }
            }
        }
        ForEach(PadDirection.allCases, id: \.self) { edge in
            if can(pad, { $0.shrink(placed.id, from: edge) }) {
                Button(shrinkTitle(edge)) { resizeKey(placed, edge, grow: false) }
            }
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

    private func extendTitle(_ edge: PadDirection) -> String {
        switch edge {
        case .up: return "Extend up"
        case .down: return "Extend down"
        case .left: return "Extend left"
        case .right: return "Extend right"
        }
    }

    private func shrinkTitle(_ edge: PadDirection) -> String {
        switch edge {
        case .up: return "Shrink from top"
        case .down: return "Shrink from bottom"
        case .left: return "Shrink from left"
        case .right: return "Shrink from right"
        }
    }

    /// Grow or shrink one edge, then say the new size and where the key now
    /// starts — extending up or left moves its top-left cell.
    private func resizeKey(_ placed: PlacedKey, _ edge: PadDirection, grow: Bool) {
        let refusal: PadEditRefusal? = store.edit(padID) { pad in
            grow ? pad.extend(placed.id, edge) : pad.shrink(placed.id, from: edge)
        } ?? .notFound
        if let refusal {
            postQueuedAnnouncement(refusal.announcement)
        } else if let now = store.pad(padID)?.placed(placed.id) {
            postQueuedAnnouncement(sizeDescription(now))
        }
        focusedKey = placed.id
    }

    private func sizeDescription(_ placed: PlacedKey) -> String {
        let wide = "\(placed.columnSpan) \(placed.columnSpan == 1 ? "column" : "columns") wide"
        let tall = "\(placed.rowSpan) \(placed.rowSpan == 1 ? "row" : "rows") tall"
        return "\(wide), \(tall), from row \(placed.row + 1), column \(placed.column + 1)"
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
        // Room a new key could grow into from its cell: rightward along its
        // row, downward along its column. A size needing both is checked on
        // save.
        let newMaxColumns: Int = {
            var n = 0
            while sheet.column + n < pad.columns, pad.key(atRow: sheet.row, column: sheet.column + n) == nil { n += 1 }
            return max(n, 1)
        }()
        let newMaxRows: Int = {
            var n = 0
            while sheet.row + n < pad.rows, pad.key(atRow: sheet.row + n, column: sheet.column) == nil { n += 1 }
            return max(n, 1)
        }()
        return PadKeyEditor(
            title: existing == nil ? "Add key" : "Edit key",
            initial: existing?.key ?? PadKey(vk: VK.return),
            initialColumns: existing?.columnSpan ?? 1,
            initialRows: existing?.rowSpan ?? 1,
            maxColumns: existing.map { pad.maxColumnSpan(of: $0.id) } ?? newMaxColumns,
            maxRows: existing.map { pad.maxRowSpan(of: $0.id) } ?? newMaxRows,
            onSave: { key, columns, rows in
                if let existing {
                    let refusal: PadEditRefusal? = store.edit(padID) { pad in
                        pad.updateKey(key)
                        return pad.setSize(existing.id, columns: columns, rows: rows)
                    } ?? .notFound
                    if refusal != nil { postQueuedAnnouncement("Key saved. That size doesn't fit here, so it kept its old size.") }
                } else {
                    let refusal: PadEditRefusal? = store.edit(padID) {
                        $0.add(key, row: sheet.row, column: sheet.column, columnSpan: columns, rowSpan: rows)
                    } ?? .notFound
                    if refusal != nil {
                        // The width and the height each fit, together they don't.
                        store.edit(padID) { $0.add(key, row: sheet.row, column: sheet.column) }
                        postQueuedAnnouncement("That size doesn't fit here, so the key was added as one cell.")
                    }
                    focusedKey = key.id
                }
            },
            onDelete: existing.map { placed in { remove(placed) } }
        )
    }
}

/// Where a cell sits in the editor's grid.
struct PadCellFrame: Equatable {
    let row: Int
    let column: Int
    let columnSpan: Int
    let rowSpan: Int
}

private struct PadCellPosition: LayoutValueKey {
    static let defaultValue = PadCellFrame(row: 0, column: 0, columnSpan: 1, rowSpan: 1)
}

/// Places each cell at its row and column, spanning as many of each as it
/// covers. Columns share the width equally; rows are a fixed height.
private struct PadGridLayout: Layout {
    let rows: Int
    let columns: Int
    let rowHeight: CGFloat
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width ?? 320,
            height: CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = (bounds.width - CGFloat(max(columns - 1, 0)) * spacing) / CGFloat(max(columns, 1))
        for subview in subviews {
            let f = subview[PadCellPosition.self]
            let size = CGSize(
                width: CGFloat(f.columnSpan) * columnWidth + CGFloat(f.columnSpan - 1) * spacing,
                height: CGFloat(f.rowSpan) * rowHeight + CGFloat(f.rowSpan - 1) * spacing
            )
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(f.column) * (columnWidth + spacing),
                    y: bounds.minY + CGFloat(f.row) * (rowHeight + spacing)
                ),
                proposal: ProposedViewSize(size)
            )
        }
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
            .foregroundStyle(isGap ? Color.secondary : Color(uiColor: color.restingText))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGap ? Color(uiColor: .quaternarySystemFill) : Color(uiColor: color.restingFill))
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
        // A full-strength fill needs an outline that isn't its own colour.
        return Color(uiColor: .label).opacity(0.45)
    }
}
