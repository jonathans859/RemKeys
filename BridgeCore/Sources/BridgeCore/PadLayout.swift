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

/// A key at a place on the grid. A key covers `span` cells of its row,
/// starting at `column`.
public struct PlacedKey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var key: PadKey
    public var row: Int
    public var column: Int
    public var span: Int

    public init(key: PadKey, row: Int, column: Int, span: Int = 1) {
        self.key = key
        self.row = row
        self.column = column
        self.span = max(span, 1)
    }

    public var id: UUID { key.id }
    public var columnRange: Range<Int> { column..<(column + span) }

    public func covers(row: Int, column: Int) -> Bool {
        self.row == row && columnRange.contains(column)
    }
}

public enum PadDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

/// Why an edit on the grid was refused, worded to be announced.
public enum PadEditRefusal: Error, Equatable, Sendable {
    case edge
    case blocked
    case noRoom
    case notFound

    public var announcement: String {
        switch self {
        case .edge: return "Already at the edge"
        case .blocked: return "A wider key is in the way"
        case .noRoom: return "Not enough room"
        case .notFound: return "Key not found"
        }
    }
}

/// One user-editable pad: a rows × columns grid with keys on it. A cell no
/// key covers is a gap — drawn dimmed, silent to the touch, sends nothing.
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
    /// Row-major, kept valid by every mutation.
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
            candidate.span = min(candidate.span, max(self.columns - candidate.column, 1))
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

    /// The widest this key could be made, keeping its place and growing
    /// rightward into free cells, or leftward when the right is taken.
    public func maxSpan(of id: UUID) -> Int {
        guard let placed = placed(id) else { return 1 }
        var low = placed.column
        var high = placed.columnRange.upperBound
        while high < columns, key(atRow: placed.row, column: high) == nil { high += 1 }
        while low > 0, key(atRow: placed.row, column: low - 1) == nil { low -= 1 }
        return high - low
    }

    /// How many keys a resize to `rows` × `columns` would delete. Keys that
    /// merely get narrower are not counted.
    public func keysLost(rows: Int, columns: Int) -> Int {
        keys.filter { $0.row >= rows || $0.column >= columns }.count
    }

    // MARK: Editing

    /// Put a new key into an empty cell.
    @discardableResult
    public mutating func add(_ key: PadKey, row: Int, column: Int, span: Int = 1) -> PadEditRefusal? {
        apply(keys + [PlacedKey(key: key, row: row, column: column, span: span)], or: .noRoom)
    }

    public mutating func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
    }

    /// Replace a key's content (what it sends, label, colour) in place.
    public mutating func updateKey(_ key: PadKey) {
        guard let index = keys.firstIndex(where: { $0.id == key.id }) else { return }
        keys[index].key = key
    }

    /// Set a key's width in cells. Grows to the right where it can, and moves
    /// left only as far as it has to.
    @discardableResult
    public mutating func setSpan(_ id: UUID, to span: Int) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return (.notFound) }
        let original = keys[index]
        let target = max(span, 1)
        guard target != original.span else { return nil }
        let lowest = max(original.column - max(target - original.span, 0), 0)
        for column in stride(from: original.column, through: lowest, by: -1) {
            var candidate = keys
            candidate[index].column = column
            candidate[index].span = target
            if Self.isValid(candidate, rows: rows, columns: columns) {
                keys = candidate
                sortKeys()
                return nil
            }
        }
        return (.noRoom)
    }

    /// Move a key one cell in a direction. Into a gap it simply moves; onto
    /// another key the two swap places. Up and down only swap with keys that
    /// fit inside this key's columns — anything wider is refused rather than
    /// shuffled out of shape.
    @discardableResult
    public mutating func move(_ id: UUID, _ direction: PadDirection) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return (.notFound) }
        let a = keys[index]
        var candidate = keys

        switch direction {
        case .up, .down:
            let target = a.row + (direction == .up ? -1 : 1)
            guard (0..<rows).contains(target) else { return (.edge) }
            let overlapping = keys.indices.filter {
                keys[$0].row == target && keys[$0].columnRange.overlaps(a.columnRange)
            }
            for other in overlapping {
                guard a.columnRange.contains(keys[other].column),
                      keys[other].columnRange.upperBound <= a.columnRange.upperBound
                else { return (.blocked) }
                candidate[other].row = a.row
            }
            candidate[index].row = target

        case .right:
            let next = a.columnRange.upperBound
            guard next < columns else { return (.edge) }
            if let other = keys.firstIndex(where: { $0.covers(row: a.row, column: next) }) {
                candidate[other].column = a.column
                candidate[index].column = a.column + keys[other].span
            } else {
                candidate[index].column = a.column + 1
            }

        case .left:
            guard a.column > 0 else { return (.edge) }
            if let other = keys.firstIndex(where: { $0.covers(row: a.row, column: a.column - 1) }) {
                candidate[index].column = keys[other].column
                candidate[other].column = keys[other].column + a.span
            } else {
                candidate[index].column = a.column - 1
            }
        }
        return apply(candidate, or: .noRoom)
    }

    /// Pick-up-and-place: put a key at a cell. An empty cell receives it; a
    /// cell holding another key swaps the two.
    @discardableResult
    public mutating func place(_ id: UUID, atRow row: Int, column: Int) -> PadEditRefusal? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return (.notFound) }
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
            candidate[index].row = row
            candidate[index].column = column
            // A wide key dropped near the right edge slides left to fit.
            candidate[index].column = min(column, max(columns - a.span, 0))
        }
        return apply(candidate, or: .noRoom)
    }

    /// Change the grid size. Keys outside the new grid are deleted (ask the
    /// user first — see `keysLost`); keys crossing the new right edge narrow.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        rows = min(max(newRows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        columns = min(max(newColumns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        keys = keys.compactMap { placed in
            guard placed.row < rows, placed.column < columns else { return nil }
            var trimmed = placed
            trimmed.span = min(trimmed.span, columns - trimmed.column)
            return trimmed
        }
    }

    // MARK: Helpers

    private mutating func apply(_ candidate: [PlacedKey], or refusal: PadEditRefusal) -> PadEditRefusal? {
        guard Self.isValid(candidate, rows: rows, columns: columns) else { return (refusal) }
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
                  placed.span >= 1,
                  (0..<rows).contains(placed.row),
                  placed.column >= 0,
                  placed.columnRange.upperBound <= columns
            else { return false }
            for column in placed.columnRange {
                guard taken.insert(placed.row * columns + column).inserted else { return false }
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
