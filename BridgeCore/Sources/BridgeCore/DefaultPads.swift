import Foundation

/// The pads a fresh install starts with, and what "Restore default pads"
/// brings back: the four pages the pad has always had, each now carrying the
/// six modifiers as its bottom two rows (modifiers are ordinary keys since
/// pads became editable — there is no separate block any more).
///
/// **The ids are fixed.** Two devices seeding defaults independently must
/// agree that their "Navigation" is the same record, or iCloud sync would
/// show every default twice.
public enum DefaultPads {
    public static let navigationID = UUID(uuidString: "6A1F0000-0000-4000-8000-000000000001")!
    public static let editingID = UUID(uuidString: "6A1F0000-0000-4000-8000-000000000002")!
    public static let functionKeysID = UUID(uuidString: "6A1F0000-0000-4000-8000-000000000003")!
    public static let extendedFunctionKeysID = UUID(uuidString: "6A1F0000-0000-4000-8000-000000000004")!

    public static let ids: Set<UUID> = [navigationID, editingID, functionKeysID, extendedFunctionKeysID]

    /// - Parameter showExtendedFunctionKeys: whether F13–F24 starts visible —
    ///   seeded from the retired `virtualPadExtendedFKeys` toggle on upgrade.
    public static func all(showExtendedFunctionKeys: Bool = false, modified: Date = Pad.neverEdited) -> [Pad] {
        [
            pad(navigationID, "Navigation", [
                [(VK.home, 1), (VK.up, 1), (VK.prior, 1)],
                [(VK.left, 1), (VK.return, 1), (VK.right, 1)],
                [(VK.end, 1), (VK.down, 1), (VK.next, 1)],
            ], modified: modified),
            // The old Editing page ended in two half-width keys; on a grid the
            // nearest shape is Menu plus a double-width Enter, which keeps Enter
            // the biggest target on the pad.
            pad(editingID, "Editing", [
                [(VK.escape, 1), (VK.tab, 1), (VK.insert, 1)],
                [(VK.back, 1), (VK.space, 1), (VK.delete, 1)],
                [(VK.apps, 1), (VK.return, 2)],
            ], modified: modified),
            pad(functionKeysID, "Function keys", fRows(1), modified: modified),
            pad(extendedFunctionKeysID, "Extended function keys", fRows(13),
                visible: showExtendedFunctionKeys, modified: modified),
        ]
    }

    /// The two modifier rows every default ends with, in catalog order.
    private static var modifierRows: [[(UInt16, Int)]] {
        let vks = KeyCatalog.modifiers.map(\.vk)
        return [Array(vks[0..<3]), Array(vks[3..<6])].map { $0.map { ($0, 1) } }
    }

    private static func fRows(_ first: Int) -> [[(UInt16, Int)]] {
        stride(from: 0, to: 12, by: 3).map { offset in
            (0..<3).map { (VK.f1 + UInt16(first - 1 + offset + $0), 1) }
        }
    }

    private static func pad(
        _ id: UUID,
        _ title: String,
        _ upper: [[(UInt16, Int)]],
        visible: Bool = true,
        modified: Date
    ) -> Pad {
        let layout = upper + modifierRows
        var placed: [PlacedKey] = []
        for (row, entries) in layout.enumerated() {
            var column = 0
            for (vk, span) in entries {
                placed.append(PlacedKey(key: PadKey(vk: vk), row: row, column: column, columnSpan: span))
                column += span
            }
        }
        return Pad(id: id, title: title, rows: layout.count, columns: 3,
                   isVisible: visible, keys: placed, modified: modified)
    }
}
