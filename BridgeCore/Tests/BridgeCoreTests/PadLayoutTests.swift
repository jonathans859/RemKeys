import XCTest
@testable import BridgeCore

final class PadLayoutTests: XCTestCase {
    private func key(_ vk: UInt16) -> PadKey { PadKey(vk: vk) }

    /// 3 × 2: [A][B][ ] / [  C  ][ ]
    private func sample() -> (Pad, a: UUID, b: UUID, c: UUID) {
        let a = key(VK.a), b = key(VK.b), c = key(VK.c)
        let pad = Pad(title: "T", rows: 2, columns: 3, keys: [
            PlacedKey(key: a, row: 0, column: 0),
            PlacedKey(key: b, row: 0, column: 1),
            PlacedKey(key: c, row: 1, column: 0, columnSpan: 2),
        ])
        return (pad, a.id, b.id, c.id)
    }

    func testLookupCoversSpans() {
        let (pad, _, _, c) = sample()
        XCTAssertEqual(pad.key(atRow: 1, column: 1)?.id, c)
        XCTAssertNil(pad.key(atRow: 0, column: 2))
        XCTAssertNil(pad.key(atRow: 1, column: 2))
    }

    func testInitDropsOverlappingAndOutOfBoundsKeys() {
        let pad = Pad(title: "T", rows: 1, columns: 2, keys: [
            PlacedKey(key: key(VK.a), row: 0, column: 0, columnSpan: 2),
            PlacedKey(key: key(VK.b), row: 0, column: 1),
            PlacedKey(key: key(VK.c), row: 3, column: 0),
        ])
        XCTAssertEqual(pad.keys.count, 1)
    }

    func testGridSizeIsClamped() {
        let pad = Pad(title: "T", rows: 20, columns: 0)
        XCTAssertEqual(pad.rows, Pad.rowRange.upperBound)
        XCTAssertEqual(pad.columns, Pad.columnRange.lowerBound)
    }

    func testMoveRightIntoGapAndSwap() {
        var (pad, a, b, _) = sample()
        XCTAssertNil(pad.move(a, .right))
        XCTAssertEqual(pad.placed(a)?.column, 1)
        XCTAssertEqual(pad.placed(b)?.column, 0)
        XCTAssertNil(pad.move(a, .right))
        XCTAssertEqual(pad.placed(a)?.column, 2)
        XCTAssertEqual(pad.move(a, .right), .edge)
    }

    func testMoveWideKeySwapsAround() {
        var (pad, _, _, c) = sample()
        pad.add(key(VK.d), row: 1, column: 2)
        let d = pad.key(atRow: 1, column: 2)!.id
        XCTAssertNil(pad.move(c, .right))
        XCTAssertEqual(pad.placed(c)?.column, 1)
        XCTAssertEqual(pad.placed(d)?.column, 0)
        XCTAssertNil(pad.move(c, .left))
        XCTAssertEqual(pad.placed(c)?.column, 0)
        XCTAssertEqual(pad.placed(d)?.column, 2)
    }

    func testMoveVerticalSwapsKeysInsideSpanAndRefusesWiderOnes() {
        var (pad, a, b, c) = sample()
        // C (two wide) moving up takes A and B down with it.
        XCTAssertNil(pad.move(c, .up))
        XCTAssertEqual(pad.placed(c)?.row, 0)
        XCTAssertEqual(pad.placed(a)?.row, 1)
        XCTAssertEqual(pad.placed(b)?.row, 1)
        // A (one wide) can't swap with C, which is wider.
        XCTAssertEqual(pad.move(a, .up), .blocked)
        XCTAssertEqual(pad.move(a, .down), .edge)
    }

    func testPlaceSwapsOrMovesIntoGap() {
        var (pad, a, _, c) = sample()
        XCTAssertNil(pad.place(a, atRow: 1, column: 2))
        XCTAssertEqual(pad.placed(a)?.row, 1)
        XCTAssertEqual(pad.placed(a)?.column, 2)
        // C onto B's cell: C is two wide and B's origin is column 1, so C would
        // cover 1–2 on row 0 and B goes to C's old origin.
        let b = pad.key(atRow: 0, column: 1)!.id
        XCTAssertNil(pad.place(c, atRow: 0, column: 1))
        XCTAssertEqual(pad.placed(c)?.columnRange, 1..<3)
        XCTAssertEqual(pad.placed(b)?.row, 1)
    }

    func testSpanGrowsRightThenLeft() {
        var (pad, _, b, _) = sample()
        XCTAssertEqual(pad.maxColumnSpan(of: b), 2)
        XCTAssertNil(pad.setSpan(b, to: 2))
        XCTAssertEqual(pad.placed(b)?.columnRange, 1..<3)
        XCTAssertEqual(pad.setSpan(b, to: 3), .noRoom)

        var pad2 = Pad(title: "T", rows: 1, columns: 3, keys: [
            PlacedKey(key: key(VK.a), row: 0, column: 2),
        ])
        let id = pad2.keys[0].id
        XCTAssertNil(pad2.setSpan(id, to: 3))
        XCTAssertEqual(pad2.placed(id)?.columnRange, 0..<3)
    }

    func testResizeCountsAndDropsLostKeysAndNarrowsCrossingOnes() {
        var (pad, _, _, c) = sample()
        XCTAssertEqual(pad.keysLost(rows: 1, columns: 3), 1)
        XCTAssertEqual(pad.keysLost(rows: 2, columns: 1), 1)
        pad.resize(rows: 2, columns: 1)
        XCTAssertEqual(pad.keys.count, 2)
        XCTAssertEqual(pad.placed(c)?.columnSpan, 1)
    }

    func testCodableRoundTripAndTolerance() throws {
        let (pad, _, _, _) = sample()
        let data = try JSONEncoder().encode(pad)
        XCTAssertEqual(try JSONDecoder().decode(Pad.self, from: data), pad)

        // An unknown colour falls back to Default instead of failing the pad.
        let json = #"{"id":"\#(UUID().uuidString)","title":"X","rows":1,"columns":1,"isVisible":true,"modified":0,"keys":[{"row":0,"column":0,"span":1,"key":{"id":"\#(UUID().uuidString)","vk":65,"modifiers":[],"color":"ultraviolet"}}]}"#
        let decoded = try JSONDecoder().decode(Pad.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.keys.first?.key.color, .standard)
    }

    func testKeyNamingAndToggling() {
        let combo = PadKey(vk: VK.c, modifiers: [VK.shift, VK.control])
        XCTAssertEqual(combo.label, "Ctrl+Shift+C")
        XCTAssertEqual(combo.spokenLabel, "Control + Shift + C")
        XCTAssertFalse(combo.togglesModifier)
        XCTAssertTrue(PadKey(vk: VK.capital).togglesModifier)
        XCTAssertFalse(PadKey(vk: VK.shift, modifiers: [VK.control]).togglesModifier)

        var named = combo
        named.customLabel = "  Copy all  "
        XCTAssertEqual(named.label, "Copy all")
        XCTAssertEqual(named.spokenLabel, "Copy all")
        named.customLabel = "   "
        XCTAssertEqual(named.label, "Ctrl+Shift+C")

        // Non-modifiers and the key itself are stripped from its modifiers.
        XCTAssertEqual(PadKey(vk: VK.shift, modifiers: [VK.shift, VK.a]).modifiers, [])
    }

    func testDefaultsMatchTheOldPagesWithModifierRows() {
        let pads = DefaultPads.all()
        XCTAssertEqual(pads.map(\.title), ["Navigation", "Editing", "Function keys", "Extended function keys"])
        XCTAssertEqual(pads.map(\.isVisible), [true, true, true, false])
        let nav = pads[0]
        XCTAssertEqual(nav.rows, 5)
        XCTAssertEqual(nav.key(atRow: 1, column: 1)?.key.vk, VK.return)
        XCTAssertEqual(nav.key(atRow: 3, column: 0)?.key.vk, VK.control)
        XCTAssertEqual(nav.key(atRow: 4, column: 2)?.key.vk, VK.capital)
        XCTAssertEqual(pads[1].key(atRow: 2, column: 2)?.key.vk, VK.return)
        XCTAssertEqual(pads[1].key(atRow: 2, column: 1)?.columnSpan, 2)
        XCTAssertEqual(pads[2].rows, 6)
        XCTAssertEqual(pads[3].key(atRow: 3, column: 2)?.key.vk, VK.f24)
        XCTAssertTrue(pads.allSatisfy { $0.modified == Pad.neverEdited })
    }

    func testEveryCatalogKeyHasAName() {
        for key in KeyCatalog.categories.flatMap(\.keys) {
            XCTAssertFalse(KeyCatalog.name(for: key.vk).hasPrefix("Key "), "\(key.vk)")
        }
        XCTAssertEqual(KeyCatalog.name(for: VK.f13), "F13")
        XCTAssertEqual(KeyCatalog.name(for: VK.z), "Z")
    }

    // MARK: Keys spanning rows

    /// 3 × 3 with a 1 × 2 tall key T in column 0, rows 0–1, and A at (0, 1).
    private func tall() -> (Pad, t: UUID, a: UUID) {
        let t = key(VK.t), a = key(VK.a)
        let pad = Pad(title: "T", rows: 3, columns: 3, keys: [
            PlacedKey(key: t, row: 0, column: 0, rowSpan: 2),
            PlacedKey(key: a, row: 0, column: 1),
        ])
        return (pad, t.id, a.id)
    }

    func testTallKeyCoversItsRows() {
        let (pad, t, _) = tall()
        XCTAssertEqual(pad.key(atRow: 1, column: 0)?.id, t)
        XCTAssertNil(pad.key(atRow: 2, column: 0))
        XCTAssertEqual(pad.maxRowSpan(of: t), 3)
        XCTAssertEqual(pad.maxColumnSpan(of: t), 1, "A blocks column 1 in row 0")
    }

    func testExtendAndShrinkFromEveryEdge() {
        var (pad, t, a) = tall()
        XCTAssertEqual(pad.extend(t, .up), .edge)
        XCTAssertEqual(pad.extend(t, .right), .noRoom, "A is in the way")
        XCTAssertNil(pad.extend(t, .down))
        XCTAssertEqual(pad.placed(t)?.rowRange, 0..<3)
        XCTAssertNil(pad.shrink(t, from: .up))
        XCTAssertEqual(pad.placed(t)?.rowRange, 1..<3)
        XCTAssertNil(pad.extend(t, .right))
        XCTAssertEqual(pad.placed(t)?.columnRange, 0..<2)
        XCTAssertNil(pad.shrink(t, from: .left))
        XCTAssertEqual(pad.placed(t)?.columnRange, 1..<2)
        XCTAssertNil(pad.extend(a, .left))
        XCTAssertEqual(pad.placed(a)?.columnRange, 0..<2)
        XCTAssertEqual(pad.shrink(a, from: .up), .noRoom, "one cell tall already")
    }

    func testTallKeyMovesSidewaysSwappingWithKeysInsideItsRows() {
        var (pad, t, a) = tall()
        // A is only in row 0 of T's two rows, so it fits inside: swap.
        XCTAssertNil(pad.move(t, .right))
        XCTAssertEqual(pad.placed(t)?.column, 1)
        XCTAssertEqual(pad.placed(a)?.column, 0)
        // A (one tall) can't move right into T, which is taller than A.
        XCTAssertEqual(pad.move(a, .right), .blocked)
        // T moves down into the free row.
        XCTAssertNil(pad.move(t, .down))
        XCTAssertEqual(pad.placed(t)?.rowRange, 1..<3)
        XCTAssertEqual(pad.move(t, .down), .edge)
    }

    func testMoveUpPastATallerKeyLinesItUpBehind() {
        // B is 1 × 2 tall at rows 0–1 of column 0; W (one cell) at row 2.
        let b = key(VK.b), w = key(VK.w)
        var pad = Pad(title: "T", rows: 3, columns: 1, keys: [
            PlacedKey(key: b, row: 0, column: 0, rowSpan: 2),
            PlacedKey(key: w, row: 2, column: 0),
        ])
        XCTAssertNil(pad.move(w.id, .up))
        XCTAssertEqual(pad.placed(w.id)?.row, 0)
        XCTAssertEqual(pad.placed(b.id)?.rowRange, 1..<3)
    }

    func testSetSizeShiftsUpAndLeftOnlyAsFarAsNeeded() {
        var pad = Pad(title: "T", rows: 3, columns: 3, keys: [
            PlacedKey(key: key(VK.a), row: 2, column: 2),
        ])
        let id = pad.keys[0].id
        XCTAssertNil(pad.setSize(id, columns: 2, rows: 3))
        XCTAssertEqual(pad.placed(id)?.rowRange, 0..<3)
        XCTAssertEqual(pad.placed(id)?.columnRange, 1..<3)
    }

    func testResizeTrimsRowSpan() {
        var (pad, t, _) = tall()
        pad.resize(rows: 1, columns: 3)
        XCTAssertEqual(pad.placed(t)?.rowSpan, 1)
    }

    func testOldRecordsWithoutRowSpanDecodeAsOneRowTall() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"X","rows":2,"columns":2,"isVisible":true,"modified":0,"keys":[{"row":0,"column":0,"span":2,"key":{"id":"\#(UUID().uuidString)","vk":65,"modifiers":[],"color":"red"}}]}"#
        let pad = try JSONDecoder().decode(Pad.self, from: Data(json.utf8))
        XCTAssertEqual(pad.keys.first?.columnSpan, 2)
        XCTAssertEqual(pad.keys.first?.rowSpan, 1)
        let (tallPad, _, _) = tall()
        XCTAssertEqual(try JSONDecoder().decode(Pad.self, from: JSONEncoder().encode(tallPad)), tallPad)
    }
}
