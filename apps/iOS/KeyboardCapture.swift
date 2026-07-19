import SwiftUI
import UIKit
import BridgeCore

/// Hosts a `UIView` that becomes first responder so attached Bluetooth / USB-C
/// keyboard events flow through `pressesBegan`/`pressesEnded`. UIKit is the
/// only path that exposes raw HID press events; SwiftUI's keyboard shortcuts
/// abstract too aggressively (no key-up, no individual modifiers).
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
            Task { @MainActor in _ = self.becomeFirstResponder() }
        }
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
    // don't handle"). `wantsPriorityOverSystemBehavior` exists only on
    // `UIKeyCommand`, a path we deliberately don't use (no key-up events).
    // So: claim a press by returning without calling super; anything
    // unclaimed goes to super and behaves normally.

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
        guard let bridge, bridge.forwardingEnabled else { return false }
        var claimed = false
        for press in presses {
            guard let key = press.key else { continue }
            guard let vk = HIDToVK.vk(
                for: key,
                leftOptionMapping: settings?.leftOptionMapping ?? .alt,
                rightOptionMapping: settings?.rightOptionMapping ?? .alt,
                leftCommandMapping: settings?.leftCommandMapping ?? .control,
                rightCommandMapping: settings?.rightCommandMapping ?? .control
            ) else {
                // Unmapped key: log so gaps are visible during testing, never
                // silently dropped.
                HIDToVK.logUnmapped(key)
                if pressed { diagnostics.unmappedSeen += 1 }
                continue
            }
            bridge.sendKey(vk: vk, pressed: pressed)
            diagnostics.eventsForwarded += 1
            claimed = true
        }
        return claimed
    }

    /// The iOS 26 system layer steals Cmd chords (Cmd+B/I/U and friends)
    /// before `pressesBegan` — and stripping the default main menu in
    /// `AppDelegate` was field-tested INSUFFICIENT (build 24, 2026-07-19):
    /// B still never arrived. So while forwarding, the capture view claims
    /// every Cmd and Cmd+Shift letter/digit chord itself via
    /// `wantsPriorityOverSystemBehavior` — the documented way to take a key
    /// from the system — and forwards a synthetic down+up for the main key
    /// (the held modifiers were already forwarded as their own presses, so
    /// the remote still sees the full chord). Tap-only semantics: a claimed
    /// chord can't be held for key-repeat, which shortcuts don't need.
    /// While forwarding is off the claim list is empty and the app behaves
    /// normally. (Caveat: a recorded toggle shortcut of the form Cmd+letter
    /// would be shadowed by the claim while forwarding is on.)
    override var keyCommands: [UIKeyCommand]? {
        guard bridge?.forwardingEnabled == true else { return [] }
        return Self.claimedChords
    }

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
              let character = sender.input?.first,
              let key = USCharVK.key(for: character) else { return }
        bridge.sendKey(vk: key.vk, pressed: true)
        bridge.sendKey(vk: key.vk, pressed: false)
        diagnostics.eventsForwarded += 2
        diagnostics.lastKey = "Chord \(sender.input?.uppercased() ?? "?")"
    }
}
