import SwiftUI
import UIKit
import GameController
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

    /// Posting this makes the capture view forget which keys it believes are
    /// down. Sent when the app stops being able to observe key-ups (see
    /// `requestForgetHeldKeys()`).
    static let forgetHeldKeys = Notification.Name("KeyBridge.forgetHeldKeys")

    /// Tell the capture view its idea of what is held is no longer trustworthy.
    /// Call when the app leaves the active state: presses stop being delivered
    /// there, so a key that was down at that moment never reports its release
    /// and would otherwise be believed held forever — blocking the next press
    /// of that key, since a down is only forwarded by the *first* holder. The
    /// matching key-ups on the remote are `BridgeClient.releaseHeldKeys()`'s
    /// job; this only clears the local bookkeeping.
    @MainActor
    static func requestForgetHeldKeys() {
        NotificationCenter.default.post(name: forgetHeldKeys, object: nil)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        observeNotifications()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeNotifications()
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleReclaimRequest),
                           name: Self.reclaimFirstResponder, object: nil)
        center.addObserver(self, selector: #selector(handleForgetHeldKeysRequest),
                           name: Self.forgetHeldKeys, object: nil)
        // A keyboard unplugged or switched off mid-press never reports the
        // release, on either source.
        center.addObserver(self, selector: #selector(handleKeyboardDisconnect),
                           name: .GCKeyboardDidDisconnect, object: nil)
    }

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

    /// What the user is physically holding, per source, whether or not
    /// forwarding is on. `sourcesHoldingKey` is what the *remote* believes is
    /// held and is cleared whenever forwarding flips, so it can't answer
    /// "is Caps Lock down right now" (the flag is only the lock state) or
    /// "which modifiers are held" on the HID path (no flags at all).
    private var physicallyHeld: [UIKeyboardHIDUsage: Set<KeySource>] = [:]

    /// The press that fired the toggle shortcut, while it is still down: the
    /// sources that have reported it so far. Every down and up of that key
    /// from either source is swallowed until the last holder lets go, so the
    /// second source's copy of the same press neither toggles again nor
    /// types on the PC.
    private var shortcutPressHolders: [UIKeyboardHIDUsage: Set<KeySource>] = [:]

    /// When a claimed Cmd chord fired the shortcut (that path has no key-up,
    /// so it can't join `shortcutPressHolders`). If the HID source goes live
    /// on that very press and reports it a moment later, this stops it
    /// toggling a second time.
    private var lastChordToggle: (usage: UIKeyboardHIDUsage, at: TimeInterval)?

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        diagnostics.captureViewIsFirstResponder = isFirstResponder
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        diagnostics.captureViewIsFirstResponder = isFirstResponder
        // Presses now go to whoever took over, and the HID source is gated on
        // first responder, so no key-up for anything held reaches us.
        if !isFirstResponder { releaseAllHeldKeys() }
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
            // Leaving the window (e.g. switching tabs) ends both sources'
            // delivery here; let go of anything still down.
            GameControllerCapture.shared.onKey = nil
            releaseAllHeldKeys()
        }
    }

    /// A key transition from the HID-level source. Gated on first responder so
    /// this path can never forward what the user is typing into one of the
    /// app's own text fields — GameController delivers app-wide, with no
    /// responder chain to fall out of.
    private func gameControllerKey(_ usage: UIKeyboardHIDUsage, pressed: Bool) {
        guard window != nil, isFirstResponder else { return }
        trackPhysical(usage, pressed: pressed, from: .gameController)
        // Shortcut detection runs here too, before `report`: this source can
        // see the shortcut's key before `pressesBegan` does (and Cmd chords
        // only ever arrive here), and the key must not reach the PC first.
        if pressed {
            if claimShortcutDown(usage, modifiers: heldModifiers(), from: .gameController) { return }
        } else if consumeShortcutUp(usage, from: .gameController) {
            return
        }
        report(usage, pressed: pressed, from: .gameController)
    }

    /// Drop every key we think is down, and the pending swallows with them —
    /// their key-ups are not coming either.
    @objc private func handleForgetHeldKeysRequest() {
        sourcesHoldingKey.removeAll()
        physicallyHeld.removeAll()
        shortcutPressHolders.removeAll()
        lastChordToggle = nil
    }

    @objc private func handleKeyboardDisconnect() {
        releaseAllHeldKeys()
    }

    /// Capture just lost sight of the keyboard while keys may be down: send
    /// their key-ups to the remote (the agent repeats a held key until one
    /// arrives) and forget them locally (a stale holder blocks that key's
    /// next press). The remote flush only runs when this view holds
    /// something, so it can't release keys another sender — the Virtual Input
    /// tab — is holding through the same bridge.
    private func releaseAllHeldKeys() {
        if !sourcesHoldingKey.isEmpty { bridge?.releaseHeldKeys() }
        handleForgetHeldKeysRequest()
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
        for press in presses {
            guard let key = press.key else { continue }
            trackPhysical(key.keyCode, pressed: true, from: .uiKit)
        }
        // The toggle shortcut takes precedence over forwarding, and works
        // whether forwarding is currently on or off.
        let rest = presses.filter { press in
            guard let key = press.key else { return true }
            let modifiers = HIDToVK.modifiers(from: key.modifierFlags, capsLockHeld: isHeld(.keyboardCapsLock))
            return !claimShortcutDown(key.keyCode, modifiers: modifiers, from: .uiKit)
        }
        guard !rest.isEmpty else { return }
        if !forward(rest, pressed: true) {
            super.pressesBegan(rest, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = releasesNotSwallowed(presses)
        guard !rest.isEmpty else { return }
        if !forward(rest, pressed: false) {
            super.pressesEnded(rest, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = releasesNotSwallowed(presses)
        guard !rest.isEmpty else { return }
        // A cancelled press is functionally a release as far as the slave is
        // concerned — emit the up so we don't strand a modifier.
        _ = forward(rest, pressed: false)
        super.pressesCancelled(rest, with: event)
    }

    /// Record a physical transition from one source, independent of
    /// forwarding.
    private func trackPhysical(_ usage: UIKeyboardHIDUsage, pressed: Bool, from source: KeySource) {
        var holders = physicallyHeld[usage] ?? []
        if pressed { holders.insert(source) } else { holders.remove(source) }
        physicallyHeld[usage] = holders.isEmpty ? nil : holders
    }

    private func isHeld(_ usage: UIKeyboardHIDUsage) -> Bool {
        physicallyHeld[usage] != nil
    }

    /// The shortcut modifiers physically held right now, for the HID source,
    /// which delivers bare usages with no modifier flags.
    private func heldModifiers() -> Set<ShortcutModifier> {
        Set(physicallyHeld.keys.compactMap(HIDToVK.shortcutModifier(for:)))
    }

    /// One key-down from either source, checked against the toggle shortcut
    /// before it can be forwarded. Returns true when the press is the
    /// shortcut's — whether this report fired it or the other source's copy
    /// of the same press already had — so the caller must not forward it.
    private func claimShortcutDown(_ usage: UIKeyboardHIDUsage,
                                   modifiers: Set<ShortcutModifier>,
                                   from source: KeySource) -> Bool {
        if var holders = shortcutPressHolders[usage] {
            // The other source already fired the shortcut for this press.
            holders.insert(source)
            shortcutPressHolders[usage] = holders
            return true
        }
        guard bridge != nil, let shortcut = settings?.toggleShortcut,
              Int(usage.rawValue) == shortcut.keyCode,
              modifiers == shortcut.modifiers else { return false }
        shortcutPressHolders[usage] = [source]
        if let chord = lastChordToggle, chord.usage == usage,
           ProcessInfo.processInfo.systemUptime - chord.at < 0.5 {
            // A claimed Cmd chord already fired it for this press.
            lastChordToggle = nil
            return true
        }
        fireToggle(usage)
        return true
    }

    /// One key-up from either source. Returns true when it belongs to the
    /// press that fired the shortcut, and so must be swallowed.
    private func consumeShortcutUp(_ usage: UIKeyboardHIDUsage, from source: KeySource) -> Bool {
        guard var holders = shortcutPressHolders[usage] else { return false }
        holders.remove(source)
        shortcutPressHolders[usage] = holders.isEmpty ? nil : holders
        return true
    }

    /// Track the releases and drop those that belong to the shortcut's press.
    private func releasesNotSwallowed(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { press in
            guard let key = press.key else { return true }
            trackPhysical(key.keyCode, pressed: false, from: .uiKit)
            return !consumeShortcutUp(key.keyCode, from: .uiKit)
        }
    }

    private func fireToggle(_ usage: UIKeyboardHIDUsage) {
        guard let bridge else { return }
        bridge.forwardingEnabled.toggle()
        // Turning forwarding *off* flushes held keys in the bridge, and
        // turning it on can't have forwarded anything yet, so dropping the
        // merge state here can't strand a key on the remote.
        sourcesHoldingKey.removeValue(forKey: usage)
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
    /// shortcuts don't need. A claimed chord never reaches `pressesBegan`, so
    /// a recorded toggle shortcut of the form Cmd+letter is checked in the
    /// handler — and on the HID path, which does see the chord's real keys.
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
        if claimedChordIsToggleShortcut(sender) { return }
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

    /// Whether a claimed chord is the recorded toggle shortcut, firing it if
    /// nothing else already has. Returns true when the chord is the
    /// shortcut, so it must not be typed on the PC either way.
    private func claimedChordIsToggleShortcut(_ sender: UIKeyCommand) -> Bool {
        guard bridge != nil, let shortcut = settings?.toggleShortcut,
              let character = sender.input?.first,
              let usage = HIDToVK.usage(forClaimedInput: character),
              Int(usage.rawValue) == shortcut.keyCode,
              HIDToVK.modifiers(from: sender.modifierFlags,
                                capsLockHeld: isHeld(.keyboardCapsLock)) == shortcut.modifiers
        else { return false }
        // The HID source reports the chord's real keys and detects the
        // shortcut itself; firing here as well would toggle twice. Same if
        // `pressesBegan` somehow saw this press and already fired.
        guard !GameControllerCapture.shared.isLive,
              shortcutPressHolders[usage] == nil else { return true }
        fireToggle(usage)
        lastChordToggle = (usage, ProcessInfo.processInfo.systemUptime)
        return true
    }
}
