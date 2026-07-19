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
/// Both modes: two-finger tap clears all toggled modifiers. Success is
/// silent (plus a light haptic); failures speak via the shared send path.
/// Keys always send wrapped in the toggled modifiers — the pad's modifier
/// band makes that intent explicit.
struct VirtualKeyPad: UIViewRepresentable {
    let settings: AppSettings
    /// Snapshot of the tab's toggled modifiers — owned by the tab so the
    /// "Will send" readout and Send stay honest.
    let selectedModifiers: Set<UInt16>
    let onToggleModifier: (VirtualKey) -> Void
    let onClearModifiers: () -> Void
    let onSend: (VirtualKey) -> Void

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
        view.selectedModifiers = selectedModifiers
        view.onToggleModifier = onToggleModifier
        view.onClearModifiers = onClearModifiers
        view.onSend = onSend
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
    var onToggleModifier: ((VirtualKey) -> Void)?
    var onClearModifiers: (() -> Void)?
    var onSend: ((VirtualKey) -> Void)?

    var sliderMode = false {
        didSet {
            guard oldValue != sliderMode else { return }
            abortTracking()
            for recognizer in sliderRecognizers { recognizer.isEnabled = sliderMode }
            updateAccessibilityHint()
        }
    }

    var selectedModifiers: Set<UInt16> = [] {
        didSet {
            guard oldValue != selectedModifiers else { return }
            refreshModifierLabels()
        }
    }

    private var bands: [PadBand] = []
    private var labels: [[UILabel]] = []
    private let selectionTick = UISelectionFeedbackGenerator()
    private let sendThump = UIImpactFeedbackGenerator(style: .light)
    /// Noticeably harder than the selection tick: felt when a swipe tries to
    /// step past the first/last position — the non-visual "end of the row".
    private let edgeThump = UIImpactFeedbackGenerator(style: .rigid)

    // Grid mode: the single tracked finger and the zone it is over.
    private var trackedTouch: UITouch?
    private var trackedZone: PadZone?

    // Slider mode: which band is current, and each band's position
    // (key bands: 0 = "None", i = keys[i - 1]; modifier band: browse index).
    private var currentBand = 0
    private var bandPositions: [Int] = []

    private var sliderRecognizers: [UIGestureRecognizer] = []

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

        // Both modes: two-finger tap clears every toggled modifier.
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
            addGestureRecognizer(recognizer)
        }
        sliderRecognizers = swipes
    }

    private func updateAccessibilityHint() {
        accessibilityHint = sliderMode
            ? "Touches here work directly. Swipe left or right to choose a row, up to move forward through its keys, down to move back, and tap once to send. Two-finger swipe left resets the row, two-finger tap clears the modifiers."
            : "Touches here work directly. Drag to hear the keys and lift on one to send it right away. Lifting on a modifier turns it on or off. Two-finger tap clears the modifiers."
    }

    // MARK: Bands & visible labels (touch-user convenience; VoiceOver only
    // ever sees the pad as one element)

    func setBands(_ newBands: [PadBand]) {
        guard newBands != bands else { return }
        bands = newBands
        currentBand = 0
        bandPositions = Array(repeating: 0, count: bands.count)
        trackedTouch = nil
        trackedZone = nil

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
        refreshModifierLabels()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func refreshModifierLabels() {
        for (bandIndex, band) in bands.enumerated() where band.isModifierBand {
            for (keyIndex, key) in band.keys.enumerated() {
                let on = selectedModifiers.contains(key.vk)
                labels[bandIndex][keyIndex].textColor = on ? tintColor : .label
                labels[bandIndex][keyIndex].font = on
                    ? .preferredFont(forTextStyle: .caption1)
                    : .preferredFont(forTextStyle: .caption2)
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

    private func description(of key: VirtualKey, inModifierBand: Bool) -> String {
        inModifierBand
            ? "\(key.name), \(selectedModifiers.contains(key.vk) ? "on" : "off")"
            : key.name
    }

    /// Toggle a modifier through the parent and speak the state it now has.
    /// The local set is flipped optimistically so a continuing drag reads
    /// the right state before SwiftUI's update pass comes around.
    private func toggleModifier(_ key: VirtualKey) {
        let nowOn = !selectedModifiers.contains(key.vk)
        if nowOn { selectedModifiers.insert(key.vk) } else { selectedModifiers.remove(key.vk) }
        onToggleModifier?(key)
        selectionTick.selectionChanged()
        announce("\(key.name) \(nowOn ? "on" : "off")")
    }

    private func send(_ key: VirtualKey) {
        sendThump.impactOccurred()
        onSend?(key)
    }

    @objc private func handleClearTap() {
        onClearModifiers?()
        selectedModifiers.removeAll()
        selectionTick.selectionChanged()
        announce("Modifiers cleared")
    }

    // MARK: Grid mode — raw touch tracking (direct touch delivers touches
    // straight here; this is where the latency win comes from)

    private func abortTracking() {
        trackedTouch = nil
        trackedZone = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !sliderMode else { return }
        if trackedTouch == nil, touches.count == 1, event?.allTouches?.count == 1,
           let touch = touches.first {
            trackedTouch = touch
            updateTrackedZone(with: touch)
        } else {
            // A second finger joined (e.g. the start of a two-finger tap):
            // the drag is over, and the eventual lift must not send.
            abortTracking()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !sliderMode, let touch = trackedTouch, touches.contains(touch) else { return }
        updateTrackedZone(with: touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard !sliderMode, let touch = trackedTouch, touches.contains(touch) else { return }
        let liftZone = zone(at: touch.location(in: self))
        abortTracking()
        guard let liftZone else { return }
        let band = bands[liftZone.band]
        let key = band.keys[liftZone.key]
        if band.isModifierBand {
            toggleModifier(key)
        } else {
            send(key)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        abortTracking()
    }

    private func updateTrackedZone(with touch: UITouch) {
        let newZone = zone(at: touch.location(in: self))
        guard newZone != trackedZone else { return }
        trackedZone = newZone
        guard let newZone else { return }
        let band = bands[newZone.band]
        selectionTick.selectionChanged()
        announce(description(of: band.keys[newZone.key], inModifierBand: band.isModifierBand))
    }

    // MARK: Slider mode — recognizer driven

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
        return position == 0 ? "None" : band.keys[position - 1].name
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
        let band = bands[currentBand]
        let position = bandPositions[currentBand]
        if band.isModifierBand {
            toggleModifier(band.keys[position])
        } else if position == 0 {
            announce("No key selected")
        } else {
            send(band.keys[position - 1])
        }
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
