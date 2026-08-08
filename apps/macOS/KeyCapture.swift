// `@preconcurrency`: CGEvent isn't `Sendable`, but the event-tap callback is
// invoked synchronously on the main run loop, so handing the event to a
// `MainActor` closure never actually crosses a thread boundary.
@preconcurrency import CoreGraphics
import Foundation
import IOKit.hid
import Observation
import BridgeCore

/// System-wide low-level keyboard hook.
///
/// Two cooperating mechanisms, both deliberately lower-level than anything
/// SwiftUI or AppKit exposes:
///
/// 1. A **`CGEventTap`** at `.cghidEventTap` sees every keyDown / keyUp /
///    flagsChanged before any application *or* the system (so ⌘Q, ⌘Tab,
///    ⌘Space are ours to forward, not the local Mac's). With `.defaultTap`
///    we can also *swallow* events — while forwarding is on, keystrokes go
///    only to the Windows PC and never act on this Mac.
///
/// 2. An **`IOHIDManager`** reads Caps Lock straight off the HID layer. The
///    normal event API only reports Caps Lock as a *toggle* (one event per
///    press, no release). The HID report gives a clean down(1) / up(0) per
///    physical press, so Caps Lock works as a real held modifier.
///
/// Forwarding is toggled from the menu button. Optionally, the user can record
/// a **global shortcut** (`settings.toggleShortcut`) that flips forwarding from
/// any app; there is no hard-wired default. Per the UTM pattern, the tap is
/// installed once and the forwarding decision is gated behind a boolean rather
/// than torn down and rebuilt on every toggle.
///
/// Callbacks are scheduled on the main run loop, so the C trampolines below
/// can hop straight onto the main actor with `assumeIsolated`.
@MainActor
@Observable
final class KeyCapture {
    enum State: Equatable {
        case stopped
        case needsAccessibility
        case needsInputMonitoring
        case running
    }

    private(set) var state: State = .stopped

    /// True while waiting to capture a chord for the toggle-shortcut recorder.
    /// Observable so the settings UI can reflect "Press keys…".
    private(set) var isRecording = false
    /// Delivered the chord the user pressed while recording. Cleared on capture
    /// or cancel. Not observed — closures aren't meaningfully observable.
    @ObservationIgnored private var recordingHandler: (@MainActor (ToggleShortcut) -> Void)?

    private let bridge: BridgeClient
    private let settings: AppSettings

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var hidManager: IOHIDManager?

    /// Physical Caps Lock state, from the HID hook (not the toggle LED).
    @ObservationIgnored private var capsHeld = false
    /// Physical down-state of the non-Caps modifiers. Only consulted for
    /// modifier key codes missing from `modifierFlagBits`; known ones read
    /// their direction straight out of the event (see `handleFlagsChanged`).
    @ObservationIgnored private var downModifiers: Set<CGKeyCode> = []
    /// Key codes whose *down* we have forwarded and not yet released. Guards
    /// the matching up: a key the user was already holding when forwarding
    /// came on (the toggle chord's own modifiers, above all) must not send the
    /// remote an up for a down it never received.
    @ObservationIgnored private var forwardedDown: Set<CGKeyCode> = []

    init(bridge: BridgeClient, settings: AppSettings) {
        self.bridge = bridge
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Install both hooks. If a permission is missing, sets `state` to the
    /// matching `.needs…` case and fires the system prompt instead.
    func start() {
        stop()

        guard Permissions.hasAccessibility else {
            state = .needsAccessibility
            Permissions.requestAccessibility()
            return
        }
        guard Permissions.hasInputMonitoring else {
            state = .needsInputMonitoring
            Permissions.requestInputMonitoring()
            return
        }
        guard installEventTap() else {
            // Accessibility flipped on but the tap still failed — usually a
            // just-granted permission that needs another beat.
            state = .needsAccessibility
            return
        }
        installHIDManager()
        state = .running
    }

    /// Re-run `start()` — used by the permissions banner's "Recheck" button
    /// after the user grants access in System Settings.
    func recheck() { start() }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil

        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(
                hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil

        capsHeld = false
        downModifiers.removeAll()
        forwardedDown.removeAll()
        if state == .running { state = .stopped }
    }

    // MARK: Forwarding toggle

    /// Flip forwarding on/off. Called by the hotkey, the menu command, and the
    /// on-screen toggle.
    ///
    /// Only what we believe the *remote* holds is reset: `BridgeClient` emits
    /// an up for every still-held key when forwarding goes off, and turning it
    /// on can't have forwarded anything yet, so after either transition the
    /// remote holds nothing. The **physical** state (`downModifiers`,
    /// `capsHeld`) is deliberately left alone — it describes the user's
    /// fingers, not the remote, and clearing it mid-chord used to make the
    /// release of the toggle chord's own modifiers read as a press.
    func toggleForwarding() {
        bridge.forwardingEnabled.toggle()
        forwardedDown.removeAll()
    }

    /// Send one key transition, keeping `forwardedDown` in step. A release is
    /// dropped unless we forwarded the matching press, so the toggle chord's
    /// modifiers — held across the moment forwarding came on — don't reach the
    /// PC as a bare key-up.
    private func forward(keyCode: CGKeyCode, vk: UInt16, pressed: Bool) {
        if pressed {
            guard bridge.forwardingEnabled else { return }
            forwardedDown.insert(keyCode)
        } else {
            guard forwardedDown.remove(keyCode) != nil else { return }
        }
        bridge.sendKey(vk: vk, pressed: pressed)
    }

    // MARK: Shortcut recording

    /// Arm the recorder: the next main-key press (with whatever modifiers are
    /// held) is captured and handed back, and is swallowed so it neither toggles
    /// forwarding nor triggers its normal action. Escape cancels.
    func beginRecording(onCapture: @escaping @MainActor (ToggleShortcut) -> Void) {
        recordingHandler = onCapture
        isRecording = true
    }

    func cancelRecording() {
        recordingHandler = nil
        isRecording = false
    }

    // MARK: Install helpers

    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyCaptureEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func installHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match physical keyboards…
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        // …and, within them, only the Caps Lock element.
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager, keyCaptureHIDValueCallback, Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    // MARK: Event handling (called from the C trampolines, on the main actor)

    /// Returns the event to let it through, or `nil` to swallow it.
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or interrupted — re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Recording the toggle shortcut: capture the next main-key press (Escape
        // cancels) and swallow everything meanwhile so nothing acts or leaks.
        if isRecording {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if keyCode == MacKeyCode.escape {
                    cancelRecording()
                } else {
                    let shortcut = ToggleShortcut(
                        keyCode: Int(keyCode),
                        modifiers: currentModifiers(event),
                        keyName: MacKeyName.name(forKeyCode: keyCode, event: event)
                    )
                    let handler = recordingHandler
                    cancelRecording()
                    handler?(shortcut)
                }
            }
            return nil
        }

        // The user's recorded toggle shortcut flips forwarding from anywhere.
        // Swallow both transitions so the chord neither performs its normal
        // action (e.g. F11 → Mission Control) nor leaks to the remote.
        if let shortcut = settings.toggleShortcut,
           Int(keyCode) == shortcut.keyCode,
           currentModifiers(event) == shortcut.modifiers {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat {
                toggleForwarding()
            }
            return nil
        }

        switch type {
        case .keyDown, .keyUp:
            guard bridge.forwardingEnabled else { return Unmanaged.passUnretained(event) }
            if let vk = MacKeyVK.vk(
                forKeyCode: keyCode,
                isISOKeyboard: MacKeyboardLayout.isISO(event),
                leftOptionMapping: settings.leftOptionMapping,
                rightOptionMapping: settings.rightOptionMapping,
                leftCommandMapping: settings.leftCommandMapping,
                rightCommandMapping: settings.rightCommandMapping
            ) {
                forward(keyCode: keyCode, vk: vk, pressed: type == .keyDown)
            }
            // Swallow everything while forwarding — even unmapped keys — so
            // the local Mac never reacts to a keystroke meant for the slave.
            return nil

        case .flagsChanged:
            return handleFlagsChanged(keyCode: keyCode, event: event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Caps Lock comes through the HID hook with a real direction. Here we
        // only suppress the synthetic toggle so it can't flip local Caps
        // state while forwarding.
        if keyCode == MacKeyCode.capsLock {
            return bridge.forwardingEnabled ? nil : Unmanaged.passUnretained(event)
        }

        // Direction comes from the event's own flags whenever we know this
        // key's bit — self-correcting, so a transition the tap never saw (the
        // swallowed toggle chord, a re-armed tap, a modifier already held at
        // launch) can't invert this key from then on. Toggling a set is only
        // the fallback for a modifier key code we have no bit for.
        let pressed: Bool
        if let flagState = MacModifierFlag.isPressed(keyCode: keyCode, flags: event.flags) {
            pressed = flagState
            if pressed { downModifiers.insert(keyCode) } else { downModifiers.remove(keyCode) }
        } else if downModifiers.contains(keyCode) {
            downModifiers.remove(keyCode)
            pressed = false
        } else {
            downModifiers.insert(keyCode)
            pressed = true
        }

        guard bridge.forwardingEnabled else { return Unmanaged.passUnretained(event) }
        if let vk = MacKeyVK.vk(
            forKeyCode: keyCode,
            // Modifiers are the same key code on both layouts; passed for
            // completeness only.
            isISOKeyboard: MacKeyboardLayout.isISO(event),
            leftOptionMapping: settings.leftOptionMapping,
            rightOptionMapping: settings.rightOptionMapping,
            leftCommandMapping: settings.leftCommandMapping,
            rightCommandMapping: settings.rightCommandMapping
        ) {
            forward(keyCode: keyCode, vk: vk, pressed: pressed)
        }
        return nil
    }

    /// Raw Caps Lock press/release straight from the HID report. `forward`
    /// supplies the guard that matters here: a Caps Lock press that merely
    /// armed the toggle chord was never sent, so its release isn't either.
    func handleCapsLock(pressed: Bool) {
        capsHeld = pressed
        forward(keyCode: MacKeyCode.capsLock, vk: VK.capital, pressed: pressed)
    }

    /// The generic modifier set currently held. Caps Lock comes from the HID
    /// hook (a real physical hold); the rest from the event's live flags.
    private func currentModifiers(_ event: CGEvent) -> Set<ShortcutModifier> {
        var mods: Set<ShortcutModifier> = []
        if capsHeld { mods.insert(.capsLock) }
        let flags = event.flags
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskCommand) { mods.insert(.command) }
        return mods
    }
}

// MARK: - C callback trampolines

/// `CGEventTapCallBack`. Runs on the main run loop, so we can assume the main
/// actor and call straight into `KeyCapture`.
private func keyCaptureEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        capture.handleEvent(type: type, event: event)
    }
}

/// `IOHIDValueCallback` for the matched Caps Lock element.
private func keyCaptureHIDValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let capture = Unmanaged<KeyCapture>.fromOpaque(context).takeUnretainedValue()
    let pressed = IOHIDValueGetIntegerValue(value) != 0
    MainActor.assumeIsolated {
        capture.handleCapsLock(pressed: pressed)
    }
}
