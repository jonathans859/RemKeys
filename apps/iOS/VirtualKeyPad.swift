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
/// Two gesture models, chosen in Settings (`virtualPadSliderMode`):
///
/// - **Grid (default, touch-typing model):** fixed spatial bands — modifiers,
///   editing, navigation, F1–F12, optionally F13–F24 — with the band's keys
///   side by side. Drag to hear the key under the finger (interrupting
///   announcement + a selection tick per boundary), lift on a key to send it
///   immediately, lift on a modifier to toggle it. Same grammar as
///   VoiceOver's touch typing, and fixed positions build muscle memory.
///   An extra finger landing mid-drag aborts the drag, so nothing fires.
/// - **Sliders (fallback):** one-finger swipe left/right moves between
///   bands, swipe up steps forward / down steps back (0 = "None"), tap
///   sends the band's current key; the modifiers band browses and
///   tap-toggles. Two-finger swipe left resets the current band; hitting
///   either end of a row answers with a harder edge haptic.
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
/// Keys always send wrapped in whatever is latched — the pad's modifier band
/// and the hold gesture make that intent explicit.
struct VirtualKeyPad: UIViewRepresentable {
    let settings: AppSettings
    /// Snapshot of the tab's latched keys (modifier band toggles and anything
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

    func makeUIView(context: Context) -> KeyPadUIView {
        let view = KeyPadUIView()
        configure(view)
        return view
    }

    func updateUIView(_ view: KeyPadUIView, context: Context) {
        configure(view)
    }

    private func configure(_ view: KeyPadUIView) {
        var bands: [PadBand] = [
            PadBand(title: "Modifiers", keys: VirtualKeys.modifiers, isModifierBand: true)
        ]
        bands += VirtualKeys.categories.map {
            PadBand(title: $0.title, keys: $0.keys, isModifierBand: false)
        }
        if settings.virtualPadExtendedFKeys {
            bands.append(PadBand(
                title: "Extended function keys",
                keys: VirtualKeys.extendedFunctionKeys,
                isModifierBand: false
            ))
        }
        view.setBands(bands)
        view.sliderMode = settings.virtualPadSliderMode
        view.holdEnabled = settings.virtualPadHoldEnabled
        view.latchDelay = settings.virtualPadLatchDelay
        view.holdDelay = settings.virtualPadHoldDelay
        view.speaksHoldStages = settings.virtualPadHoldSpeech
        view.latchedKeys = latchedKeys
        view.onSetLatched = onSetLatched
        view.onClearLatched = onClearLatched
        view.onSend = onSend
        view.onHoldBegin = onHoldBegin
        view.onHoldEnd = onHoldEnd
    }
}

/// One horizontal band of pad zones.
struct PadBand: Equatable {
    let title: String
    let keys: [VirtualKey]
    let isModifierBand: Bool
}

/// A zone address on the pad.
private struct PadZone: Equatable {
    let band: Int
    let key: Int
}

final class KeyPadUIView: UIView {
    var onSetLatched: ((VirtualKey, Bool) -> Void)?
    var onClearLatched: (() -> Void)?
    var onSend: ((VirtualKey) -> Void)?
    var onHoldBegin: ((VirtualKey) -> Bool)?
    var onHoldEnd: ((VirtualKey) -> Void)?

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

    var latchedKeys: Set<UInt16> = [] {
        didSet {
            guard oldValue != latchedKeys else { return }
            refreshLabels()
        }
    }

    private var bands: [PadBand] = []
    private var labels: [[UILabel]] = []
    private let selectionTick = UISelectionFeedbackGenerator()
    private let sendThump = UIImpactFeedbackGenerator(style: .light)
    /// Noticeably harder than the selection tick: felt when a swipe tries to
    /// step past the first/last position — the non-visual "end of the row".
    private let edgeThump = UIImpactFeedbackGenerator(style: .rigid)
    /// The hold stages, felt apart without looking: a soft swell when the key
    /// latches, the hard `edgeThump` when it actually goes down on the PC, and
    /// the light `sendThump` when it comes back up.
    private let latchThump = UIImpactFeedbackGenerator(style: .soft)

    // Grid mode: the single tracked finger and the zone it is over.
    private var trackedTouch: UITouch?
    private var trackedZone: PadZone?

    // Slider mode: which band is current, and each band's position
    // (key bands: 0 = "None", i = keys[i - 1]; modifier band: browse index).
    private var currentBand = 0
    private var bandPositions: [Int] = []
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
    private var pressKey: VirtualKey?
    private var pressIsModifierBand = false
    private var latchTimer: Timer?
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
        // so the pad's own announcements are the only voice. The trade:
        // exploring by touch ACROSS the pad interacts with it — acceptable
        // because the pad is pinned at the top, outside casual explore
        // paths, and a drag without a lift on a key sends nothing.
        accessibilityTraits = .allowsDirectInteraction
        accessibilityDirectTouchOptions = [.silentOnTouch]
        updateAccessibilityHint()

        // Both modes: two-finger tap clears the whole selection.
        let clearTap = UITapGestureRecognizer(target: self, action: #selector(handleClearTap))
        clearTap.numberOfTouchesRequired = 2
        addGestureRecognizer(clearTap)

        // Slider mode only; disabled while the grid handles raw touches.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSliderTap))
        tap.numberOfTouchesRequired = 1
        let resetSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleBandReset))
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

    // MARK: Bands & visible labels (touch-user convenience; VoiceOver only
    // ever sees the pad as one element)

    func setBands(_ newBands: [PadBand]) {
        guard newBands != bands else { return }
        abortPress()
        bands = newBands
        currentBand = 0
        bandPositions = Array(repeating: 0, count: bands.count)

        for label in labels.flatMap({ $0 }) { label.removeFromSuperview() }
        labels = bands.map { band in
            band.keys.map { key in
                let label = UILabel()
                label.text = key.name
                label.font = .preferredFont(forTextStyle: .caption2)
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.5
                label.textAlignment = .center
                label.layer.borderWidth = 0.5
                label.layer.borderColor = UIColor.separator.cgColor
                label.isAccessibilityElement = false
                addSubview(label)
                return label
            }
        }
        refreshLabels()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Latched keys are tinted and a size larger in *every* band now, not just
    /// the modifier one — holding can latch an F-key just as well.
    private func refreshLabels() {
        for (bandIndex, band) in bands.enumerated() {
            for (keyIndex, key) in band.keys.enumerated() {
                let label = labels[bandIndex][keyIndex]
                let on = latchedKeys.contains(key.vk)
                label.textColor = on ? tintColor : .label
                label.font = on
                    ? .preferredFont(forTextStyle: .caption1)
                    : .preferredFont(forTextStyle: .caption2)
                label.backgroundColor = key.vk == heldVK
                    ? tintColor.withAlphaComponent(0.25)
                    : .clear
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(bands.count) * 56)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bands.isEmpty, bounds.width > 0 else { return }
        let bandHeight = bounds.height / CGFloat(bands.count)
        for (bandIndex, band) in bands.enumerated() {
            let keyWidth = bounds.width / CGFloat(band.keys.count)
            for keyIndex in band.keys.indices {
                labels[bandIndex][keyIndex].frame = CGRect(
                    x: CGFloat(keyIndex) * keyWidth,
                    y: CGFloat(bandIndex) * bandHeight,
                    width: keyWidth,
                    height: bandHeight
                )
            }
        }
    }

    // MARK: Shared helpers

    private func zone(at point: CGPoint) -> PadZone? {
        guard !bands.isEmpty, bounds.contains(point) else { return nil }
        let bandHeight = bounds.height / CGFloat(bands.count)
        let bandIndex = min(max(Int(point.y / bandHeight), 0), bands.count - 1)
        let keys = bands[bandIndex].keys
        let keyWidth = bounds.width / CGFloat(keys.count)
        let keyIndex = min(max(Int(point.x / keyWidth), 0), keys.count - 1)
        return PadZone(band: bandIndex, key: keyIndex)
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

    private func description(of key: VirtualKey, inModifierBand: Bool) -> String {
        if latchedKeys.contains(key.vk) { return "\(key.name), on" }
        return inModifierBand ? "\(key.name), off" : key.name
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

    /// Start (or restart) the countdown for `key`. Any key still down on the
    /// PC from the previous zone is released first — sliding off a held key
    /// ends its hold exactly like lifting does.
    private func startPress(on key: VirtualKey, inModifierBand: Bool) {
        endHoldIfNeeded()
        cancelStageTimers()
        pressKey = key
        pressIsModifierBand = inModifierBand
        pressStage = .pressing
        guard holdEnabled else { return }
        latchTimer = scheduleStage(after: latchDelay) { [weak self] in self?.latchStageFired() }
    }

    private func latchStageFired() {
        guard pressStage == .pressing, let key = pressKey else { return }
        pressStage = .latched
        suppressSliderTap = true
        setLatched(key, true)
        latchThump.impactOccurred()
        announceStage("\(key.name) on")
        holdTimer = scheduleStage(after: holdDelay) { [weak self] in self?.holdStageFired() }
    }

    private func holdStageFired() {
        guard pressStage == .latched, let key = pressKey else { return }
        // A refused hold (forwarding off, not connected) leaves the press at
        // the latched stage; the tab has already said why.
        guard onHoldBegin?(key) == true else { return }
        pressStage = .held
        heldVK = key.vk
        refreshLabels()
        edgeThump.impactOccurred()
        announceStage("\(key.name) held down")
    }

    /// Release a key this press put down on the PC, and drop its latch with
    /// it: a hold is momentary from end to end, so lifting leaves nothing
    /// selected (field decision 2026-08-10).
    private func endHoldIfNeeded() {
        guard pressStage == .held, let key = pressKey else { return }
        pressStage = .spent
        heldVK = nil
        onHoldEnd?(key)
        setLatched(key, false)
        refreshLabels()
        sendThump.impactOccurred()
        announceStage("\(key.name) released")
    }

    /// A press that ended before the latch stage: the pad's original grammar —
    /// modifiers toggle, other keys send. Pressing an already-latched key is
    /// how you let it go again, in either kind of band.
    private func shortPress(_ key: VirtualKey, inModifierBand: Bool) {
        if latchedKeys.contains(key.vk) {
            setLatched(key, false)
            selectionTick.selectionChanged()
            announce("\(key.name) off")
        } else if inModifierBand {
            setLatched(key, true)
            selectionTick.selectionChanged()
            announce("\(key.name) on")
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
            if !sliderMode, let key = pressKey {
                shortPress(key, inModifierBand: pressIsModifierBand)
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
        let band = bands[newZone.band]
        let key = band.keys[newZone.key]
        selectionTick.selectionChanged()
        announce(description(of: key, inModifierBand: band.isModifierBand))
        startPress(on: key, inModifierBand: band.isModifierBand)
    }

    /// How far a slider-mode finger may drift and still count as a hold.
    private static let sliderHoldSlop: CGFloat = 12

    // MARK: Slider mode — recognizer driven

    /// The key the current row points at, or nil on a key band's "None".
    private var sliderKey: VirtualKey? {
        guard !bands.isEmpty else { return nil }
        let band = bands[currentBand]
        let position = bandPositions[currentBand]
        if band.isModifierBand { return band.keys[position] }
        return position == 0 ? nil : band.keys[position - 1]
    }

    private func beginSliderPress() {
        guard let key = sliderKey else {
            pressStage = .spent
            pressKey = nil
            return
        }
        startPress(on: key, inModifierBand: bands[currentBand].isModifierBand)
    }

    private func moveBand(by delta: Int) {
        let target = min(max(currentBand + delta, 0), bands.count - 1)
        guard target != currentBand else {
            edgeThump.impactOccurred()
            return
        }
        currentBand = target
        selectionTick.selectionChanged()
        let band = bands[currentBand]
        announce("\(band.title): \(currentPositionDescription())")
    }

    private func currentPositionDescription() -> String {
        let band = bands[currentBand]
        let position = bandPositions[currentBand]
        if band.isModifierBand {
            return description(of: band.keys[position], inModifierBand: true)
        }
        return position == 0 ? "None" : description(of: band.keys[position - 1], inModifierBand: false)
    }

    private func stepPosition(by delta: Int) {
        let band = bands[currentBand]
        // Key bands have a leading "None" slot; the modifier band browses
        // its keys directly (several can be on, so position can't be the
        // selection there).
        let count = band.isModifierBand ? band.keys.count : band.keys.count + 1
        let target = min(max(bandPositions[currentBand] + delta, 0), count - 1)
        guard target != bandPositions[currentBand] else {
            edgeThump.impactOccurred()
            return
        }
        bandPositions[currentBand] = target
        selectionTick.selectionChanged()
        announce(currentPositionDescription())
    }

    @objc private func handleSwipeRight() { moveBand(by: 1) }
    @objc private func handleSwipeLeft() { moveBand(by: -1) }
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
        let band = bands[currentBand]
        guard let key = sliderKey else {
            announce("No key selected")
            return
        }
        shortPress(key, inModifierBand: band.isModifierBand)
    }

    @objc private func handleBandReset() {
        let band = bands[currentBand]
        if band.isModifierBand {
            handleClearTap()
        } else {
            bandPositions[currentBand] = 0
            selectionTick.selectionChanged()
            announce("\(band.title) reset")
        }
    }
}
