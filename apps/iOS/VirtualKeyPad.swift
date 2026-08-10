import SwiftUI
import UIKit
import BridgeCore

/// The direct-touch key pad: VoiceOver's slow gesture round-trip removed from
/// the send path entirely. The pad is ONE accessibility element — the rest of
/// the tab stays ordinary VoiceOver territory, so explore by touch and
/// flicking between elements keep working. Inside the pad's frame, touches
/// pass straight through to the app with no activation step (instant
/// direct interaction, piano-app style — field-chosen over
/// `.requiresActivation`).
///
/// Two **arrangements** (`virtualPadLayout`), picked by the pad's own shape:
///
/// - **Key bands** — modifiers, editing, navigation, F1–F12, optionally
///   F13–F24, each band a row of equal cells. The portrait layout: a tall
///   narrow rectangle can hold nothing denser.
/// - **Keyboard** — a real PC key block, letters and all
///   (`VirtualKeys.keyboardRows`). Used once the pad is wider than tall,
///   because that rectangle is close to a physical keyboard's proportions and
///   the resulting keys come out bigger than iOS's own landscape keyboard.
///   The point is not looks: it replaces "third band, fifth key" with a
///   layout the user's hands already know, and the screen edges become the
///   landmarks (left edge going up really is Shift / Caps / Tab / Esc).
///
/// Two gesture models, chosen in Settings (`virtualPadSliderMode`), and both
/// work with either arrangement:
///
/// - **Grid (default, touch-typing model):** drag to hear the key under the
///   finger (interrupting announcement + a tick per boundary), lift on a key
///   to send it immediately, lift on a modifier to toggle it. Same grammar as
///   VoiceOver's touch typing, and fixed positions build muscle memory.
///   An extra finger landing mid-drag aborts the drag, so nothing fires.
/// - **Sliders (fallback):** one-finger swipe left/right moves between
///   rows, swipe up steps forward / down steps back (0 = "None"), tap
///   sends the row's current key; modifiers tap-toggle. Two-finger swipe left
///   resets the current row; hitting either end answers with a harder haptic.
///
/// **Press and hold works in both models** (`virtualPadHoldEnabled`), and is
/// what makes a one-finger pad able to express more than "tap = send":
///
/// 1. Touch down starts the countdown for the key under the finger (moving to
///    another zone restarts it for that one).
/// 2. After `virtualPadLatchDelay` the key **latches on** — from then on it
///    wraps everything sent, exactly like a modifier does, until it is pressed
///    again or the selection is cleared. Soft haptic, optional speech.
/// 3. After `virtualPadHoldDelay` more it is **pressed down on the PC** and
///    stays down while the finger stays down, so the PC's own key repeat runs
///    (hold Backspace to eat a word, hold Down to scroll). Firm haptic.
/// 4. Lifting from that state releases the key on the PC *and* drops the latch
///    (field decision 2026-08-10): a hold is momentary all the way through, so
///    it never leaves state behind. Lifting at stage 2 leaves the key latched.
///
/// Both modes: two-finger tap clears the whole selection. Success is
/// silent (plus a light haptic); failures speak via the shared send path.
/// Keys always send wrapped in whatever is latched.
///
/// **One zone, one vibration** — and with `virtualPadRichHaptics` on, how
/// hard it is *is* the key's state: light tick = off, firmer knock = turned
/// on, hard knock = down on the PC. Encoding state as extra pulses was tried
/// first and field-rejected (2026-08-10): pulses have to be counted and told
/// apart, a single harder one is read instantly.
struct VirtualKeyPad: UIViewRepresentable {
    let settings: AppSettings
    /// Snapshot of the tab's latched keys (modifier toggles and anything
    /// latched by holding) — owned by the tab so Send's hint stays honest.
    let latchedKeys: Set<UInt16>
    /// Latch a key on or off. Explicit rather than a toggle: the hold stages
    /// know the state they want, and a toggle would race the SwiftUI update.
    let onSetLatched: (VirtualKey, Bool) -> Void
    let onClearLatched: () -> Void
    let onSend: (VirtualKey) -> Void
    /// Press the key down on the PC and keep it down. Returns false when the
    /// connection can't carry it (the tab announces why), and the pad then
    /// stays at the latched stage instead of pretending the key is down.
    let onHoldBegin: (VirtualKey) -> Bool
    /// Release a key put down by `onHoldBegin`.
    let onHoldEnd: (VirtualKey) -> Void
    /// Reports which arrangement is on screen (true = the keyboard), so the
    /// tab's layout button can name the one the user is actually touching.
    /// The pad decides this from its own bounds, so it is the only place that
    /// knows.
    let onLayoutChange: (Bool) -> Void

    func makeUIView(context: Context) -> KeyPadUIView {
        let view = KeyPadUIView()
        configure(view)
        return view
    }

    func updateUIView(_ view: KeyPadUIView, context: Context) {
        configure(view)
    }

    /// Fill whatever the tab gives us. Without this the representable is sized
    /// from `intrinsicContentSize` and *centred* inside the frame instead —
    /// which is why a landscape pad ended up a fixed-height strip floating in
    /// the middle of the screen rather than the full-bleed pad the tab asks
    /// for. Zones are aimed at by feel, so every point counts.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: KeyPadUIView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    private func configure(_ view: KeyPadUIView) {
        view.layoutPreference = settings.virtualPadLayout
        view.pcLayout = settings.pcKeyboardLayout
        view.extendedFKeys = settings.virtualPadExtendedFKeys
        view.sliderMode = settings.virtualPadSliderMode
        view.holdEnabled = settings.virtualPadHoldEnabled
        view.latchDelay = settings.virtualPadLatchDelay
        view.holdDelay = settings.virtualPadHoldDelay
        view.speaksHoldStages = settings.virtualPadHoldSpeech
        view.richHaptics = settings.virtualPadRichHaptics
        view.latchedKeys = latchedKeys
        view.onSetLatched = onSetLatched
        view.onClearLatched = onClearLatched
        view.onSend = onSend
        view.onHoldBegin = onHoldBegin
        view.onHoldEnd = onHoldEnd
        view.onEffectiveLayoutChange = onLayoutChange
    }
}

/// One key on the pad, with the width it takes in its row.
///
/// Widths are in grid units, not points: every row of a layout sums to the
/// same number of units, so a 2-unit Backspace stays twice a letter's width at
/// any screen size and keys line up between rows.
struct PadKey: Equatable {
    let key: VirtualKey
    let units: Double

    init(key: VirtualKey, units: Double = 1) {
        self.key = key
        self.units = units
    }

    /// Lifting on it toggles instead of sending. A property of the key, not of
    /// the row: the keyboard layout scatters Shift/Ctrl/Alt/Win/Caps across
    /// three different rows.
    var isModifier: Bool { VirtualKeys.modifierVKs.contains(key.vk) }
}

/// One horizontal row of pad zones.
struct PadRow: Equatable {
    let title: String
    let keys: [PadKey]
    /// Every key in the row is a modifier — true only for the bands layout's
    /// modifier band. Slider mode reads it to decide whether the row needs a
    /// leading "None" slot (a row of toggles has no single selection).
    let isModifierRow: Bool

    init(title: String, keys: [PadKey], isModifierRow: Bool = false) {
        self.title = title
        self.keys = keys
        self.isModifierRow = isModifierRow
    }
}

/// A zone address on the pad.
private struct PadZone: Equatable {
    let row: Int
    let key: Int
}

final class KeyPadUIView: UIView {
    var onSetLatched: ((VirtualKey, Bool) -> Void)?
    var onClearLatched: (() -> Void)?
    var onSend: ((VirtualKey) -> Void)?
    var onHoldBegin: ((VirtualKey) -> Bool)?
    var onHoldEnd: ((VirtualKey) -> Void)?
    var onEffectiveLayoutChange: ((Bool) -> Void)?

    var layoutPreference: VirtualPadLayout = .keyboardInLandscape {
        didSet { rowsInvalidated(oldValue != layoutPreference) }
    }

    var pcLayout: PCKeyboardLayout = .us {
        didSet { rowsInvalidated(oldValue != pcLayout) }
    }

    var extendedFKeys = false {
        didSet { rowsInvalidated(oldValue != extendedFKeys) }
    }

    var sliderMode = false {
        didSet {
            guard oldValue != sliderMode else { return }
            abortPress()
            for recognizer in sliderRecognizers { recognizer.isEnabled = sliderMode }
            updateAccessibilityHint()
        }
    }

    var holdEnabled = true {
        didSet {
            guard oldValue != holdEnabled else { return }
            if !holdEnabled { abortPress() }
            updateAccessibilityHint()
        }
    }

    var latchDelay: TimeInterval = 0.6
    var holdDelay: TimeInterval = 0.6
    var speaksHoldStages = true
    var richHaptics = true

    var latchedKeys: Set<UInt16> = [] {
        didSet {
            guard oldValue != latchedKeys else { return }
            refreshLabels()
        }
    }

    private var rows: [PadRow] = []
    private var labels: [[UILabel]] = []
    /// Whether `rows` currently holds the keyboard arrangement, so a rotation
    /// that flips the answer is noticed in `layoutSubviews`.
    private var rowsAreKeyboard: Bool?
    private var rowsNeedRebuild = true
    /// The size the zones were last computed for: a change means the finger is
    /// no longer over what it thought it was.
    private var lastLaidOutSize: CGSize?

    private let selectionTick = UISelectionFeedbackGenerator()
    private let sendThump = UIImpactFeedbackGenerator(style: .light)
    /// Noticeably harder than the selection tick: felt when a swipe tries to
    /// step past the first/last position — the non-visual "end of the row" —
    /// and when a key goes down on the PC.
    private let edgeThump = UIImpactFeedbackGenerator(style: .rigid)
    /// The soft swell that marks a held key latching on.
    private let latchThump = UIImpactFeedbackGenerator(style: .soft)
    /// The arrival knock for a key that is turned on: it *replaces* the
    /// selection tick rather than following it, so the ladder a dragging
    /// finger feels is one pulse getting harder — tick, knock, hard knock.
    private let stateThump = UIImpactFeedbackGenerator(style: .medium)

    // Grid mode: the single tracked finger and the zone it is over.
    private var trackedTouch: UITouch?
    private var trackedZone: PadZone?

    // Slider mode: which row is current, and each row's position
    // (key rows: 0 = "None", i = keys[i - 1]; modifier row: browse index).
    private var currentRow = 0
    private var rowPositions: [Int] = []
    /// Where the slider-mode finger landed, so a swipe (rather than a hold)
    /// can be told apart and call the countdown off.
    private var sliderTouchOrigin: CGPoint = .zero
    /// A press that reached the latch stage must not *also* fire the slider
    /// tap recognizer's send on lift. Cleared when the next press starts.
    private var suppressSliderTap = false

    private var sliderRecognizers: [UIGestureRecognizer] = []

    // MARK: Press state (both modes)

    /// How far the current press has got. `spent` is a press that has already
    /// done its work (or been called off) — its lift must do nothing.
    private enum PressStage {
        case pressing, latched, held, spent
    }

    private var pressStage: PressStage = .spent
    private var pressKey: PadKey?
    private var latchTimer: Timer?
    private var holdTimer: Timer?
    /// The key currently down on the PC, for the label highlight.
    private var heldVK: UInt16?
    /// Whether the hold actually reached the PC. A refused one still counts
    /// as the stage being reached (so the latch drops), but there is nothing
    /// to release and nothing to announce as released.
    private var holdIsLive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        isMultipleTouchEnabled = true

        isAccessibilityElement = true
        accessibilityLabel = "Key pad"
        // Instant pass-through (field-requested, 2026-07-19): touching the
        // pad is direct interaction immediately — no activation step, the
        // classic piano-app behavior. `.requiresActivation` was tried first
        // and rejected as an extra hop. silentOnTouch keeps VoiceOver quiet
        // so the pad's own announcements are the only voice. The trade:
        // exploring by touch ACROSS the pad interacts with it — acceptable
        // because the pad is pinned at the top, outside casual explore
        // paths, and a drag without a lift on a key sends nothing.
        accessibilityTraits = .allowsDirectInteraction
        accessibilityDirectTouchOptions = [.silentOnTouch]
        updateAccessibilityHint()

        // Key borders are CGColors, which are resolved once and don't follow
        // light/dark mode on their own — without this the outlines stay the
        // old mode's colour until the pad is rebuilt.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyPadUIView, _) in
            view.updateBorderColors()
        }

        // Both modes: two-finger tap clears the whole selection.
        let clearTap = UITapGestureRecognizer(target: self, action: #selector(handleClearTap))
        clearTap.numberOfTouchesRequired = 2
        addGestureRecognizer(clearTap)

        // Slider mode only; disabled while the grid handles raw touches.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSliderTap))
        tap.numberOfTouchesRequired = 1
        let resetSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleRowReset))
        resetSwipe.direction = .left
        resetSwipe.numberOfTouchesRequired = 2
        var swipes: [UIGestureRecognizer] = [tap, resetSwipe]
        let directions: [(UISwipeGestureRecognizer.Direction, Selector)] = [
            (.left, #selector(handleSwipeLeft)),
            (.right, #selector(handleSwipeRight)),
            (.up, #selector(handleSwipeUp)),
            (.down, #selector(handleSwipeDown)),
        ]
        for (direction, selector) in directions {
            let swipe = UISwipeGestureRecognizer(target: self, action: selector)
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 1
            swipes.append(swipe)
        }
        for recognizer in swipes {
            recognizer.isEnabled = false
            // The hold machine runs off raw touches even in slider mode, and
            // it needs the touch to END rather than be cancelled out from
            // under it when one of these recognizes — otherwise a key held
            // down on the PC could be released late, or not at all.
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }
        sliderRecognizers = swipes
    }

    private func updateAccessibilityHint() {
        var hint = sliderMode
            ? "Touches here work directly. Swipe left or right to choose a row, up to move forward through its keys, down to move back, and tap once to send. Two-finger swipe left resets the row, two-finger tap clears the selection."
            : "Touches here work directly. Drag to hear the keys and lift on one to send it right away. Lifting on a modifier turns it on or off. Two-finger tap clears the selection."
        if holdEnabled {
            hint += " Hold a key to turn it on like a modifier, keep holding to press it down on the PC, and lift to release it."
        }
        accessibilityHint = hint
    }

    /// A pad taken out of the window (tab switched away, sheet covering it)
    /// must not leave a key down on the PC.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { abortPress() }
    }

    // MARK: Rows & visible labels (touch-user convenience; VoiceOver only
    // ever sees the pad as one element)

    private func rowsInvalidated(_ changed: Bool) {
        guard changed else { return }
        rowsNeedRebuild = true
        setNeedsLayout()
    }

    /// Which arrangement this rectangle can hold. The pad's own aspect ratio
    /// decides it, not the size class: an iPad in landscape and an iPad in a
    /// wide Split View slot are both "regular" but only one is keyboard
    /// shaped, and the shape is what actually determines whether a 15-unit row
    /// gives keys a usable width.
    private var wantsKeyboardLayout: Bool {
        switch layoutPreference {
        case .bands: return false
        case .keyboardAlways: return true
        case .keyboardInLandscape: return bounds.width > bounds.height * 1.2
        }
    }

    /// The bands arrangement: one row per group, equal cells throughout.
    private func bandRows() -> [PadRow] {
        var result = [PadRow(
            title: "Modifiers",
            keys: VirtualKeys.modifiers.map { PadKey(key: $0) },
            isModifierRow: true
        )]
        result += VirtualKeys.categories.map { category in
            PadRow(title: category.title, keys: category.keys.map { PadKey(key: $0) })
        }
        if extendedFKeys {
            result.append(PadRow(
                title: "Extended function keys",
                keys: VirtualKeys.extendedFunctionKeys.map { PadKey(key: $0) }
            ))
        }
        return result
    }

    /// Rebuild the rows when the settings or the pad's shape call for a
    /// different arrangement. Called from `layoutSubviews`, so it must not ask
    /// for another layout pass — the caller positions the new labels itself.
    private func applyRowsIfNeeded() {
        let wantsKeyboard = wantsKeyboardLayout
        guard rowsNeedRebuild || wantsKeyboard != rowsAreKeyboard else { return }
        let wasKeyboard = rowsAreKeyboard
        rowsNeedRebuild = false
        rowsAreKeyboard = wantsKeyboard
        setRows(wantsKeyboard
            ? VirtualKeys.keyboardRows(layout: pcLayout, includeExtendedFKeys: extendedFKeys)
            : bandRows())
        guard wasKeyboard != wantsKeyboard else { return }
        // Hopped out of the layout pass: this ends in a SwiftUI @State write,
        // which must not happen while the view tree is being laid out.
        let report = onEffectiveLayoutChange
        DispatchQueue.main.async { report?(wantsKeyboard) }
    }

    private func setRows(_ newRows: [PadRow]) {
        guard newRows != rows else { return }
        abortPress()
        rows = newRows
        currentRow = 0
        rowPositions = Array(repeating: 0, count: rows.count)

        for label in labels.flatMap({ $0 }) { label.removeFromSuperview() }
        labels = rows.map { row in
            row.keys.map { padKey in
                let label = UILabel()
                label.text = padKey.key.name
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.5
                label.textAlignment = .center
                label.layer.cornerRadius = 6
                label.layer.borderWidth = 1
                label.layer.borderColor = UIColor.separator
                    .resolvedColor(with: traitCollection).cgColor
                label.layer.masksToBounds = true
                label.isAccessibilityElement = false
                addSubview(label)
                return label
            }
        }
        invalidateIntrinsicContentSize()
    }

    /// Three visibly distinct key states, in *every* row — holding can turn an
    /// F-key on just as well as a modifier. A **filled background** is the
    /// primary cue (field-requested 2026-08-10): tinted text alone was too
    /// quiet to find at a glance on a pad this dense. Off is a plain key fill,
    /// on is a light tint wash, down-on-the-PC is the same hue at full
    /// strength, so the two live states can't be mistaken for each other.
    private func refreshLabels() {
        for (rowIndex, row) in rows.enumerated() {
            for (keyIndex, padKey) in row.keys.enumerated() {
                guard rowIndex < labels.count, keyIndex < labels[rowIndex].count else { continue }
                let label = labels[rowIndex][keyIndex]
                let down = padKey.key.vk == heldVK
                let on = latchedKeys.contains(padKey.key.vk)
                label.backgroundColor = down
                    ? tintColor.withAlphaComponent(0.45)
                    : (on ? tintColor.withAlphaComponent(0.2) : .tertiarySystemFill)
                // Dark text on the strong fill, tinted text on the light one:
                // tint-on-tint at 45% would be the one unreadable combination.
                label.textColor = on && !down ? tintColor : .label
                label.font = .systemFont(
                    ofSize: labelPointSize,
                    weight: on || down ? .semibold : .regular
                )
            }
        }
    }

    private func updateBorderColors() {
        let border = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        for label in labels.flatMap({ $0 }) { label.layer.borderColor = border }
    }

    /// Text sized from the zones themselves. The keyboard layout's rows are a
    /// third the height of a band, and a fixed caption size looked either lost
    /// or clipped depending on the arrangement.
    private var labelPointSize: CGFloat {
        guard !rows.isEmpty, bounds.height > 0 else { return 11 }
        let rowHeight = bounds.height / CGFloat(rows.count)
        return min(max(rowHeight * 0.36, 9), 20)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(max(rows.count, 1)) * 56)
    }

    /// Gap between key rectangles, so the pad reads as keys rather than as a
    /// wireframe grid. Purely cosmetic — hit testing uses the full cell, so
    /// no touch can land "between" two keys.
    private static let keyGap: CGFloat = 2

    override func layoutSubviews() {
        super.layoutSubviews()
        // A resize (rotation, the on-screen keyboard, an iPad window drag)
        // moves every zone out from under the finger: end the press, which
        // also releases anything this pad is holding down on the PC.
        if let lastLaidOutSize, lastLaidOutSize != bounds.size { abortPress() }
        lastLaidOutSize = bounds.size

        applyRowsIfNeeded()
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let rowHeight = bounds.height / CGFloat(rows.count)
        let gap = Self.keyGap
        for (rowIndex, row) in rows.enumerated() {
            let totalUnits = row.keys.reduce(0) { $0 + $1.units }
            guard totalUnits > 0 else { continue }
            var x: CGFloat = 0
            for (keyIndex, padKey) in row.keys.enumerated() {
                let width = bounds.width * CGFloat(padKey.units / totalUnits)
                labels[rowIndex][keyIndex].frame = CGRect(
                    x: x + gap / 2,
                    y: CGFloat(rowIndex) * rowHeight + gap / 2,
                    width: max(width - gap, 1),
                    height: max(rowHeight - gap, 1)
                )
                x += width
            }
        }
        refreshLabels()
    }

    // MARK: Shared helpers

    private func zone(at point: CGPoint) -> PadZone? {
        guard !rows.isEmpty, bounds.contains(point) else { return nil }
        let rowHeight = bounds.height / CGFloat(rows.count)
        let rowIndex = min(max(Int(point.y / rowHeight), 0), rows.count - 1)
        let keys = rows[rowIndex].keys
        guard !keys.isEmpty else { return nil }
        // Walk the row's cumulative widths: unlike the bands layout, keys in a
        // keyboard row are not all the same width.
        let totalUnits = keys.reduce(0) { $0 + $1.units }
        guard totalUnits > 0 else { return nil }
        let unitsAcross = Double(point.x / bounds.width) * totalUnits
        var consumed = 0.0
        for (index, padKey) in keys.enumerated() {
            consumed += padKey.units
            if unitsAcross < consumed { return PadZone(row: rowIndex, key: index) }
        }
        return PadZone(row: rowIndex, key: keys.count - 1)
    }

    /// Interrupting on purpose: while dragging, the newest key name must win
    /// immediately — queueing here would narrate history.
    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Speech for the hold stages only, so turning the cues off leaves the
    /// haptics as the channel and the pad otherwise as talkative as before.
    private func announceStage(_ message: String) {
        guard speaksHoldStages else { return }
        announce(message)
    }

    private func description(of padKey: PadKey) -> String {
        let name = padKey.key.spokenName
        if latchedKeys.contains(padKey.key.vk) { return "\(name), on" }
        return padKey.isModifier ? "\(name), off" : name
    }

    /// The vibration for arriving on a key — **always exactly one**, and with
    /// rich haptics on, its *strength* is the key's state. Dragging over 60
    /// keys, the finger learns which ones are on without waiting for a word.
    ///
    /// - key off: the ordinary selection tick
    /// - key on: a firmer single knock
    /// - key down on the PC: a hard single knock
    ///
    /// Earlier versions added a *second* pulse for the state and a third for
    /// crossing into another row. Field-rejected as unintuitive (2026-08-10):
    /// several pulses per key have to be counted and told apart, while one
    /// pulse that is simply harder is read instantly and needs no learning.
    /// So there is no row cue at all now — one zone, one vibration.
    private func feedbackEntering(_ padKey: PadKey) {
        guard richHaptics else {
            selectionTick.selectionChanged()
            return
        }
        if padKey.key.vk == heldVK {
            edgeThump.impactOccurred()
        } else if latchedKeys.contains(padKey.key.vk) {
            stateThump.impactOccurred()
        } else {
            selectionTick.selectionChanged()
        }
    }

    /// Latch a key on/off through the parent. The local set is updated
    /// optimistically so a continuing drag reads the right state before
    /// SwiftUI's update pass comes around.
    private func setLatched(_ key: VirtualKey, _ on: Bool) {
        guard latchedKeys.contains(key.vk) != on else { return }
        if on { latchedKeys.insert(key.vk) } else { latchedKeys.remove(key.vk) }
        onSetLatched?(key, on)
    }

    private func send(_ key: VirtualKey) {
        sendThump.impactOccurred()
        onSend?(key)
    }

    @objc private func handleClearTap() {
        onClearLatched?()
        latchedKeys.removeAll()
        selectionTick.selectionChanged()
        announce("Selection cleared")
    }

    // MARK: Press & hold state machine

    /// Start (or restart) the countdown for `padKey`. Any key still down on
    /// the PC from the previous zone is released first — sliding off a held
    /// key ends its hold exactly like lifting does.
    private func startPress(on padKey: PadKey) {
        endHoldIfNeeded()
        cancelStageTimers()
        pressKey = padKey
        pressStage = .pressing
        guard holdEnabled else { return }
        latchTimer = scheduleStage(after: latchDelay) { [weak self] in self?.latchStageFired() }
    }

    private func latchStageFired() {
        guard pressStage == .pressing, let padKey = pressKey else { return }
        pressStage = .latched
        suppressSliderTap = true
        setLatched(padKey.key, true)
        latchThump.impactOccurred()
        announceStage("\(padKey.key.spokenName) on")
        holdTimer = scheduleStage(after: holdDelay) { [weak self] in self?.holdStageFired() }
    }

    private func holdStageFired() {
        guard pressStage == .latched, let padKey = pressKey else { return }
        pressStage = .held
        // Passing this stage ends the "on" state there and then — being down
        // on the PC replaces it, it doesn't come on top of it. That has to
        // happen even when the press is refused below (forwarding off, not
        // connected): a key that announced itself as held must never still be
        // sitting there turned on afterwards (field-reported 2026-08-10).
        setLatched(padKey.key, false)
        holdIsLive = onHoldBegin?(padKey.key) == true
        if holdIsLive { heldVK = padKey.key.vk }
        refreshLabels()
        edgeThump.impactOccurred()
        // A refused hold said why through the tab; don't claim it went down.
        if holdIsLive { announceStage("\(padKey.key.spokenName) held down") }
    }

    /// Release a key this press put down on the PC. The latch is already gone
    /// (dropped when the hold stage was reached), so a hold is momentary from
    /// end to end and leaves nothing selected.
    private func endHoldIfNeeded() {
        guard pressStage == .held, let padKey = pressKey else { return }
        pressStage = .spent
        let wasLive = holdIsLive
        holdIsLive = false
        heldVK = nil
        if wasLive { onHoldEnd?(padKey.key) }
        setLatched(padKey.key, false)
        refreshLabels()
        sendThump.impactOccurred()
        if wasLive { announceStage("\(padKey.key.spokenName) released") }
    }

    /// A press that ended before the latch stage: the pad's original grammar —
    /// modifiers toggle, other keys send. Pressing an already-latched key is
    /// how you let it go again, wherever it sits.
    private func shortPress(_ padKey: PadKey) {
        let key = padKey.key
        if latchedKeys.contains(key.vk) {
            setLatched(key, false)
            selectionTick.selectionChanged()
            announce("\(key.spokenName) off")
        } else if padKey.isModifier {
            setLatched(key, true)
            selectionTick.selectionChanged()
            announce("\(key.spokenName) on")
        } else {
            send(key)
        }
    }

    /// Called off, not lifted: release anything held and make the eventual
    /// lift a no-op.
    private func abortPress() {
        endHoldIfNeeded()
        cancelStageTimers()
        pressStage = .spent
        pressKey = nil
        trackedTouch = nil
        trackedZone = nil
    }

    private func cancelStageTimers() {
        latchTimer?.invalidate()
        latchTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
    }


    /// `.common` mode so the countdown keeps running through anything that
    /// puts the run loop into a tracking mode while the finger is down.
    private func scheduleStage(after delay: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Grid mode — raw touch tracking (direct touch delivers touches
    // straight here; this is where the latency win comes from)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let isFirstFinger = trackedTouch == nil && touches.count == 1 && event?.allTouches?.count == 1
        guard isFirstFinger, let touch = touches.first else {
            // A second finger joined (e.g. the start of a two-finger tap):
            // the press is over, and the eventual lift must not act.
            abortPress()
            return
        }
        // Warming the Taptic Engine here is what keeps the first tick of a
        // drag as prompt as the rest — on a keyboard layout a drag crosses
        // zones immediately, so a cold first boundary is very noticeable.
        selectionTick.prepare()
        latchThump.prepare()
        edgeThump.prepare()
        stateThump.prepare()
        trackedTouch = touch
        suppressSliderTap = false
        if sliderMode {
            sliderTouchOrigin = touch.location(in: self)
            beginSliderPress()
        } else {
            updateTrackedZone(with: touch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if sliderMode {
            // Slider mode has no zones: a finger that travels is swiping, not
            // holding, so the countdown (and any hold) is called off.
            let point = touch.location(in: self)
            let travel = hypot(point.x - sliderTouchOrigin.x, point.y - sliderTouchOrigin.y)
            if travel > Self.sliderHoldSlop, pressStage != .spent {
                endHoldIfNeeded()
                cancelStageTimers()
                pressStage = .spent
            }
        } else {
            updateTrackedZone(with: touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        // Catch a lift that landed in a zone the move events never reported.
        if !sliderMode { updateTrackedZone(with: touch) }
        cancelStageTimers()

        switch pressStage {
        case .held:
            endHoldIfNeeded()
        case .pressing:
            // In slider mode the tap recognizer owns the short press, so the
            // send doesn't happen twice.
            if !sliderMode, let padKey = pressKey {
                shortPress(padKey)
            }
        case .latched, .spent:
            // Latched: the stage itself already did the work and said so.
            break
        }

        pressStage = .spent
        pressKey = nil
        trackedTouch = nil
        trackedZone = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        abortPress()
    }

    private func updateTrackedZone(with touch: UITouch) {
        let newZone = zone(at: touch.location(in: self))
        guard newZone != trackedZone else { return }
        trackedZone = newZone
        guard let newZone else {
            // The finger left the pad: end any hold and stop the countdown, so
            // lifting outside sends nothing.
            endHoldIfNeeded()
            cancelStageTimers()
            pressStage = .spent
            pressKey = nil
            return
        }
        let padKey = rows[newZone.row].keys[newZone.key]
        feedbackEntering(padKey)
        announce(description(of: padKey))
        startPress(on: padKey)
    }

    /// How far a slider-mode finger may drift and still count as a hold.
    private static let sliderHoldSlop: CGFloat = 12

    // MARK: Slider mode — recognizer driven

    /// The key the current row points at, or nil on a key row's "None".
    private var sliderKey: PadKey? {
        guard !rows.isEmpty else { return nil }
        let row = rows[currentRow]
        let position = rowPositions[currentRow]
        if row.isModifierRow { return row.keys[position] }
        return position == 0 ? nil : row.keys[position - 1]
    }

    private func beginSliderPress() {
        guard let padKey = sliderKey else {
            pressStage = .spent
            pressKey = nil
            return
        }
        startPress(on: padKey)
    }

    private func moveRow(by delta: Int) {
        guard !rows.isEmpty else { return }
        let target = min(max(currentRow + delta, 0), rows.count - 1)
        guard target != currentRow else {
            edgeThump.impactOccurred()
            return
        }
        currentRow = target
        selectionTick.selectionChanged()
        announce("\(rows[currentRow].title): \(currentPositionDescription())")
    }

    private func currentPositionDescription() -> String {
        guard !rows.isEmpty else { return "None" }
        let row = rows[currentRow]
        let position = rowPositions[currentRow]
        if row.isModifierRow { return description(of: row.keys[position]) }
        return position == 0 ? "None" : description(of: row.keys[position - 1])
    }

    private func stepPosition(by delta: Int) {
        guard !rows.isEmpty else { return }
        let row = rows[currentRow]
        // Key rows have a leading "None" slot; an all-modifier row browses
        // its keys directly (several can be on, so position can't be the
        // selection there).
        let count = row.isModifierRow ? row.keys.count : row.keys.count + 1
        let target = min(max(rowPositions[currentRow] + delta, 0), count - 1)
        guard target != rowPositions[currentRow] else {
            edgeThump.impactOccurred()
            return
        }
        rowPositions[currentRow] = target
        selectionTick.selectionChanged()
        announce(currentPositionDescription())
    }

    @objc private func handleSwipeRight() { moveRow(by: 1) }
    @objc private func handleSwipeLeft() { moveRow(by: -1) }
    // Swipe up = forward, down = back — the VoiceOver-adjustable convention.
    // (Flipped to down-forward on request 2026-07-19 and reverted the same
    // day; the user confirmed the request was a mistake. Keep the
    // convention.)
    @objc private func handleSwipeUp() { stepPosition(by: 1) }
    @objc private func handleSwipeDown() { stepPosition(by: -1) }

    @objc private func handleSliderTap() {
        // A press that latched (or went further) has already acted; the tap
        // recognizer must not send the same key on top of it.
        guard !suppressSliderTap else { return }
        guard let padKey = sliderKey else {
            announce("No key selected")
            return
        }
        shortPress(padKey)
    }

    @objc private func handleRowReset() {
        guard !rows.isEmpty else { return }
        if rows[currentRow].isModifierRow {
            handleClearTap()
        } else {
            rowPositions[currentRow] = 0
            selectionTick.selectionChanged()
            announce("\(rows[currentRow].title) reset")
        }
    }
}
