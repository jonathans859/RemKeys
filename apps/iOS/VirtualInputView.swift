import SwiftUI
import UIKit
import BridgeCore

/// On-screen key sender: build a key combination without a physical keyboard
/// and ship it to the PC. VoiceOver-first by design:
///
/// - The **direct-touch key pad** (`VirtualKeyPad`) IS the key interface:
///   one accessibility element whose raw touches bypass VoiceOver's gesture
///   round-trip entirely — drag to hear keys, lift to send, lift on a
///   modifier to toggle it, and **hold** any key to turn it on like a
///   modifier or (holding longer) press it down on the PC until you lift.
///   The earlier adjustable rows were retired in its
///   favor (field decision 2026-07-19). Layout (also field-specified,
///   revised 2026-08-06): the pad fills everything from the **inline**
///   title down — the bigger the zones, the better the muscle memory —
///   over a **single control row** at the bottom: text field, dismiss
///   keyboard, keep text, Send. The title is inline app-wide because the
///   large one sits low, costs the pad ~50 points, and overlapped it when
///   the keyboard came up. That row is a **bottom `safeAreaInset`**, the messenger input-bar
///   pattern, so it rises with the on-screen keyboard rather than hiding
///   under it. There is no separate "Will send" readout; it cost a whole
///   row, so what Send will deliver rides on Send's own VoiceOver hint, and
///   the pad already tints the modifiers it has toggled on.
///   The pad must stay OUTSIDE any scroll container (a scroll ancestor
///   cancels direct-touch drags; field-verified dead pad in build 25).
/// - Plain text is typed into a normal text field and sent through the
///   layout-independent unicode path, so it types verbatim on any PC layout;
///   when modifiers are held it switches to US-position keys, because
///   shortcuts match keys, not characters. The field normally clears after
///   Send; `virtualInputKeepText` pins it instead, for repeating one
///   keystroke (single-letter screen-reader navigation on the PC) without
///   retyping it between sends.
/// - A two-finger double tap (magic tap) sends from anywhere on this tab,
///   and the top-right info button explains the pad's current gesture set
///   (it follows the slider-mode and F13–F24 settings).
struct VirtualInputView: View {
    let bridge: BridgeClient
    let settings: AppSettings

    /// Posted by the root magic-tap handler while this tab is frontmost.
    static let sendRequested = Notification.Name("KeyBridge.virtualInputSendRequested")

    /// Everything currently latched on the pad, in the order it was latched:
    /// the modifier band's toggles and any key latched by holding it. All of
    /// it wraps whatever is sent next, which is why this is one list rather
    /// than a modifiers-only set.
    @State private var latched: [VirtualKey] = []
    /// The key the pad is holding *down* on the PC right now, plus the keys
    /// pressed around it, so the release lets go of exactly what it pressed.
    @State private var heldKey: VirtualKey?
    @State private var holdWrap: [VirtualKey] = []
    @State private var text = ""
    @State private var showInfo = false
    @FocusState private var textFieldFocused: Bool
    /// Compact height is a phone held sideways: there the on-screen keyboard
    /// takes almost the whole screen, and what is left cannot hold a pad.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Which arrangement the pad is actually showing, reported by the pad
    /// itself (it decides from its own bounds). Drives the layout button's
    /// value, so the button always names what is under the finger.
    @State private var showingKeyboardLayout = false

    var body: some View {
        NavigationStack {
            pad
                // Tighter than the standard margin on purpose: every point of
                // width widens the zones, and the pad is aimed at by feel.
                .padding(.horizontal, 8)
                .padding(.top, 4)
                // Messenger-style input bar: as a bottom safe-area inset the
                // row rides *up* with the on-screen keyboard instead of being
                // covered by it (a plain VStack let the keyboard bury Send,
                // keep text and dismiss — field-reported 2026-08-05). The pad
                // gives up the height, so every band stays reachable while
                // typing, and gets it back when the keyboard goes away.
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    controlRow
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
                .navigationTitle("Virtual Input")
                // Inline, not the default large title: the large one sits low,
                // eats ~50 points the pad wants, and — since the pad is not
                // scrollable content — it had nothing to collapse into, so it
                // overlapped the pad once the on-screen keyboard squeezed the
                // layout (field-reported 2026-08-06).
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        layoutButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        InfoButton { showInfo = true }
                    }
                }
                .sheet(isPresented: $showInfo) { infoSheet }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sendRequested)) { _ in
            send()
        }
        // Turning the phone sideways takes the text field away with the rest
        // of the typing controls; the focus state has to follow, or the field
        // comes back focused (and the keyboard with it) on the way back.
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue == .compact { textFieldFocused = false }
        }
    }

    /// Switches the pad between the two arrangements without a trip to
    /// Settings. It **pins** the choice — Settings keeps the third option,
    /// "Keyboard when sideways", which picks per orientation.
    ///
    /// Deliberately silent: the button's own accessibility value changes, and
    /// VoiceOver speaks that. A confirmation announcement posted alongside a
    /// value change on the focused element clips the speech (field-tested
    /// twice on this app).
    private var layoutButton: some View {
        Button {
            settings.virtualPadLayout = showingKeyboardLayout ? .bands : .keyboardAlways
        } label: {
            Image(systemName: showingKeyboardLayout ? "keyboard" : "rectangle.grid.1x2")
        }
        .accessibilityLabel("Pad layout")
        .accessibilityValue(showingKeyboardLayout ? "Keyboard" : "Key bands")
        .accessibilityHint("Switches the pad between the full PC keyboard and the key bands, and keeps that choice in both orientations. Settings can instead pick the keyboard automatically whenever the device is sideways.")
    }

    // MARK: Layout

    /// The one and only chrome row, under the pad: text field, dismiss
    /// keyboard, keep text, Send. Everything but the field is icon-sized so
    /// the field keeps usable width on a phone, and the row sits right above
    /// the on-screen keyboard when it comes up.
    ///
    /// **Sideways on a phone the typing controls are gone and only Send
    /// remains** (field-requested 2026-08-10). The pad there is a whole
    /// keyboard, so the text field earns nothing — and it was actively
    /// expensive, because focusing it raised the on-screen keyboard, which in
    /// that orientation covers everything but a strip. Removing the field is
    /// what makes it impossible to raise, so the pad keeps the full screen.
    /// Text typed upright survives and Send still delivers it (its hint spells
    /// out what it will send).
    private var controlRow: some View {
        HStack(spacing: 8) {
            if verticalSizeClass != .compact {
                typingControls
            }
            sendButton
                .frame(maxWidth: verticalSizeClass == .compact ? .infinity : nil)
        }
    }

    @ViewBuilder
    private var typingControls: some View {
        Group {
            TextField("Text to type", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityHint(settings.virtualInputKeepText
                    ? "Typed on the PC as part of the combination. With no modifiers it is sent as literal text, including umlauts. It is kept after sending, so Send repeats it."
                    : "Typed on the PC as part of the combination. With no modifiers it is sent as literal text, including umlauts.")
                // Emptying the field otherwise means holding Backspace on the
                // on-screen keyboard, character by character — and with "keep
                // text" on, the field is *meant* to stay filled, so clearing it
                // is a routine step, not an edge case. Offered only when there
                // is something to clear, so it never pads the action list of an
                // empty field. Silent on purpose: the value change is on the
                // focused element, and an announcement alongside it clips.
                .accessibilityActions {
                    if !text.isEmpty {
                        Button("Clear text") { text = "" }
                    }
                }

            Button {
                textFieldFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(.bordered)
            .disabled(!textFieldFocused)
            .accessibilityLabel("Dismiss keyboard")
            .accessibilityHint("Closes the on-screen keyboard")

            Toggle(isOn: Binding(
                get: { settings.virtualInputKeepText },
                set: { settings.virtualInputKeepText = $0 }
            )) {
                Image(systemName: settings.virtualInputKeepText ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            // The button style carries the state visually (tinted) and as the
            // "selected" trait; the explicit value guarantees VoiceOver speaks
            // it either way, since nothing else on screen shows it.
            .accessibilityLabel("Keep text after sending")
            .accessibilityValue(settings.virtualInputKeepText ? "On" : "Off")
            .accessibilityHint("On: Send leaves the text in the field, so pressing Send again repeats it. Off: the field is cleared after each send.")
        }
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Text("Send")
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hasSomethingToSend)
        // Replaces the old "Will send" readout: the combination is spoken
        // as the hint, so focusing Send tells you what it delivers without
        // a row of its own. Recomputed on every focus, so it never goes
        // stale as modifiers are toggled on the pad.
        .accessibilityHint(hasSomethingToSend
            ? "Sends \(comboDescription) to the Windows PC"
            : "Nothing selected to send")
    }

    /// The pad drives the latched keys (the modifiers it toggles, plus
    /// anything latched by holding) and tints the ones that are on; Send reads
    /// the same state for its hint. Pad sends always wrap in them.
    private var pad: some View {
        VirtualKeyPad(
            settings: settings,
            latchedKeys: latchedVKs,
            onSetLatched: { key, on in
                if on {
                    guard !latched.contains(where: { $0.vk == key.vk }) else { return }
                    latched.append(key)
                } else {
                    latched.removeAll { $0.vk == key.vk }
                }
            },
            onClearLatched: { latched.removeAll() },
            onSend: { key in sendImmediate(key) },
            onHoldBegin: { key in beginHold(key) },
            onHoldEnd: { key in endHold(key) },
            onLayoutChange: { showingKeyboardLayout = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Info sheet

    /// Explains the tab as it currently behaves — the text follows the
    /// slider-mode and F13–F24 settings so it never describes gestures the
    /// pad doesn't have right now.
    private var infoSheet: some View {
        InfoSheet(title: "Virtual Input") {
            Section("Key pad") {
                if settings.virtualPadSliderMode {
                    Text("The pad works as virtual sliders, one row at a time\(rowListSuffix). Touches on it act immediately — VoiceOver gestures are bypassed. Swipe left or right to choose a row, swipe up to move forward through its keys, down to move back. Tap once to send the current key. A harder vibration means you reached the end of a row. Two-finger swipe left resets the row.")
                } else {
                    Text("The pad is a fixed grid of key zones\(rowListSuffix). Touches on it act immediately — VoiceOver gestures are bypassed. Drag a finger to hear the key under it, with a small tick at each boundary, and lift to send that key at once. Lift on a modifier to turn it on or off. Landing a second finger cancels the drag, so nothing is sent.")
                }
                Text("Two-finger tap on the pad clears everything that is turned on. Sending is silent when it works; you only hear a message when something failed.")
            }
            Section("Layout") {
                switch settings.virtualPadLayout {
                case .bands:
                    Text("The pad shows key bands in both orientations. To get a full keyboard — letters, digits and punctuation included — change Key pad layout in Settings.")
                case .keyboardInLandscape:
                    Text("Held upright the pad shows key bands. Turn the device sideways and it becomes a whole PC keyboard instead, laid out as a real one: the bottom row is Ctrl, Windows, Alt, Space and the arrows, and going up the left edge you pass Shift, Caps Lock, Tab and Escape. A tall narrow screen has no room for that, which is why it appears only sideways.")
                case .keyboardAlways:
                    Text("The pad always shows a whole PC keyboard, laid out as a real one. Upright the keys are narrow — turn the device sideways and they get roughly the size of the keys on the on-screen keyboard.")
                }
                Text("The Pad layout button at the top left switches between the two straight away and keeps that choice in both orientations; its value tells you which one is on screen right now.")
                if settings.virtualPadLayout != .bands {
                    Text("The keyboard is named for a \(settings.pcKeyboardLayout.displayName) PC. Keys are always sent by position, so the PC's own layout decides the character — change PC keyboard layout in Settings if the letters you hear are not the ones that arrive.")
                    Text("Above the function keys sits a row for Insert, Home, Page Up, Delete, End, Page Down and Print Screen — the cluster that lives to the right of a real keyboard, unrolled so it fits.")
                }
                Text("Sideways on a phone the text field, the keep-text button and the dismiss-keyboard button are not shown, and only Send remains: the pad can type everything there, and keeping the field would mean the on-screen keyboard could cover the pad. Text you typed upright is kept and still goes out with Send.")
            }
            Section("Modifiers") {
                Text("Modifiers you turn on stay on and wrap every key you send, until you press them again, clear them, or press Send. To hear what is active, move to the Send button at the bottom: its hint spells out the whole combination it would deliver.")
                Text("Caps Lock counts as a modifier here because that is what it is on the PC when a screen reader is running — NVDA's desktop layout uses it as the screen-reader key. Turn it on, then send a key, and the PC gets Caps Lock plus that key. To flip the lock itself instead, hold the Caps Lock zone until it is pressed down, then lift.")
            }
            if settings.virtualPadRichHaptics {
                Section("What the vibrations tell you") {
                    Text("Moving onto a key always vibrates exactly once, and how hard it vibrates tells you the key's state: the usual light tick if it is off, a firmer knock if it is turned on, a hard knock if it is being held down on the PC. So you can feel what is already on while exploring, without waiting for it to be spoken.")
                    Text("This can be turned off under Key pad in Settings, leaving the same light tick for every key. The vibrations that mark holding a key down are separate and always on.")
                }
            }
            if settings.virtualPadHoldEnabled {
                Section("Holding a key") {
                    Text("Press and keep holding any key on the pad. After \(VirtualKeys.secondsDescription(settings.virtualPadLatchDelay)) it turns on and stays on, just like a modifier — a gentle vibration marks the moment. Keep holding for another \(VirtualKeys.secondsDescription(settings.virtualPadHoldDelay)) and the key is pressed down on the PC and stays down, with a firmer vibration: that is how you get key repeat, such as holding Backspace to delete a run of text or Down to keep scrolling.")
                    Text("The moment a key goes down on the PC it stops being turned on — being held down is the stronger state, not an extra one — so lifting releases it and leaves nothing selected. Lift while it is only turned on and it stays on for the keys you send next; press a key that is on to turn it off again. On the pad, a key that is on carries a light coloured background and the key currently down on the PC a stronger one. The timings and the spoken cues can be changed in Settings; the vibrations stay either way.")
                }
            }
            Section("Text") {
                Text("Text without modifiers is typed on the PC exactly as written, including umlauts, regardless of the PC's keyboard layout. With modifiers toggled, each character becomes its US-position key instead — shortcuts match keys, not characters — and characters without a US key are skipped and announced.")
                Text("To empty the field in one step, focus it with VoiceOver and use its Clear text action — swipe up or down to find it, then double tap.")
            }
            Section("Sending") {
                if settings.virtualInputKeepText {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the toggled modifiers plus the typed text. Keep text after sending is on, so the modifiers reset but the text stays in the field: pressing Send again repeats it. Clear the field yourself, or turn the button off, when you are done with that text.")
                } else {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the toggled modifiers plus the typed text, then resets both. To repeat the same text — a single letter for screen-reader navigation, say — turn on Keep text after sending, the button just left of Send.")
                }
                Text("Sending needs forwarding: if it is off, Send turns it on and asks you to send again once connected.")
            }
        }
    }

    /// Names the rows the pad *can* be showing. It can't know the orientation
    /// from here — the pad picks the arrangement from its own shape — so with
    /// the landscape setting both are named rather than guessed at.
    private var rowListSuffix: String {
        let extended = settings.virtualPadExtendedFKeys ? ", plus F13 to F24" : ""
        switch settings.virtualPadLayout {
        case .bands:
            return ": modifiers, editing, navigation, and F1 to F12\(extended)"
        case .keyboardAlways:
            return ", following a PC keyboard\(extended)"
        case .keyboardInLandscape:
            return ": upright, modifiers, editing, navigation, and F1 to F12; sideways, the rows of a PC keyboard\(extended)"
        }
    }

    // MARK: Combination state

    private var latchedVKs: Set<UInt16> { Set(latched.map(\.vk)) }

    /// What gets pressed around whatever is sent, in send order: the
    /// modifiers first, in the canonical order the pad shows them, then any
    /// other latched key in the order it was latched.
    private var wrapKeys: [VirtualKey] {
        let modifiers = VirtualKeys.modifiers.filter { latchedVKs.contains($0.vk) }
        let others = latched.filter { key in
            !VirtualKeys.modifiers.contains { $0.vk == key.vk }
        }
        return modifiers + others
    }

    private var hasSomethingToSend: Bool {
        !latched.isEmpty || !text.isEmpty
    }

    /// Human-readable spelling of exactly what Send will do, e.g.
    /// "Control + Shift + Escape" or "Control + “c”" or "“hello”".
    private var comboDescription: String {
        var parts = wrapKeys.map(\.spokenName)
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " + ")
    }

    // MARK: Sending

    /// Immediate path for the pad: exactly one key, wrapped in whatever is
    /// latched. Success is fully silent (the pad adds its own haptic) and
    /// nothing resets; latched keys only clear via Send, pressing them again,
    /// or the pad's clear gesture. A failure doesn't flip forwarding on — it
    /// just says the key was not sent.
    private func sendImmediate(_ key: VirtualKey) {
        guard bridge.forwardingEnabled else {
            announce("\(key.spokenName) not sent. Forwarding is off.")
            return
        }
        guard bridge.status.isConnected else {
            announce("\(key.spokenName) not sent. \(bridge.status.announcement)")
            return
        }
        let wrap = wrapKeys.map(\.vk)
        for vk in wrap { bridge.sendKey(vk: vk, pressed: true) }
        tap(key.vk)
        for vk in wrap.reversed() { bridge.sendKey(vk: vk, pressed: false) }
    }

    /// The pad's hold stage: the key goes *down* on the PC and stays down
    /// until the finger lifts, so the PC's own auto-repeat runs (hold
    /// Backspace to eat a word). The latched keys are pressed around it
    /// exactly as they wrap a tap — the held key itself is excluded, since a
    /// key can be latched and then held. Returns false when nothing was sent,
    /// so the pad doesn't claim a key is down that never went out.
    private func beginHold(_ key: VirtualKey) -> Bool {
        guard bridge.forwardingEnabled else {
            announce("\(key.spokenName) not held down. Forwarding is off.")
            return false
        }
        guard bridge.status.isConnected else {
            announce("\(key.spokenName) not held down. \(bridge.status.announcement)")
            return false
        }
        let wrap = wrapKeys.filter { $0.vk != key.vk }
        for modifier in wrap { bridge.sendKey(vk: modifier.vk, pressed: true) }
        holdWrap = wrap
        heldKey = key
        bridge.sendKey(vk: key.vk, pressed: true)
        return true
    }

    /// Let go of a held key and the wrap that went down with it. Releasing in
    /// reverse is the same discipline the tap path uses, so the PC never sees
    /// a modifier outlive the key it was modifying.
    private func endHold(_ key: VirtualKey) {
        guard heldKey?.vk == key.vk else { return }
        bridge.sendKey(vk: key.vk, pressed: false)
        for modifier in holdWrap.reversed() { bridge.sendKey(vk: modifier.vk, pressed: false) }
        heldKey = nil
        holdWrap = []
    }

    private func send() {
        guard hasSomethingToSend else {
            announce("Nothing selected to send")
            return
        }
        guard bridge.forwardingEnabled else {
            // Sending rides the same connection as forwarding. Turn it on
            // (which connects) and let the user re-trigger once connected —
            // queuing the combo for later would fire it unexpectedly.
            bridge.forwardingEnabled = true
            announce("Connecting to the PC. Send again once connected.")
            return
        }
        guard bridge.status.isConnected else {
            announce("Cannot send. \(bridge.status.announcement)")
            return
        }

        let sentDescription = comboDescription
        let wrap = wrapKeys.map(\.vk)
        for vk in wrap { bridge.sendKey(vk: vk, pressed: true) }

        var skippedCharacters = 0
        if !text.isEmpty {
            if wrap.isEmpty {
                // Plain text: unicode path, layout-proof, types verbatim.
                for scalar in text.unicodeScalars {
                    bridge.sendCharacter(scalar)
                }
            } else {
                // Shortcut semantics: US-position keys, like physical capture.
                for character in text {
                    guard let key = USCharVK.key(for: character) else {
                        skippedCharacters += 1
                        continue
                    }
                    let wrapInShift = key.shift && !latchedVKs.contains(VK.shift)
                    if wrapInShift { bridge.sendKey(vk: VK.shift, pressed: true) }
                    tap(key.vk)
                    if wrapInShift { bridge.sendKey(vk: VK.shift, pressed: false) }
                }
            }
        }

        for vk in wrap.reversed() { bridge.sendKey(vk: vk, pressed: false) }

        // Reset so the next combination starts clean: latched keys off, text
        // cleared — unless the text is pinned, in which case it stays put so
        // the same keystroke can be fired again with a single Send.
        latched.removeAll()
        if !settings.virtualInputKeepText { text = "" }

        var confirmation = "Sent \(sentDescription)"
        if skippedCharacters > 0 {
            confirmation += ". \(skippedCharacters) characters have no US key in a shortcut and were skipped"
        }
        announce(confirmation)
    }

    private func tap(_ vk: UInt16) {
        bridge.sendKey(vk: vk, pressed: true)
        bridge.sendKey(vk: vk, pressed: false)
    }

    /// Queued so it never clips speech VoiceOver is producing — see
    /// `postQueuedAnnouncement`.
    private func announce(_ message: String) {
        postQueuedAnnouncement(message)
    }
}
