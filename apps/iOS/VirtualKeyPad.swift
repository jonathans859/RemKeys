import SwiftUI
import UIKit
import BridgeCore

/// The direct-touch key pad: VoiceOver's slow gesture round-trip removed from
/// the send path entirely. The pad is ONE accessibility element — the rest of
/// the tab stays ordinary VoiceOver territory, so explore by touch and
/// flicking between elements keep working. Inside the pad's frame, touches
/// pass straight through to the app with no activation step (instant direct
/// interaction, piano-app style — field-chosen over `.requiresActivation`).
///
/// **One shape, three zones wide, in every orientation** (rebuilt 2026-08-20).
/// The pad used to offer key bands, a full 60-key PC keyboard, and a rule for
/// choosing between them by screen aspect ratio. All of it went, because all
/// of it was in service of a surface whose zones were 23–29 pt across: too
/// narrow to aim at, so every key cost a search. See `VirtualKeys.columns` for
/// why the replacement is three wide and nothing else.
///
/// The layout is two blocks:
///
/// - **The page**, filling the top: 3 × 3 (or 3 × 4 for the function keys),
///   swapped by two-finger swipe left/right or from the tab's page control.
/// - **The modifier block**, the bottom two rows, which is the same six keys
///   at the same place forever — it does not move when the page changes, and
///   it is what the thumb finds coming up off the bottom edge of the phone.
///
/// Gestures, one set, no modes:
///
/// - Drag to hear the key under the finger (interrupting announcement plus a
///   tick per boundary); lift on a key to send it, lift on a modifier to
///   toggle it. Pressing a modifier that is on turns it off.
/// - **Press and hold** (`virtualPadHoldEnabled`): after
///   `virtualPadHoldDelay` the key is pressed *down* on the PC and stays down
///   until the finger lifts, so it repeats there — hold Backspace to eat a
///   word, hold Down to keep scrolling. The Windows agent generates that
///   repeat (`KeyRepeater`); Windows never repeats injected keys by itself.
///   There is no second "latch the key on" stage any more: latching is what
///   the modifier block is for, and every modifier now has a permanent zone.
/// - Two-finger tap clears every modifier that is on. An extra finger landing
///   mid-drag aborts the drag, so nothing fires.
///
/// State shows as a **filled key**: plain grey off, half-strength tint on,
/// solid tint down on the PC, with a thicker tinted border on both live
/// states so it never rests on hue alone.
///
/// **One zone, one vibration** — and with `virtualPadRichHaptics` on, how hard
/// it is *is* the key's state: light tick = off, firmer knock = turned on,
/// hard knock = down on the PC. Encoding state as extra pulses was tried first
/// and field-rejected (2026-08-10): pulses have to be counted and told apart,
/// a single harder one is read instantly.
struct VirtualKeyPad: UIViewRepresentable {
    let settings: AppSettings
    /// Which page the upper block shows. Owned by the tab, because the tab's
    /// toolbar control changes it too.
    let pageIndex: Int
    /// Snapshot of the tab's latched modifiers — owned by the tab so Send's
    /// hint stays honest.
    let latchedKeys: Set<UInt16>
    /// Move the page by ±1. The pad reports the gesture rather than owning the
    /// page, so the toolbar control and the swipe can't disagree.
    let onPageStep: (Int) -> Void
    /// Latch a key on or off. Explicit rather than a toggle: the pad knows the
    /// state it wants, and a toggle would race the SwiftUI update.
    let onSetLatched: (VirtualKey, Bool) -> Void
    let onClearLatched: () -> Void
    let onSend: (VirtualKey) -> Void
    /// Press the key down on the PC and keep it down. Returns false when the
    /// connection can't carry it (the tab announces why), and the press is
    /// then simply spent — nothing is left looking held.
    let onHoldBegin: (VirtualKey) -> Bool
    /// Release a key put down by `onHoldBegin`.
    let onHoldEnd: (VirtualKey) -> Void

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
    /// which once left the pad a fixed-height strip floating in the middle of
    /// the screen rather than the full-bleed pad the tab asks for. Zones are
    /// aimed at by feel, so every point counts.
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
        view.extendedFKeys = settings.virtualPadExtendedFKeys
        view.holdEnabled = settings.virtualPadHoldEnabled
        view.holdDelay = settings.virtualPadHoldDelay
        view.speaksHoldStages = settings.virtualPadHoldSpeech
        view.richHaptics = settings.virtualPadRichHaptics
        view.latchedKeys = latchedKeys
        view.onPageStep = onPageStep
        view.onSetLatched = onSetLatched
        view.onClearLatched = onClearLatched
        view.onSend = onSend
        view.onHoldBegin = onHoldBegin
        view.onHoldEnd = onHoldEnd
        // Last, so the announcement it makes describes a fully configured pad.
        view.pageIndex = pageIndex
    }
}

/// A zone address: which row of the whole pad (page rows first, then the
/// modifier block) and which column.
private struct PadZone: Equatable {
    let row: Int
    let column: Int
}

final class KeyPadUIView: UIView {
    var onPageStep: ((Int) -> Void)?
    var onSetLatched: ((VirtualKey, Bool) -> Void)?
    var onClearLatched: (() -> Void)?
    var onSend: ((VirtualKey) -> Void)?
    var onHoldBegin: ((VirtualKey) -> Bool)?
    var onHoldEnd: ((VirtualKey) -> Void)?

    var extendedFKeys = false {
        didSet {
            guard oldValue != extendedFKeys else { return }
            rebuildZones(announcePage: false)
        }
    }

    var pageIndex = 0 {
        didSet {
            guard oldValue != pageIndex else { return }
            let announce = pageChangeCameFromSwipe
            pageChangeCameFromSwipe = false
            rebuildZones(announcePage: announce)
        }
    }

    /// Set while a two-finger swipe is asking for the page change it is about
    /// to be handed back. The toolbar's page control is an adjustable element,
    /// so VoiceOver speaks its new value by itself — announcing here as well
    /// would be two voices for one change.
    private var pageChangeCameFromSwipe = false

    var holdEnabled = true {
        didSet {
            guard oldValue != holdEnabled else { return }
            if !holdEnabled { abortPress() }
            updateAccessibilityHint()
        }
    }

    var holdDelay: TimeInterval = 0.8
    var speaksHoldStages = true
    var richHaptics = true

    var latchedKeys: Set<UInt16> = [] {
        didSet {
            guard oldValue != latchedKeys else { return }
            refreshLabels()
        }
    }

    /// Every row on the pad: the current page's rows, then the modifier
    /// block's. Flattening the two blocks into one list keeps hit testing and
    /// label handling single-path; only the geometry knows about the split.
    private var rows: [[VirtualKey]] = []
    /// How many of `rows` belong to the page. The rest are the modifier block.
    private var pageRowCount = 0
    private var pages: [PadPage] = []
    private var labels: [[UILabel]] = []
    /// The size the zones were last computed for: a change means the finger is
    /// no longer over what it thought it was.
    private var lastLaidOutSize: CGSize?

    private let selectionTick = UISelectionFeedbackGenerator()
    private let sendThump = UIImpactFeedbackGenerator(style: .light)
    /// Noticeably harder than the selection tick: felt when a key goes down on
    /// the PC, and when a drag arrives on a key that is already down.
    private let edgeThump = UIImpactFeedbackGenerator(style: .rigid)
    /// The arrival knock for a key that is turned on: it *replaces* the
    /// selection tick rather than following it, so the ladder a dragging
    /// finger feels is one pulse getting harder — tick, knock, hard knock.
    private let stateThump = UIImpactFeedbackGenerator(style: .medium)

    /// The single tracked finger and the zone it is over.
    private var trackedTouch: UITouch?
    private var trackedZone: PadZone?

    // MARK: Press state

    /// How far the current press has got. `spent` is a press that has already
    /// done its work (or been called off) — its lift must do nothing.
    private enum PressStage {
        case pressing, held, spent
    }

    private var pressStage: PressStage = .spent
    private var pressKey: VirtualKey?
    private var holdTimer: Timer?
    /// The key currently down on the PC, for the label highlight.
    private var heldVK: UInt16?

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
        // so the pad's own announcements are the only voice.
        accessibilityTraits = .allowsDirectInteraction
        accessibilityDirectTouchOptions = [.silentOnTouch]
        updateAccessibilityHint()
        rebuildZones(announcePage: false)

        // Key borders are CGColors, which are resolved once and don't follow
        // light/dark mode on their own — without this the outlines stay the
        // old mode's colour until the pad is rebuilt.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyPadUIView, _) in
            view.updateBorderColors()
        }

        let clearTap = UITapGestureRecognizer(target: self, action: #selector(handleClearTap))
        clearTap.numberOfTouchesRequired = 2
        addGestureRecognizer(clearTap)

        // Paging. Two fingers, so a one-finger drag across the pad — which is
        // how every key is found — can never be mistaken for it.
        let paging: [(UISwipeGestureRecognizer.Direction, Selector)] = [
            (.left, #selector(handleNextPage)),
            (.right, #selector(handlePreviousPage)),
        ]
        for (direction, selector) in paging {
            let swipe = UISwipeGestureRecognizer(target: self, action: selector)
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            // The hold machine runs off raw touches; it needs the touch to END
            // rather than be cancelled out from under it when this recognizes,
            // or a key held down on the PC could be released late, or not at
            // all.
            swipe.cancelsTouchesInView = false
            addGestureRecognizer(swipe)
        }
    }

    private func updateAccessibilityHint() {
        var hint = "Touches here work directly. Drag to hear the keys and lift on one to send it right away. The bottom two rows are the modifiers; lifting on one turns it on or off. Two-finger swipe left or right changes the keys above them, two-finger tap clears the modifiers."
        if holdEnabled {
            hint += " Hold a key until it is pressed down on the PC, where it repeats until you lift."
        }
        accessibilityHint = hint
    }

    /// A pad taken out of the window (tab switched away, sheet covering it)
    /// must not leave a key down on the PC.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { abortPress() }
    }

    // MARK: Zones & labels (the drawn keys are a touch-user convenience;
    // VoiceOver only ever sees the pad as one element)

    /// Rebuild the pad for the current page. The modifier block is appended
    /// unchanged every time, which is what makes it the same six zones in the
    /// same place on every page.
    private func rebuildZones(announcePage: Bool) {
        pages = VirtualKeys.pages(includeExtendedFKeys: extendedFKeys)
        guard !pages.isEmpty else { return }
        let page = pages[min(max(pageIndex, 0), pages.count - 1)]
        let newRows = page.rows + VirtualKeys.modifierBlock
        pageRowCount = page.rows.count

        if newRows != rows {
            abortPress()
            rows = newRows
            for label in labels.flatMap({ $0 }) { label.removeFromSuperview() }
            labels = rows.map { row in
                row.map { key in
                    let label = UILabel()
                    label.text = key.name
                    label.adjustsFontSizeToFitWidth = true
                    label.minimumScaleFactor = 0.5
                    label.textAlignment = .center
                    label.layer.cornerRadius = 8
                    label.layer.borderWidth = 1
                    label.layer.borderColor = UIColor.separator
                        .resolvedColor(with: traitCollection).cgColor
                    label.layer.masksToBounds = true
                    label.isAccessibilityElement = false
                    addSubview(label)
                    return label
                }
            }
            setNeedsLayout()
        }
        if announcePage { announce(page.title) }
    }

    /// Three visibly distinct key states. A **filled background** is the
    /// primary cue (field-requested 2026-08-10): tinted text alone was too
    /// quiet to find at a glance.
    ///
    /// The washes used to be 20% and 45% tint, and 20% was still too quiet to
    /// spot at a glance (field-reported 2026-08-20). They are now **half
    /// strength for on and solid for down**, which is a much wider gap from a
    /// plain grey key and from each other. A **thicker tinted border** rides
    /// along with both, so the state survives a display that is washing the
    /// colour out and does not rest on hue alone.
    private func refreshLabels() {
        let separator = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        let accent = tintColor.resolvedColor(with: traitCollection)
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, key) in row.enumerated() {
                guard rowIndex < labels.count, columnIndex < labels[rowIndex].count else { continue }
                let label = labels[rowIndex][columnIndex]
                let down = key.vk == heldVK
                let on = latchedKeys.contains(key.vk)
                label.backgroundColor = down
                    ? accent
                    : (on ? accent.withAlphaComponent(0.5) : .tertiarySystemFill)
                // White on the solid fill, the ordinary label colour on the
                // half wash — which stays readable in both light and dark
                // mode, where a tinted label on a tinted fill would not.
                label.textColor = down ? .white : .label
                label.font = .systemFont(
                    ofSize: labelPointSize,
                    weight: on || down ? .semibold : .regular
                )
                label.layer.borderWidth = on || down ? 2.5 : 1
                label.layer.borderColor = on || down ? accent.cgColor : separator
            }
        }
    }

    /// Borders are CGColors, which don't follow light/dark mode by themselves.
    /// `refreshLabels` already resolves them against the current traits, so
    /// re-running it is the whole fix.
    private func updateBorderColors() {
        refreshLabels()
    }

    private var labelPointSize: CGFloat {
        guard !rows.isEmpty, bounds.height > 0 else { return 15 }
        return min(max(bounds.height / CGFloat(rows.count) * 0.28, 11), 22)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(max(rows.count, 1)) * 72)
    }

    /// Gap between key rectangles, so the pad reads as keys rather than as a
    /// wireframe grid. Purely cosmetic — hit testing uses the full cell, so no
    /// touch can land "between" two keys.
    private static let keyGap: CGFloat = 3

    /// Share of the pad's height given to the modifier block.
    ///
    /// A fixed fraction rather than an equal share of all rows, and that is
    /// the point: pages have three rows or four, so equal rows would shift the
    /// modifiers up and down as the page changed. At a fixed fraction the six
    /// modifier zones sit at exactly the same coordinates on every page, which
    /// is the only reason muscle memory can form for them at all.
    private static let modifierBlockFraction: CGFloat = 0.4

    /// Where the page block ends and the modifier block begins.
    private var blockSplit: CGFloat {
        bounds.height * (1 - Self.modifierBlockFraction)
    }

    private func rowGeometry(_ index: Int) -> (y: CGFloat, height: CGFloat) {
        let split = blockSplit
        if index < pageRowCount {
            let height = split / CGFloat(max(pageRowCount, 1))
            return (CGFloat(index) * height, height)
        }
        let modifierRows = max(rows.count - pageRowCount, 1)
        let height = (bounds.height - split) / CGFloat(modifierRows)
        return (split + CGFloat(index - pageRowCount) * height, height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A resize (rotation, the on-screen keyboard, an iPad window drag)
        // moves every zone out from under the finger: end the press, which
        // also releases anything this pad is holding down on the PC.
        if let lastLaidOutSize, lastLaidOutSize != bounds.size { abortPress() }
        lastLaidOutSize = bounds.size

        if rows.isEmpty { rebuildZones(announcePage: false) }
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let gap = Self.keyGap
        for (rowIndex, row) in rows.enumerated() {
            let (y, rowHeight) = rowGeometry(rowIndex)
            let columnWidth = bounds.width / CGFloat(row.count)
            for columnIndex in row.indices {
                labels[rowIndex][columnIndex].frame = CGRect(
                    x: CGFloat(columnIndex) * columnWidth + gap / 2,
                    y: y + gap / 2,
                    width: max(columnWidth - gap, 1),
                    height: max(rowHeight - gap, 1)
                )
            }
        }
        refreshLabels()
    }

    // MARK: Shared helpers

    private func zone(at point: CGPoint) -> PadZone? {
        guard !rows.isEmpty, bounds.contains(point) else { return nil }
        let split = blockSplit
        let rowIndex: Int
        if point.y < split, pageRowCount > 0 {
            let height = split / CGFloat(pageRowCount)
            rowIndex = min(max(Int(point.y / height), 0), pageRowCount - 1)
        } else {
            let modifierRows = max(rows.count - pageRowCount, 1)
            let height = (bounds.height - split) / CGFloat(modifierRows)
            let offset = min(max(Int((point.y - split) / height), 0), modifierRows - 1)
            rowIndex = pageRowCount + offset
        }
        let row = rows[rowIndex]
        guard !row.isEmpty else { return nil }
        let columnWidth = bounds.width / CGFloat(row.count)
        let column = min(max(Int(point.x / columnWidth), 0), row.count - 1)
        return PadZone(row: rowIndex, column: column)
    }

    private func key(at zone: PadZone) -> VirtualKey {
        rows[zone.row][zone.column]
    }

    /// Interrupting on purpose: while dragging, the newest key name must win
    /// immediately — queueing here would narrate history.
    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Speech for the hold stage only, so turning the cue off leaves the
    /// haptics as the channel and the pad otherwise as talkative as before.
    private func announceStage(_ message: String) {
        guard speaksHoldStages else { return }
        announce(message)
    }

    private func description(of key: VirtualKey) -> String {
        let name = key.spokenName
        if latchedKeys.contains(key.vk) { return "\(name), on" }
        return VirtualKeys.modifierVKs.contains(key.vk) ? "\(name), off" : name
    }

    /// The vibration for arriving on a key — **always exactly one**, and with
    /// rich haptics on, its *strength* is the key's state.
    ///
    /// - key off: the ordinary selection tick
    /// - key on: a firmer single knock
    /// - key down on the PC: a hard single knock
    ///
    /// Earlier versions added a *second* pulse for the state and a third for
    /// crossing into another row. Field-rejected as unintuitive (2026-08-10):
    /// several pulses per key have to be counted and told apart, while one
    /// pulse that is simply harder is read instantly and needs no learning.
    private func feedbackEntering(_ key: VirtualKey) {
        guard richHaptics else {
            selectionTick.selectionChanged()
            return
        }
        if key.vk == heldVK {
            edgeThump.impactOccurred()
        } else if latchedKeys.contains(key.vk) {
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
        announce("Modifiers cleared")
    }

    @objc private func handleNextPage() { stepPage(by: 1) }
    @objc private func handlePreviousPage() { stepPage(by: -1) }

    /// Paging ends any press first: the finger is on a zone that is about to
    /// mean a different key, and a key held down on the PC has to be let go
    /// before its zone disappears.
    private func stepPage(by delta: Int) {
        abortPress()
        guard pages.count > 1 else {
            edgeThump.impactOccurred()
            return
        }
        let target = pageIndex + delta
        guard pages.indices.contains(target) else {
            // A harder knock for "there is nothing past this" — the same edge
            // cue the pad has always used.
            edgeThump.impactOccurred()
            return
        }
        selectionTick.selectionChanged()
        // The announcement rides on `pageIndex` being set, which happens when
        // the tab hands the new value back.
        pageChangeCameFromSwipe = true
        onPageStep?(delta)
    }

    // MARK: Press & hold

    /// Start (or restart) the countdown for `key`. Any key still down on the
    /// PC from the previous zone is released first — sliding off a held key
    /// ends its hold exactly like lifting does.
    private func startPress(on key: VirtualKey) {
        endHoldIfNeeded()
        cancelHoldTimer()
        pressKey = key
        pressStage = .pressing
        guard holdEnabled else { return }
        // `.common` mode so the countdown keeps running through anything that
        // puts the run loop into a tracking mode while the finger is down.
        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            self?.holdStageFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func holdStageFired() {
        guard pressStage == .pressing, let key = pressKey else { return }
        guard onHoldBegin?(key) == true else {
            // Refused (forwarding off, not connected): the tab already said
            // why. The press is over — never leave a key looking held that
            // never went down.
            pressStage = .spent
            return
        }
        pressStage = .held
        heldVK = key.vk
        refreshLabels()
        edgeThump.impactOccurred()
        announceStage("\(key.spokenName) held down")
    }

    /// Release a key this press put down on the PC.
    private func endHoldIfNeeded() {
        guard pressStage == .held, let key = pressKey else { return }
        pressStage = .spent
        heldVK = nil
        onHoldEnd?(key)
        refreshLabels()
        sendThump.impactOccurred()
        announceStage("\(key.spokenName) released")
    }

    /// A press that ended before the hold: modifiers toggle, other keys send.
    /// Pressing a modifier that is already on is how you turn it off.
    private func shortPress(_ key: VirtualKey) {
        if latchedKeys.contains(key.vk) {
            setLatched(key, false)
            selectionTick.selectionChanged()
            announce("\(key.spokenName) off")
        } else if VirtualKeys.modifierVKs.contains(key.vk) {
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
        cancelHoldTimer()
        pressStage = .spent
        pressKey = nil
        trackedTouch = nil
        trackedZone = nil
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // MARK: Raw touch tracking (direct touch delivers touches straight here;
    // this is where the latency win comes from)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let isFirstFinger = trackedTouch == nil && touches.count == 1 && event?.allTouches?.count == 1
        guard isFirstFinger, let touch = touches.first else {
            // A second finger joined (a two-finger tap or a page swipe): the
            // press is over, and the eventual lift must not act.
            abortPress()
            return
        }
        // Warming the Taptic Engine here is what keeps the first tick of a
        // drag as prompt as the rest.
        selectionTick.prepare()
        edgeThump.prepare()
        stateThump.prepare()
        trackedTouch = touch
        updateTrackedZone(with: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        updateTrackedZone(with: touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        // Catch a lift that landed in a zone the move events never reported.
        updateTrackedZone(with: touch)
        cancelHoldTimer()

        switch pressStage {
        case .held:
            endHoldIfNeeded()
        case .pressing:
            if let key = pressKey { shortPress(key) }
        case .spent:
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
            cancelHoldTimer()
            pressStage = .spent
            pressKey = nil
            return
        }
        let padKey = key(at: newZone)
        feedbackEntering(padKey)
        announce(description(of: padKey))
        startPress(on: padKey)
    }
}
