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
/// **What it draws is a user-editable `Pad`** (since 2026-11): a rows ×
/// columns grid, 1–4 wide and 1–6 tall, whose keys are rectangles spanning
/// any number of columns and rows, and whose empty cells are dimmed gaps. Pads are edited in
/// Settings → Pads; the shipped defaults are the old pages with the six
/// modifiers as their bottom two rows. Modifiers are ordinary keys now — the
/// fixed modifier block went when pads became editable.
///
/// Gestures, one set, no modes:
///
/// - Drag to hear the key under the finger (interrupting announcement plus a
///   tick per boundary); lift on a key to send it, lift on a modifier to
///   toggle it. Pressing a modifier that is on turns it off. **A gap is
///   silent** — no speech, no tick — and lifting on one sends nothing.
/// - **Press and hold** (`virtualPadHoldEnabled`): after
///   `virtualPadHoldDelay` the key is pressed *down* on the PC and stays down
///   until the finger lifts, so it repeats there. The Windows agent generates
///   that repeat (`KeyRepeater`); Windows never repeats injected keys itself.
/// - **Multi-finger gestures are the user's** (Settings → Key pad → Gestures,
///   `AppSettings.virtualPadGestures`): two- and three-finger swipes in four
///   directions, two- and three-finger single/double/triple taps, and a
///   two-finger twist left/right like VoiceOver's rotor (one step per ~36°,
///   repeating while the twist continues). Defaults are the old fixed set:
///   two-finger swipe left/right pages, two-finger tap clears the modifiers.
///   Only assigned gestures get a recognizer, so an unused double tap costs a
///   single tap no waiting. An extra finger landing mid-drag aborts the drag.
/// - **Wait for more fingers** (`virtualPadMultiFingerGrace`, off by default):
///   the first finger is held silent for that long, so a second finger landing
///   a beat late turns the touch into a gesture before any key is spoken or
///   sent — including a first finger that brushed and already lifted.
///
/// State shows as a **filled key**: the key's own fill off (a coloured key is
/// its colour at full strength), half-strength accent on, solid accent down on
/// the PC, with a thicker border on both live states so it never rests on hue
/// alone. A coloured key keeps its colour in the border while it is on. Keys
/// can span several columns and rows.
///
/// **One zone, one vibration** — and with `virtualPadRichHaptics` on, how hard
/// it is *is* the key's state: light tick = off, firmer knock = turned on,
/// hard knock = down on the PC (field-chosen 2026-08-10 over extra pulses).
struct VirtualKeyPad: UIViewRepresentable {
    let settings: AppSettings
    /// The pads to page through — the visible ones, in order.
    let pads: [Pad]
    /// Which pad is shown. Owned by the tab, because the tab's toolbar
    /// control changes it too.
    let pageIndex: Int
    /// Snapshot of the tab's latched modifiers — owned by the tab so Send's
    /// hint stays honest.
    let latchedKeys: Set<UInt16>
    /// Move the pad by ±1. The pad reports the gesture rather than owning the
    /// index, so the toolbar control and the swipe can't disagree.
    let onPageStep: (Int) -> Void
    /// Latch a modifier on or off. Explicit rather than a toggle: the pad
    /// knows the state it wants, and a toggle would race the SwiftUI update.
    let onSetLatched: (UInt16, Bool) -> Void
    let onClearLatched: () -> Void
    let onSend: (PadKey) -> Void
    /// Press the key down on the PC and keep it down. Returns false when the
    /// connection can't carry it (the tab announces why), and the press is
    /// then simply spent — nothing is left looking held.
    let onHoldBegin: (PadKey) -> Bool
    /// Release a key put down by `onHoldBegin`.
    let onHoldEnd: (PadKey) -> Void

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
    /// the screen. Zones are aimed at by feel, so every point counts.
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
        view.holdEnabled = settings.virtualPadHoldEnabled
        view.holdDelay = settings.virtualPadHoldDelay
        view.speaksHoldStages = settings.virtualPadHoldSpeech
        view.richHaptics = settings.virtualPadRichHaptics
        view.multiFingerGrace = settings.virtualPadMultiFingerGrace
        view.gestureActions = settings.virtualPadGestures
        view.latchedKeys = latchedKeys
        view.onPageStep = onPageStep
        view.onSetLatched = onSetLatched
        view.onClearLatched = onClearLatched
        view.onSend = onSend
        view.onHoldBegin = onHoldBegin
        view.onHoldEnd = onHoldEnd
        // Last, so the announcement it makes describes a fully configured pad.
        view.setPads(pads, index: pageIndex)
    }
}

/// What the finger is over: a key (by id — every cell of a wide key is the
/// same target, so crossing between them is not a boundary) or a gap. All
/// gaps are the same target: moving between two of them changes nothing.
private enum PadTarget: Equatable {
    case key(UUID)
    case gap
}

final class KeyPadUIView: UIView {
    var onPageStep: ((Int) -> Void)?
    var onSetLatched: ((UInt16, Bool) -> Void)?
    var onClearLatched: (() -> Void)?
    var onSend: ((PadKey) -> Void)?
    var onHoldBegin: ((PadKey) -> Bool)?
    var onHoldEnd: ((PadKey) -> Void)?

    private var pads: [Pad] = []
    private var pageIndex = 0
    /// The pad on screen, as last built.
    private var pad: Pad?

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
    /// Seconds a first finger stays silent waiting for a second; 0 = off.
    var multiFingerGrace: TimeInterval = 0

    /// What each multi-finger gesture does. Changing it rebuilds the
    /// recognizers, since only assigned gestures get one.
    var gestureActions: [PadGesture: PadGestureAction] = [:] {
        didSet {
            guard oldValue != gestureActions else { return }
            installGestureRecognizers()
            updateAccessibilityHint()
        }
    }

    private var installedRecognizers: [UIGestureRecognizer] = []
    private var recognizerGestures: [ObjectIdentifier: PadGesture] = [:]
    /// Twist steps already acted on in the current twist, signed (+ = right).
    private var twistStepsTaken = 0
    /// One rotor-like step. Small enough to repeat comfortably within one
    /// wrist turn, big enough that two fingers landing at a slant don't fire.
    private static let twistStep: CGFloat = .pi / 5

    // MARK: Multi-finger grace

    private var settleTimer: Timer?
    /// The first finger is inside the grace window: tracked, but nothing has
    /// been spoken, felt or started for it yet.
    private var settling = false
    /// A finger that lifted inside the window. Its key goes out when the
    /// window ends, unless another finger lands first.
    private var pendingLiftKey: PadKey?

    var latchedKeys: Set<UInt16> = [] {
        didSet {
            guard oldValue != latchedKeys else { return }
            refreshLabels()
        }
    }

    private var keyLabels: [UUID: UILabel] = [:]
    private var gapViews: [UIView] = []
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

    /// The single tracked finger and what it is over.
    private var trackedTouch: UITouch?
    private var trackedTarget: PadTarget?

    // MARK: Press state

    /// How far the current press has got. `spent` is a press that has already
    /// done its work (or been called off) — its lift must do nothing.
    private enum PressStage {
        case pressing, held, spent
    }

    private var pressStage: PressStage = .spent
    private var pressKey: PadKey?
    private var holdTimer: Timer?
    /// The key currently down on the PC, for the label highlight.
    private var heldKeyID: UUID?

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
        // pad is direct interaction immediately — no activation step.
        // silentOnTouch keeps VoiceOver quiet so the pad's own announcements
        // are the only voice.
        accessibilityTraits = .allowsDirectInteraction
        accessibilityDirectTouchOptions = [.silentOnTouch]
        updateAccessibilityHint()

        // Borders are CGColors, which are resolved once and don't follow
        // light/dark mode on their own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyPadUIView, _) in
            view.refreshLabels()
        }

        installGestureRecognizers()
    }

    /// One recognizer per *assigned* gesture. Every gesture uses at least two
    /// fingers, so a one-finger drag across the pad — which is how every key
    /// is found — can never be mistaken for one.
    private func installGestureRecognizers() {
        for recognizer in installedRecognizers { removeGestureRecognizer(recognizer) }
        installedRecognizers = []
        recognizerGestures = [:]

        func add(_ recognizer: UIGestureRecognizer, for gesture: PadGesture?) {
            // The hold machine runs off raw touches; it needs the touch to END
            // rather than be cancelled out from under it when a gesture
            // recognizes, or a key held down on the PC could be released late,
            // or not at all. And lift-to-send must not wait for a two-finger
            // recognizer to give up on a one-finger touch.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            addGestureRecognizer(recognizer)
            installedRecognizers.append(recognizer)
            if let gesture { recognizerGestures[ObjectIdentifier(recognizer)] = gesture }
        }

        // fingers → tap count → recognizer, to chain the failure requirements.
        var taps: [Int: [Int: UITapGestureRecognizer]] = [:]
        for gesture in PadGesture.allCases where action(for: gesture).kind != .nothing {
            switch gesture.kind {
            case .swipe(let direction):
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
                let swipeDirection: UISwipeGestureRecognizer.Direction = switch direction {
                case .up: .up
                case .down: .down
                case .left: .left
                case .right: .right
                }
                swipe.direction = swipeDirection
                swipe.numberOfTouchesRequired = gesture.fingers
                add(swipe, for: gesture)
            case .tap(let count):
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
                tap.numberOfTouchesRequired = gesture.fingers
                tap.numberOfTapsRequired = count
                add(tap, for: gesture)
                taps[gesture.fingers, default: [:]][count] = tap
            case .twist:
                break
            }
        }
        // A tap waits for the longer taps with the same fingers to fail —
        // only those actually assigned, so the wait is paid only when needed.
        for byCount in taps.values {
            for (count, tap) in byCount {
                for (longerCount, longer) in byCount where longerCount > count {
                    tap.require(toFail: longer)
                }
            }
        }
        if action(for: .twistLeft).kind != .nothing || action(for: .twistRight).kind != .nothing {
            add(UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:))), for: nil)
        }
    }

    private func action(for gesture: PadGesture) -> PadGestureAction {
        gestureActions[gesture] ?? .nothing
    }

    private func updateAccessibilityHint() {
        var hint = "Touches here work directly. Drag to hear the keys and lift on one to send it right away; lifting on a modifier turns it on or off. Empty spaces are silent and send nothing."
        if holdEnabled {
            hint += " Hold a key until it is pressed down on the PC, where it repeats until you lift."
        }
        let gestureLines = PadGesture.allCases.compactMap { gesture -> String? in
            let assigned = action(for: gesture)
            return assigned.kind == .nothing ? nil : "\(gesture.displayName): \(assigned.spokenDescription)"
        }
        if !gestureLines.isEmpty {
            hint += " " + gestureLines.joined(separator: ". ") + "."
        }
        accessibilityHint = hint
    }

    /// A pad taken out of the window (tab switched away, sheet covering it)
    /// must not leave a key down on the PC.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { abortPress() }
    }

    // MARK: Building (the drawn keys are a touch-user convenience; VoiceOver
    // only ever sees the pad as one element)

    func setPads(_ newPads: [Pad], index: Int) {
        pads = newPads
        let clamped = newPads.isEmpty ? 0 : min(max(index, 0), newPads.count - 1)
        let indexChanged = clamped != pageIndex
        pageIndex = clamped
        let announce = indexChanged && pageChangeCameFromSwipe
        if indexChanged { pageChangeCameFromSwipe = false }
        rebuild(announce: announce)
    }

    private func rebuild(announce: Bool) {
        let newPad = pads.isEmpty ? nil : pads[pageIndex]
        guard newPad != pad else { return }
        // The finger is on a zone that is about to mean something else, and a
        // key held down on the PC has to be let go before its zone goes.
        abortPress()
        pad = newPad

        for label in keyLabels.values { label.removeFromSuperview() }
        for gap in gapViews { gap.removeFromSuperview() }
        keyLabels = [:]
        gapViews = []

        if let pad {
            for row in 0..<pad.rows {
                for column in 0..<pad.columns where pad.key(atRow: row, column: column) == nil {
                    let gap = UIView()
                    gap.backgroundColor = .quaternarySystemFill
                    gap.layer.cornerRadius = 8
                    gap.isAccessibilityElement = false
                    gap.tag = row * pad.columns + column
                    addSubview(gap)
                    gapViews.append(gap)
                }
            }
            for placed in pad.keys {
                let label = UILabel()
                label.text = placed.key.label
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.5
                label.numberOfLines = 2
                label.textAlignment = .center
                label.layer.cornerRadius = 8
                label.layer.borderWidth = 1.5
                label.layer.masksToBounds = true
                label.isAccessibilityElement = false
                addSubview(label)
                keyLabels[placed.id] = label
            }
        }
        setNeedsLayout()
        if announce, let pad { self.announce(pad.displayTitle) }
    }

    /// Three visibly distinct key states. A **filled background** is the
    /// primary cue (field-requested 2026-08-10): tinted text alone was too
    /// quiet to find at a glance. Half strength for on and solid for down,
    /// each with a thicker border, so the state survives a washed-out display
    /// and does not rest on hue alone.
    ///
    /// A key's own colour is its *resting* fill, at full strength, with black
    /// or white text by contrast. The live states override the fill — the
    /// state matters more than the colour while it lasts — and a coloured key
    /// keeps its colour as the border while it is on.
    private func refreshLabels() {
        guard let pad else { return }
        // NOT `UIColor.separator`: that hairline left the keys looking
        // borderless (field-reported 2026-08-20).
        let outline = UIColor.label.withAlphaComponent(0.45)
            .resolvedColor(with: traitCollection).cgColor
        let accent = tintColor.resolvedColor(with: traitCollection)
        // A solid accent key needs an outline that is *not* accent, or the
        // border disappears into the fill.
        let downOutline = UIColor.label.resolvedColor(with: traitCollection).cgColor
        let downText = accent.highestContrastForeground
        for placed in pad.keys {
            guard let label = keyLabels[placed.id] else { continue }
            let key = placed.key
            let colour = key.color.uiColor?.resolvedColor(with: traitCollection)
            let down = placed.id == heldKeyID
            let on = key.togglesModifier && latchedKeys.contains(key.vk)
            let resting = key.color.restingFill.resolvedColor(with: traitCollection)
            label.backgroundColor = down ? accent : (on ? accent.withAlphaComponent(0.5) : resting)
            label.textColor = down
                ? downText
                : (on ? .label : key.color.restingText.resolvedColor(with: traitCollection))
            label.font = .systemFont(ofSize: labelPointSize, weight: on || down ? .semibold : .regular)
            label.layer.borderWidth = on || down ? 3 : 1.5
            label.layer.borderColor = down
                ? downOutline
                : (on ? (colour ?? accent).cgColor : outline)
        }
    }

    private var labelPointSize: CGFloat {
        guard let pad, bounds.height > 0 else { return 15 }
        return min(max(bounds.height / CGFloat(pad.rows) * 0.28, 11), 22)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(pad?.rows ?? 1) * 72)
    }

    /// Gap between key rectangles, so the pad reads as keys rather than as a
    /// wireframe grid. Purely cosmetic — hit testing uses the full cell, so no
    /// touch can land "between" two keys.
    private static let keyGap: CGFloat = 4

    private func cellFrame(row: Int, column: Int, columnSpan: Int = 1, rowSpan: Int = 1, in pad: Pad) -> CGRect {
        let rowHeight = bounds.height / CGFloat(pad.rows)
        let columnWidth = bounds.width / CGFloat(pad.columns)
        let gap = Self.keyGap
        return CGRect(
            x: CGFloat(column) * columnWidth + gap / 2,
            y: CGFloat(row) * rowHeight + gap / 2,
            width: max(CGFloat(columnSpan) * columnWidth - gap, 1),
            height: max(CGFloat(rowSpan) * rowHeight - gap, 1)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A resize (rotation, the on-screen keyboard, an iPad window drag)
        // moves every zone out from under the finger: end the press, which
        // also releases anything this pad is holding down on the PC.
        if let lastLaidOutSize, lastLaidOutSize != bounds.size { abortPress() }
        lastLaidOutSize = bounds.size

        guard let pad, bounds.width > 0, bounds.height > 0 else { return }
        for gap in gapViews {
            gap.frame = cellFrame(row: gap.tag / pad.columns, column: gap.tag % pad.columns, in: pad)
        }
        for placed in pad.keys {
            keyLabels[placed.id]?.frame = cellFrame(
                row: placed.row, column: placed.column,
                columnSpan: placed.columnSpan, rowSpan: placed.rowSpan, in: pad
            )
        }
        refreshLabels()
    }

    // MARK: Shared helpers

    private func target(at point: CGPoint) -> (PadTarget, PadKey?)? {
        guard let pad, bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return nil }
        let row = min(max(Int(point.y / (bounds.height / CGFloat(pad.rows))), 0), pad.rows - 1)
        let column = min(max(Int(point.x / (bounds.width / CGFloat(pad.columns))), 0), pad.columns - 1)
        guard let placed = pad.key(atRow: row, column: column) else { return (.gap, nil) }
        return (.key(placed.id), placed.key)
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

    private func description(of key: PadKey) -> String {
        guard key.togglesModifier else { return key.spokenLabel }
        return "\(key.spokenLabel), \(latchedKeys.contains(key.vk) ? "on" : "off")"
    }

    /// The vibration for arriving on a key — **always exactly one**, and with
    /// rich haptics on, its *strength* is the key's state.
    private func feedbackEntering(_ key: PadKey, id: UUID) {
        guard richHaptics else {
            selectionTick.selectionChanged()
            return
        }
        if id == heldKeyID {
            edgeThump.impactOccurred()
        } else if key.togglesModifier && latchedKeys.contains(key.vk) {
            stateThump.impactOccurred()
        } else {
            selectionTick.selectionChanged()
        }
    }

    /// Latch a modifier on/off through the parent. The local set is updated
    /// optimistically so a continuing drag reads the right state before
    /// SwiftUI's update pass comes around.
    private func setLatched(_ vk: UInt16, _ on: Bool) {
        guard latchedKeys.contains(vk) != on else { return }
        if on { latchedKeys.insert(vk) } else { latchedKeys.remove(vk) }
        onSetLatched?(vk, on)
    }

    private func send(_ key: PadKey) {
        sendThump.impactOccurred()
        onSend?(key)
    }

    private func clearModifiers() {
        onClearLatched?()
        latchedKeys.removeAll()
        selectionTick.selectionChanged()
        announce("Modifiers cleared")
    }

    // MARK: Gestures

    @objc private func handleGesture(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .ended,
              let gesture = recognizerGestures[ObjectIdentifier(recognizer)] else { return }
        performGesture(gesture)
    }

    /// Rotor-style: one step per `twistStep` of rotation, repeating while the
    /// twist continues, and turning back steps back. UIKit's rotation is
    /// positive clockwise, which is "right".
    @objc private func handleTwist(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            twistStepsTaken = 0
        case .changed:
            let steps = Int((recognizer.rotation / Self.twistStep).rounded(.towardZero))
            while twistStepsTaken < steps {
                twistStepsTaken += 1
                performGesture(.twistRight)
            }
            while twistStepsTaken > steps {
                twistStepsTaken -= 1
                performGesture(.twistLeft)
            }
        default:
            break
        }
    }

    private func performGesture(_ gesture: PadGesture) {
        let assigned = action(for: gesture)
        switch assigned.kind {
        case .nothing:
            return
        case .nextPad:
            stepPage(by: 1)
        case .previousPad:
            stepPage(by: -1)
        case .clearModifiers:
            abortPress()
            clearModifiers()
        case .sendKey:
            guard let key = assigned.padKey else { return }
            abortPress()
            // Unlike a pad key, nothing was spoken before this one went out,
            // so say what was sent. A failure announcement from the tab comes
            // after and interrupts it.
            if !key.togglesModifier { announce(key.spokenLabel) }
            shortPress(key)
        }
    }

    /// Paging ends any press first: a key held down on the PC has to be let
    /// go before its zone disappears.
    private func stepPage(by delta: Int) {
        abortPress()
        let target = pageIndex + delta
        guard pads.count > 1, pads.indices.contains(target) else {
            // A harder knock for "there is nothing past this" — the same edge
            // cue the pad has always used.
            edgeThump.impactOccurred()
            return
        }
        selectionTick.selectionChanged()
        // The announcement rides on the index being handed back.
        pageChangeCameFromSwipe = true
        onPageStep?(delta)
    }

    // MARK: Press & hold

    /// Start (or restart) the countdown for `key`. Any key still down on the
    /// PC from the previous zone is released first — sliding off a held key
    /// ends its hold exactly like lifting does.
    private func startPress(on key: PadKey) {
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
            // why. Never leave a key looking held that never went down.
            pressStage = .spent
            return
        }
        pressStage = .held
        heldKeyID = key.id
        refreshLabels()
        edgeThump.impactOccurred()
        announceStage("\(key.spokenLabel) held down")
    }

    /// Release a key this press put down on the PC.
    private func endHoldIfNeeded() {
        guard pressStage == .held, let key = pressKey else { return }
        pressStage = .spent
        heldKeyID = nil
        onHoldEnd?(key)
        refreshLabels()
        sendThump.impactOccurred()
        announceStage("\(key.spokenLabel) released")
    }

    /// A press that ended before the hold: modifiers toggle, other keys send.
    /// Pressing a modifier that is already on is how you turn it off.
    private func shortPress(_ key: PadKey) {
        if key.togglesModifier {
            let on = !latchedKeys.contains(key.vk)
            setLatched(key.vk, on)
            selectionTick.selectionChanged()
            announce("\(key.spokenLabel) \(on ? "on" : "off")")
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
        trackedTarget = nil
        cancelSettle()
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // MARK: Multi-finger grace window

    private func cancelSettle() {
        settleTimer?.invalidate()
        settleTimer = nil
        settling = false
        pendingLiftKey = nil
    }

    /// No second finger came: the touch is a one-finger touch after all.
    private func settleEnded() {
        settleTimer = nil
        guard settling else { return }
        settling = false
        if let key = pendingLiftKey {
            // A quick tap that finished inside the window: nothing was said
            // for it yet, so say it now, then act exactly as a lift would.
            pendingLiftKey = nil
            if !key.togglesModifier { announce(key.spokenLabel) }
            shortPress(key)
        } else if let touch = trackedTouch {
            updateTracking(with: touch)
        }
    }

    // MARK: Raw touch tracking (direct touch delivers touches straight here;
    // this is where the latency win comes from)

    /// Fingers currently down on the pad. `event.allTouches` is not that: it
    /// also carries touches elsewhere in the window and ones that ended in
    /// this very event, so a tap landing as another finger lifts read as a
    /// second finger and was thrown away.
    private func activeTouchCount(in event: UIEvent?) -> Int {
        event?.allTouches?.filter { touch in
            guard touch.phase != .ended, touch.phase != .cancelled,
                  let view = touch.view else { return false }
            return view.isDescendant(of: self)
        }.count ?? 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // A finger lifted inside the grace window and another lands before it
        // ended: a staggered multi-finger touch, so the lifted one never acts.
        if pendingLiftKey != nil { cancelSettle() }
        let isFirstFinger = trackedTouch == nil && touches.count == 1 && activeTouchCount(in: event) == 1
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
        guard multiFingerGrace > 0 else {
            updateTracking(with: touch)
            return
        }
        // Stay silent until the window shows this is really one finger.
        settling = true
        let timer = Timer(timeInterval: multiFingerGrace, repeats: false) { [weak self] _ in
            self?.settleEnded()
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !settling, let touch = trackedTouch, touches.contains(touch) else { return }
        updateTracking(with: touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if settling {
            // Lifted inside the window: remember the key under the lift and
            // let the window decide whether it was a brush before a gesture.
            pendingLiftKey = target(at: touch.location(in: self))?.1
            trackedTouch = nil
            trackedTarget = nil
            if pendingLiftKey == nil { cancelSettle() }
            return
        }
        // Catch a lift that landed in a zone the move events never reported.
        updateTracking(with: touch)
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
        trackedTarget = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        abortPress()
    }

    /// Ends whatever the finger was doing on its old target, so lifting on a
    /// gap or outside the pad sends nothing and a hold never outlives its key.
    private func releaseTrackedPress() {
        endHoldIfNeeded()
        cancelHoldTimer()
        pressStage = .spent
        pressKey = nil
    }

    private func updateTracking(with touch: UITouch) {
        let found = target(at: touch.location(in: self))
        let newTarget = found?.0
        guard newTarget != trackedTarget else { return }
        trackedTarget = newTarget
        guard let found, case .key(let id) = found.0, let key = found.1 else {
            // Off the pad, or onto a gap: silent by design — no tick, no
            // speech — and nothing is sent on lift.
            releaseTrackedPress()
            return
        }
        feedbackEntering(key, id: id)
        announce(description(of: key))
        startPress(on: key)
    }
}
