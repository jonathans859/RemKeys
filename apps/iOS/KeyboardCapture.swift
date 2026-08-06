import SwiftUI
import UIKit
import BridgeCore

/// Hosts a `UIView` that becomes first responder so attached Bluetooth / USB-C
/// keyboard events flow through `pressesBegan`/`pressesEnded`. SwiftUI's
/// keyboard shortcuts abstract too aggressively for this (no key-up, no
/// individual modifiers).
///
/// `pressesBegan` is the primary source but not the only one: the system keeps
/// Cmd chords for itself before the responder chain sees them, so
/// `GameControllerCapture` reads the same keyboard at the HID layer and its
/// events are merged in here — see `report(_:pressed:from:)`.
///
/// Each press becomes one `key <vk> pressed=1` wire line; each release becomes
/// `key <vk> pressed=0`.
struct KeyboardCapture: UIViewRepresentable {
    let bridge: BridgeClient
    let settings: AppSettings

    func makeUIView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.bridge = bridge
        v.settings = settings
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        Task { @MainActor in _ = v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.bridge = bridge
        view.settings = settings
    }
}

/// First-responder UIView that observes physical keyboard events and forwards
/// them to the bridge.
final class CaptureView: UIView {
    var bridge: BridgeClient?
    var settings: AppSettings?
    private var diagnostics: CaptureDiagnostics { .shared }

    /// Posting this reclaims first responder for the capture view after some
    /// other control (e.g. the IP-address field) has taken it. The view can't
    /// otherwise get focus back short of re-entering a window.
    static let reclaimFirstResponder = Notification.Name("KeyBridge.reclaimFirstResponder")

    /// Ask the active capture view to take first responder back. Call after
    /// dismissing a text field / settings sheet.
    @MainActor
    static func requestReclaim() {
        NotificationCenter.default.post(name: reclaimFirstResponder, object: nil)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReclaimRequest),
            name: Self.reclaimFirstResponder,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReclaimRequest),
            name: Self.reclaimFirstResponder,
            object: nil
        )
    }

    /// Main-key codes whose *release* we swallow because their press fired the
    /// toggle shortcut — so the up neither types nor leaks to the remote.
    private var swallowedKeyUps: Set<Int> = []
    /// Same idea for the HID-level source, which has no responder chain to be
    /// claimed out of and so must be told explicitly.
    private var swallowedGameControllerKeys: Set<Int> = []

    /// The two capture sources whose events are merged into one forwarded
    /// stream. See `report(_:pressed:from:)`.
    private enum KeySource: Hashable {
        case uiKit             // pressesBegan/Ended — misses Cmd chords
        case gameController    // HID layer — sees them, but may never fire
    }

    /// Which sources currently believe each key is down. A key is forwarded
    /// down when the *first* source reports it and up when the *last* one
    /// lets go, so overlapping reports collapse into one down/up pair.
    private var sourcesHoldingKey: [UIKeyboardHIDUsage: Set<KeySource>] = [:]

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        diagnostics.captureViewIsFirstResponder = isFirstResponder
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        diagnostics.captureViewIsFirstResponder = isFirstResponder
        return result
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            GameControllerCapture.shared.attachIfPossible()
            GameControllerCapture.shared.onKey = { [weak self] usage, pressed in
                self?.gameControllerKey(usage, pressed: pressed)
            }
            Task { @MainActor in _ = self.becomeFirstResponder() }
        } else {
            GameControllerCapture.shared.onKey = nil
        }
    }

    /// A key transition from the HID-level source. Gated on first responder so
    /// this path can never forward what the user is typing into one of the
    /// app's own text fields — GameController delivers app-wide, with no
    /// responder chain to fall out of.
    private func gameControllerKey(_ usage: UIKeyboardHIDUsage, pressed: Bool) {
        guard window != nil, isFirstResponder else { return }
        // The toggle shortcut is handled locally, so its key must not also
        // type on the PC — the UIKit path swallows it, and this source needs
        // the same instruction or the two would disagree.
        if swallowedGameControllerKeys.contains(usage.rawValue) {
            if !pressed { swallowedGameControllerKeys.remove(usage.rawValue) }
            return
        }
        report(usage, pressed: pressed, from: .gameController)
    }

    /// Reclaim first responder if we're still on screen. Guarded by `window`
    /// so a stale off-screen view doesn't steal focus.
    @objc private func handleReclaimRequest() {
        guard window != nil, !isFirstResponder else { return }
        Task { @MainActor in _ = self.becomeFirstResponder() }
    }

    // Keeping Tab/arrows away from the focus engine needs no special API:
    // presses reach the first responder's `pressesBegan` before the system
    // acts on them, and the focus engine only handles presses we pass up via
    // `super` (WWDC21 10260 — "call super consistently for presses that you
    // don't handle"). So: claim a press by returning without calling super;
    // anything unclaimed goes to super and behaves normally. (There is no
    // responder-level `wantsPriorityOverSystemBehavior`; the `UIKeyCommand`
    // property of that name is used further down, for Cmd chords only.)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Count every key-down before any handling — the diagnostics screen
        // uses this to distinguish "keys never arrive" from "keys arrive but
        // aren't forwarded".
        for press in presses {
            guard let key = press.key else { continue }
            diagnostics.pressesSeen += 1
            diagnostics.lastKey = HIDToVK.keyName(for: key)
        }
        // The toggle shortcut takes precedence over forwarding, and works
        // whether forwarding is currently on or off.
        if handleToggleShortcut(presses) { return }
        if !forward(presses, pressed: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if consumeSwallowedKeyUp(presses) { return }
        if !forward(presses, pressed: false) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if consumeSwallowedKeyUp(presses) { return }
        // A cancelled press is functionally a release as far as the slave is
        // concerned — emit the up so we don't strand a modifier.
        _ = forward(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }

    /// If a press completes the user's recorded toggle shortcut, flip forwarding
    /// and claim the event. Returns true when the shortcut fired.
    private func handleToggleShortcut(_ presses: Set<UIPress>) -> Bool {
        guard let bridge, let shortcut = settings?.toggleShortcut else { return false }
        for press in presses {
            guard let key = press.key, !HIDToVK.isModifier(key) else { continue }
            guard Int(key.keyCode.rawValue) == shortcut.keyCode else { continue }
            guard HIDToVK.modifiers(from: key.modifierFlags) == shortcut.modifiers else { continue }
            bridge.forwardingEnabled.toggle()
            swallowedKeyUps.insert(shortcut.keyCode)
            swallowedGameControllerKeys.insert(shortcut.keyCode)
            // Turning forwarding *off* flushes held keys in the bridge, and
            // turning it on can't have forwarded anything yet, so dropping the
            // merge state here can't strand a key on the remote.
            sourcesHoldingKey.removeValue(forKey: key.keyCode)
            return true
        }
        return false
    }

    /// Swallow the release of a key whose press fired the toggle shortcut.
    private func consumeSwallowedKeyUp(_ presses: Set<UIPress>) -> Bool {
        var consumed = false
        for press in presses {
            guard let key = press.key else { continue }
            if swallowedKeyUps.remove(Int(key.keyCode.rawValue)) != nil { consumed = true }
        }
        return consumed
    }

    /// Returns true if at least one press in the set was claimed (forwarded).
    /// When forwarding is off we always return false so the system can route
    /// the event normally (e.g. keep-alive scrolling, tab focus).
    @discardableResult
    private func forward(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var claimed = false
        for press in presses {
            guard let key = press.key else { continue }
            if report(key.keyCode, pressed: pressed, from: .uiKit) { claimed = true }
        }
        return claimed
    }

    /// Merge one key transition from one source into the forwarded stream.
    ///
    /// The two sources overlap: normal keys arrive on both, Cmd chords only
    /// from GameController, and on a device where `keyChangedHandler` never
    /// fires only from UIKit. Counting *holders* per key rather than trusting
    /// either source means whichever one sees the key carries it, and a key
    /// both of them see is still forwarded exactly once.
    ///
    /// Returns true when the key was ours to take — i.e. forwarding is on and
    /// the key maps to a Windows VK — regardless of whether this particular
    /// report was the one that emitted, so a de-duplicated press is still kept
    /// away from the system.
    @discardableResult
    private func report(_ usage: UIKeyboardHIDUsage, pressed: Bool, from source: KeySource) -> Bool {
        guard let bridge, bridge.forwardingEnabled else {
            sourcesHoldingKey.removeAll()
            return false
        }
        guard let vk = HIDToVK.vk(
            for: usage,
            leftOptionMapping: settings?.leftOptionMapping ?? .alt,
            rightOptionMapping: settings?.rightOptionMapping ?? .alt,
            leftCommandMapping: settings?.leftCommandMapping ?? .control,
            rightCommandMapping: settings?.rightCommandMapping ?? .control
        ) else {
            // Unmapped key: log so gaps are visible during testing, never
            // silently dropped.
            HIDToVK.logUnmapped(usage: usage)
            if pressed { diagnostics.unmappedSeen += 1 }
            return false
        }

        var holders = sourcesHoldingKey[usage] ?? []
        if pressed {
            let isFirstHolder = holders.isEmpty
            holders.insert(source)
            sourcesHoldingKey[usage] = holders
            guard isFirstHolder else { return true }
        } else {
            holders.remove(source)
            if holders.isEmpty {
                sourcesHoldingKey.removeValue(forKey: usage)
            } else {
                // Another source still holds it — don't release early.
                sourcesHoldingKey[usage] = holders
                return true
            }
        }

        bridge.sendKey(vk: vk, pressed: pressed)
        diagnostics.eventsForwarded += 1
        return true
    }

    /// The iOS 26 system layer steals Cmd chords (Cmd+B/I/U and friends)
    /// before `pressesBegan` — stripping the default main menu in
    /// `AppDelegate` was field-tested INSUFFICIENT (build 24, 2026-07-19) and
    /// so was claiming the chords back here (build 39, 2026-08-06), which is
    /// why the real carrier is now `GameControllerCapture`. This stays as the
    /// belt: `wantsPriorityOverSystemBehavior` is the documented way to take a
    /// key from the system, and when the HID source is dead it is the only
    /// thing that forwards a chord at all.
    ///
    /// The list is deliberately **not** gated on `forwardingEnabled`: UIKit
    /// collects a responder's key commands when the responder chain changes,
    /// not on every keystroke, so a list that is empty at the moment the view
    /// takes first responder can stay empty for the rest of the session — the
    /// most likely reason the build-28 version never fired. A constant list
    /// has nothing to invalidate. Claiming while forwarding is off costs
    /// nothing: the handler no-ops, and the app's own text fields are never
    /// below this view in the responder chain.
    ///
    /// Tap-only semantics: a claimed chord can't be held for key-repeat, which
    /// shortcuts don't need. (Caveat: a recorded toggle shortcut of the form
    /// Cmd+letter is shadowed by the claim.)
    override var keyCommands: [UIKeyCommand]? { Self.claimedChords }

    private static let claimedChords: [UIKeyCommand] = {
        let inputs = "abcdefghijklmnopqrstuvwxyz0123456789,.".map(String.init)
        let modifierSets: [UIKeyModifierFlags] = [.command, [.command, .shift]]
        return inputs.flatMap { input in
            modifierSets.map { flags in
                let command = UIKeyCommand(
                    input: input,
                    modifierFlags: flags,
                    action: #selector(CaptureView.handleClaimedChord(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }()

    @objc private func handleClaimedChord(_ sender: UIKeyCommand) {
        guard let bridge, bridge.forwardingEnabled,
              let character = sender.input?.first else { return }
        diagnostics.chordsClaimed += 1
        diagnostics.lastKey = "Chord \(sender.input?.uppercased() ?? "?")"
        // The HID source reports this key's real down and up, so a synthetic
        // pair here would type it twice.
        guard !GameControllerCapture.shared.isLive else { return }
        guard let key = USCharVK.key(for: character) else { return }
        bridge.sendKey(vk: key.vk, pressed: true)
        bridge.sendKey(vk: key.vk, pressed: false)
        diagnostics.eventsForwarded += 2
    }
}
