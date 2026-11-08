import Foundation

/// A key's background colour, from a fixed named palette.
///
/// Named rather than free-form so that every colour has a word VoiceOver can
/// say and the app can tune each one for light and dark mode. The app maps
/// these to system colours; nothing here knows about UIKit.
public enum PadKeyColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, red, orange, yellow, green, teal, blue, indigo, purple, pink, brown, gray

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Default"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .brown: return "Brown"
        case .gray: return "Grey"
        }
    }
}

/// What one zone on a pad sends: a Windows key, optionally with fixed
/// modifiers (a chord like Ctrl+C), under an optional label of the user's.
public struct PadKey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var vk: UInt16
    /// Modifiers pressed around `vk` on every press. Only the six
    /// `KeyCatalog.modifiers` count; the press order comes from there.
    public var modifiers: Set<UInt16>
    /// The user's own name for the key. Shown **and** spoken, so the visible
    /// label and the accessibility label can never diverge.
    public var customLabel: String?
    public var color: PadKeyColor

    public init(
        id: UUID = UUID(),
        vk: UInt16,
        modifiers: Set<UInt16> = [],
        customLabel: String? = nil,
        color: PadKeyColor = .standard
    ) {
        self.id = id
        self.vk = vk
        self.modifiers = modifiers.intersection(KeyCatalog.modifierVKs).subtracting([vk])
        self.customLabel = customLabel
        self.color = color
    }

    private var trimmedLabel: String? {
        guard let text = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// The name drawn on the key.
    public var label: String {
        trimmedLabel ?? KeyCatalog.comboName(vk: vk, modifiers: modifiers)
    }

    /// The name announced for the key. Identical to `label` when the user
    /// named it; otherwise the spoken form of the key and its modifiers.
    public var spokenLabel: String {
        trimmedLabel ?? KeyCatalog.spokenComboName(vk: vk, modifiers: modifiers)
    }

    /// A bare modifier toggles on lift instead of sending. A modifier *with*
    /// fixed modifiers of its own (Ctrl+Shift as one key) is a chord and sends.
    public var togglesModifier: Bool {
        modifiers.isEmpty && KeyCatalog.isModifier(vk)
    }

    // Tolerant decoding: a record written by a newer version — an added
    // colour, say — must still load rather than take its whole pad with it.
    private enum CodingKeys: String, CodingKey { case id, vk, modifiers, customLabel, color }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            vk: try c.decode(UInt16.self, forKey: .vk),
            modifiers: Set(try c.decodeIfPresent([UInt16].self, forKey: .modifiers) ?? []),
            customLabel: try c.decodeIfPresent(String.self, forKey: .customLabel),
            color: (try? c.decodeIfPresent(PadKeyColor.self, forKey: .color)) ?? .standard
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vk, forKey: .vk)
        // Sorted, so the same key always encodes to the same bytes and a sync
        // never sees a change that isn't one.
        try c.encode(modifiers.sorted(), forKey: .modifiers)
        try c.encodeIfPresent(customLabel, forKey: .customLabel)
        try c.encode(color, forKey: .color)
    }
}

/// A key at a place on the grid: a rectangle `columnSpan` cells wide and
/// `rowSpan` cells tall, with its top-left cell at `row`/`column`.
public struct PlacedKey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var key: PadKey
    public var row: Int
    public var column: Int
    public var columnSpan: Int
    public var rowSpan: Int

    public init(key: PadKey, row: Int, column: Int, columnSpan: Int = 1, rowSpan: Int = 1) {
        self.key = key
        self.row = row
        self.column = column
        self.columnSpan = max(columnSpan, 1)
        self.rowSpan = max(rowSpan, 1)
    }

    public var id: UUID { key.id }
    public var columnRange: Range<Int> { column..<(column + columnSpan) }
    public var rowRange: Range<Int> { row..<(row + rowSpan) }

    public func covers(row: Int, column: Int) -> Bool {
        rowRange.contains(row) && columnRange.contains(column)
    }

    // "span" is the stored name of the width: records from before keys could
    // span rows have only that, and must read as one row tall.
    private enum CodingKeys: String, CodingKey { case key, row, column, span, rowSpan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(PadKey.self, forKey: .key),
            row: try c.decode(Int.self, forKey: .row),
            column: try c.decode(Int.self, forKey: .column),
            columnSpan: try c.decodeIfPresent(Int.self, forKey: .span) ?? 1,
            rowSpan: try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(row, forKey: .row)
        try c.encode(column, forKey: .column)
        try c.encode(columnSpan, forKey: .span)
        try c.encode(rowSpan, forKey: .rowSpan)
    }
}

public enum PadDirection: String, CaseIterable, Sendable {
    case up, down, left, right

    var isVertical: Bool { self == .up || self == .down }
}

/// Why an edit on the grid was refused, worded to be announced. Edits
/// return one of these, or nil when they succeeded.
public enum PadEditRefusal: Error, Equatable, Sendable {
    case edge
    case blocked
    case noRoom
    case notFound

    public var announcement: String {
        switch self {
        case .edge: return "Already at the edge"
        case .blocked: return "A bigger key is in the way"
        case .noRoom: return "Not enough room"
        case .notFound: return "Key not found"
        }
    }
}

/// One user-editable pad: a rows × columns grid with keys on it. A key is a
/// rectangle of cells; a cell no key covers is a gap — drawn dimmed, silent
/// to the touch, sends nothing.
///
/// Every edit builds a candidate layout and keeps it only if it is valid (in
/// bounds, nothing overlapping), so no sequence of edits can corrupt a pad.
public struct Pad: Codable, Equatable, Identifiable, Sendable {
    public static let columnRange = 1...4
    public static let rowRange = 1...6
    /// `modified` of a pad nobody has edited — a shipped default as seeded.
    /// Such a pad is never pushed to iCloud, so a fresh install can't publish
    /// its defaults over pads the user edited on another device.
    public static let neverEdited = Date(timeIntervalSince1970: 0)

    public var id: UUID
    public var title: String
    public private(set) var rows: Int
    public private(set) var columns: Int
    /// Shown on the Virtual Input tab. Hidden pads stay editable.
    public var isVisible: Bool
    /// Row-major by top-left cell, kept valid by every mutation.
    public private(set) var keys: [PlacedKey]
    public var modified: Date

    public init(
        id: UUID = UUID(),
        title: String,
        rows: Int,
        columns: Int,
        isVisible: Bool = true,
        keys: [PlacedKey] = [],
        modified: Date = Pad.neverEdited
    ) {
        self.id = id
        self.title = title
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        self.isVisible = isVisible
        self.modified = modified
        self.keys = []
        // Admit keys one at a time, dropping any that don't fit: a damaged or
        // hand-edited record degrades to a pad with gaps, never to a crash.
        for placed in keys {
            var candidate = placed
            candidate.columnSpan = min(candidate.columnSpan, max(self.columns - candidate.column, 1))
            candidate.rowSpan = min(candidate.rowSpan, max(self.rows - candidate.row, 1))
            let next = self.keys + [candidate]
            if Self.isValid(next, rows: self.rows, columns: self.columns) { self.keys = next }
        }
        sortKeys()
    }

    private enum CodingKeys: String, CodingKey { case id, title, rows, columns, isVisible, keys, modified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Pad",
            rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 3,
            columns: try c.decodeIfPresent(Int.self, forKey: .columns) ?? 3,
            isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
            // Per-key tolerance: one undecodable key loses that key only.
            keys: (try c.decodeIfPresent([FailableKey].self, forKey: .keys) ?? []).compactMap(\.value),
            modified: try c.decodeIfPresent(Date.self, forKey: .modified) ?? Pad.neverEdited
        )
    }

    private struct FailableKey: Decodable {
        let value: PlacedKey?
        init(from decoder: Decoder) throws { value = try? PlacedKey(from: decoder) }
    }

    // MARK: Reading

    public func key(atRow row: Int, column: Int) -> PlacedKey? {
        keys.first { $0.covers(row: row, column: column) }
    }

    public func placed(_ id: UUID) -> PlacedKey? {
        keys.first { $0.id == id }
    }

    /// Whether every cell of the rectangle is free (or belongs to `except`).
    public func isFree(rows rowRange: Range<Int>, columns columnRange: Range<Int>, except: UUID? = nil) -> Bool {
        guard rowRange.lowerBound >= 0, rowRange.upperBound <= rows,
              columnRange.lowerBound >= 0, columnRange.upperBound <= columns else { return false }
        return !keys.contains { placed in
            placed.id != except && placed.rowRange.overlaps(rowRange) && placed.columnRange.overlaps(columnRange)
        }
    }

    /// The widest this key could be made, keeping its rows: free columns on
    /// both sides count, since `setSize` shifts a key left when it must.
    public func maxColumnSpan(of id: UUID) -> Int {
        guard let placed = placed(id) else { return 1 }
        var low = placed.column, high = placed.columnRange.upperBound
        while high < columns, isFree(rows: placed.rowRange, columns: high..<(high + 1)) { high += 1 }
        while low > 0, isFree(rows: placed.rowRange, columns: (low - 1)..<low) { low -= 1 }
        return high - low
    }

    /// The tallest this key could be made, keeping its columns.
    public func maxRowSpan(of id: UUID) -> Int {
        guard let placed = placed(id) else { return 1 }
        var low = placed.row, high = placed.rowRange.upperBound
        while high < rows, isFree(rows: high..<(high + 1), columns: placed.columnRange) { high += 1 }
        while low > 0, isFree(rows: (low - 1)..<low, columns: placed.columnRange) { low -= 1 }
        return high - low
    }

    /// How many keys a resize to `rows` × `columns` would delete. Keys that
    /// merely get smaller are not counted.
    public func keysLost(rows: Int, columns: Int) -> Int {
        keys.filter { $0.row >= rows || $0.column >= columns }.count
    }

    // MARK: Editing

    /// Put a new key at a free rectangle.
    @discardableResult
    public mutating func add(
        _ key: PadKey, row: Int, column: Int, columnSpan: Int = 1, rowSpan: Int = 1
    ) -> PadEditRefusal? {
        apply(keys + [PlacedKey(key: key, row: row, column: column, columnSpan: columnSpan, rowSpan: rowSpan)],
              or: .noRoom)
    }

    public mutating func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
    }

    /// Replace a key's content (what it sends, label, colour) in place.
    public mutating func updateKey(_ key: PadKey) {
        guard let index = keys.firstIndex(where: { $0.id == key.id }) else { return }
        keys[index].key = key
    }

    /// Set a key's size. Grows right and down where it can, and moves left
    /// or up only as far as it has to.
    @discardableResult
    public mutating func setSize(_ id: UUID, columns columnSpan: Int, rows rowSpan: Int) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return .notFound }
        let original = keys[index]
        let width = max(columnSpan, 1), height = max(rowSpan, 1)
        guard width != original.columnSpan || height != original.rowSpan else { return nil }
        let lowestColumn = max(original.column - max(width - original.columnSpan, 0), 0)
        let lowestRow = max(original.row - max(height - original.rowSpan, 0), 0)
        for row in stride(from: original.row, through: lowestRow, by: -1) {
            for column in stride(from: original.column, through: lowestColumn, by: -1) {
                var candidate = keys
                candidate[index].row = row
                candidate[index].column = column
                candidate[index].columnSpan = width
                candidate[index].rowSpan = height
                if Self.isValid(candidate, rows: rows, columns: columns) {
                    keys = candidate
                    sortKeys()
                    return nil
                }
            }
        }
        return .noRoom
    }

    /// Kept for callers that only change the width.
    @discardableResult
    public mutating func setSpan(_ id: UUID, to span: Int) -> PadEditRefusal? {
        guard let placed = placed(id) else { return .notFound }
        return setSize(id, columns: span, rows: placed.rowSpan)
    }

    /// Grow a key by one cell out of one edge — Extend left / right / up /
    /// down. Only into free cells; nothing is pushed aside.
    @discardableResult
    public mutating func extend(_ id: UUID, _ edge: PadDirection) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return .notFound }
        var candidate = keys
        switch edge {
        case .left:
            candidate[index].column -= 1
            candidate[index].columnSpan += 1
        case .right:
            candidate[index].columnSpan += 1
        case .up:
            candidate[index].row -= 1
            candidate[index].rowSpan += 1
        case .down:
            candidate[index].rowSpan += 1
        }
        let grown = candidate[index]
        guard grown.row >= 0, grown.column >= 0,
              grown.rowRange.upperBound <= rows, grown.columnRange.upperBound <= columns
        else { return .edge }
        return apply(candidate, or: .noRoom)
    }

    /// Shrink a key by one cell from one edge — Shrink from left / right /
    /// top / bottom. A key is never smaller than one cell.
    @discardableResult
    public mutating func shrink(_ id: UUID, from edge: PadDirection) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return .notFound }
        var candidate = keys
        switch edge {
        case .left, .right:
            guard candidate[index].columnSpan > 1 else { return .noRoom }
            candidate[index].columnSpan -= 1
            if edge == .left { candidate[index].column += 1 }
        case .up, .down:
            guard candidate[index].rowSpan > 1 else { return .noRoom }
            candidate[index].rowSpan -= 1
            if edge == .up { candidate[index].row += 1 }
        }
        return apply(candidate, or: .noRoom)
    }

    /// Move a key one cell in a direction. Into free cells it simply moves;
    /// onto other keys it swaps places with them. The keys it swaps with must
    /// fit within this key's extent across the move (its rows, for a sideways
    /// move); anything bigger is refused rather than shuffled out of shape.
    @discardableResult
    public mutating func move(_ id: UUID, _ direction: PadDirection) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return .notFound }
        let a = keys[index]
        let vertical = direction.isVertical
        // Along the move: position and length. Across it: the range that
        // neighbours must fit inside.
        let start = vertical ? a.row : a.column
        let length = vertical ? a.rowSpan : a.columnSpan
        let across = vertical ? a.columnRange : a.rowRange
        let limit = vertical ? rows : columns
        let forward = direction == .down || direction == .right

        let edgeCell = forward ? start + length : start - 1
        guard (0..<limit).contains(edgeCell) else { return .edge }

        func along(_ k: PlacedKey) -> (start: Int, length: Int, across: Range<Int>) {
            vertical ? (k.row, k.rowSpan, k.columnRange) : (k.column, k.columnSpan, k.rowRange)
        }
        let neighbours = keys.indices.filter { i in
            guard i != index else { return false }
            let n = along(keys[i])
            let touches = forward ? n.start == edgeCell : n.start + n.length - 1 == edgeCell
            return touches && n.across.overlaps(across)
        }

        var candidate = keys
        func set(_ i: Int, _ value: Int) {
            if vertical { candidate[i].row = value } else { candidate[i].column = value }
        }

        if neighbours.isEmpty {
            set(index, start + (forward ? 1 : -1))
        } else {
            for i in neighbours {
                let n = along(keys[i])
                guard n.across.lowerBound >= across.lowerBound,
                      n.across.upperBound <= across.upperBound else { return .blocked }
            }
            let step = neighbours.map { along(keys[$0]).length }.max() ?? 1
            if forward {
                // Neighbours take this key's old leading edge; it goes past them.
                for i in neighbours { set(i, start) }
                set(index, start + step)
            } else {
                // This key steps back past them; they line up against its old
                // trailing edge.
                set(index, start - step)
                for i in neighbours { set(i, start + length - along(keys[i]).length) }
            }
        }
        return apply(candidate, or: .noRoom)
    }

    /// Pick-up-and-place: put a key at a cell. A free cell receives it (slid
    /// back inside the grid if it would hang off an edge); a cell holding
    /// another key swaps the two.
    @discardableResult
    public mutating func place(_ id: UUID, atRow row: Int, column: Int) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return .notFound }
        let a = keys[index]
        if a.covers(row: row, column: column) { return nil }
        var candidate = keys
        if let other = keys.firstIndex(where: { $0.covers(row: row, column: column) }) {
            let b = keys[other]
            candidate[index].row = b.row
            candidate[index].column = b.column
            candidate[other].row = a.row
            candidate[other].column = a.column
        } else {
            candidate[index].row = min(row, max(rows - a.rowSpan, 0))
            candidate[index].column = min(column, max(columns - a.columnSpan, 0))
        }
        return apply(candidate, or: .noRoom)
    }

    /// Change the grid size. Keys outside the new grid are deleted (ask the
    /// user first — see `keysLost`); keys crossing a new edge get smaller.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        rows = min(max(newRows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        columns = min(max(newColumns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        keys = keys.compactMap { placed in
            guard placed.row < rows, placed.column < columns else { return nil }
            var trimmed = placed
            trimmed.columnSpan = min(trimmed.columnSpan, columns - trimmed.column)
            trimmed.rowSpan = min(trimmed.rowSpan, rows - trimmed.row)
            return trimmed
        }
    }

    // MARK: Helpers

    private mutating func apply(_ candidate: [PlacedKey], or refusal: PadEditRefusal) -> PadEditRefusal? {
        guard Self.isValid(candidate, rows: rows, columns: columns) else { return refusal }
        keys = candidate
        sortKeys()
        return nil
    }

    private mutating func sortKeys() {
        keys.sort { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    static func isValid(_ keys: [PlacedKey], rows: Int, columns: Int) -> Bool {
        var taken = Set<Int>()
        var ids = Set<UUID>()
        for placed in keys {
            guard ids.insert(placed.id).inserted,
                  placed.columnSpan >= 1, placed.rowSpan >= 1,
                  placed.row >= 0, placed.column >= 0,
                  placed.rowRange.upperBound <= rows,
                  placed.columnRange.upperBound <= columns
            else { return false }
            for row in placed.rowRange {
                for column in placed.columnRange {
                    guard taken.insert(row * columns + column).inserted else { return false }
                }
            }
        }
        return true
    }

    /// A copy with fresh ids throughout, for Duplicate.
    public func duplicated(title: String, modified: Date) -> Pad {
        Pad(
            title: title,
            rows: rows,
            columns: columns,
            isVisible: isVisible,
            keys: keys.map { placed in
                var copy = placed
                copy.key.id = UUID()
                return copy
            },
            modified: modified
        )
    }
}
