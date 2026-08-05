import SwiftUI
import UIKit
import BridgeCore

/// On-screen key sender: build a key combination without a physical keyboard
/// and ship it to the PC. VoiceOver-first by design:
///
/// - The **direct-touch key pad** (`VirtualKeyPad`) IS the key interface:
///   one accessibility element whose raw touches bypass VoiceOver's gesture
///   round-trip entirely — drag to hear keys, lift to send, lift on a
///   modifier to toggle it. The earlier adjustable rows were retired in its
///   favor (field decision 2026-07-19). Layout (also field-specified): the
///   "Will send" readout + Send on top, then the text field with a compact
///   dismiss-keyboard button beside it, and the pad filling the entire rest
///   of the screen — the bigger the zones, the better the muscle memory.
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

    @State private var selectedModifiers: Set<UInt16> = []
    @State private var text = ""
    @State private var showInfo = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                sendRow
                textRow
                pad
            }
            .padding(.horizontal)
            .navigationTitle("Virtual Input")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    InfoButton { showInfo = true }
                }
            }
            .sheet(isPresented: $showInfo) { infoSheet }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sendRequested)) { _ in
            send()
        }
    }

    // MARK: Layout

    /// Top row: what Send will deliver, and Send itself to the right.
    private var sendRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Will send")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(comboDescription)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Will send")
            .accessibilityValue(comboDescription)
            .accessibilityAddTraits(.updatesFrequently)

            Button {
                send()
            } label: {
                Text("Send")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasSomethingToSend)
            .accessibilityHint("Sends the combination to the Windows PC")
        }
    }

    /// Text entry, then the keep-text toggle and a compact dismiss-keyboard
    /// button. Keep text sits here rather than in Settings because it is
    /// flipped several times in a session (field decision 2026-08-05).
    private var textRow: some View {
        HStack(spacing: 8) {
            TextField("Text to type", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityHint(settings.virtualInputKeepText
                    ? "Typed on the PC as part of the combination. With no modifiers it is sent as literal text, including umlauts. It is kept after sending, so Send repeats it."
                    : "Typed on the PC as part of the combination. With no modifiers it is sent as literal text, including umlauts.")

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

            Button {
                textFieldFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(.bordered)
            .disabled(!textFieldFocused)
            .accessibilityLabel("Dismiss keyboard")
            .accessibilityHint("Closes the on-screen keyboard")
        }
    }

    /// The pad owns the toggled modifiers (toggle zones on its top band);
    /// the "Will send" readout and Send read the same state. Pad sends
    /// always wrap in the toggled modifiers.
    private var pad: some View {
        VirtualKeyPad(
            settings: settings,
            selectedModifiers: selectedModifiers,
            onToggleModifier: { modifier in
                if selectedModifiers.contains(modifier.vk) {
                    selectedModifiers.remove(modifier.vk)
                } else {
                    selectedModifiers.insert(modifier.vk)
                }
            },
            onClearModifiers: { selectedModifiers.removeAll() },
            onSend: { key in sendImmediate(key) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: Info sheet

    /// Explains the tab as it currently behaves — the text follows the
    /// slider-mode and F13–F24 settings so it never describes gestures the
    /// pad doesn't have right now.
    private var infoSheet: some View {
        InfoSheet(title: "Virtual Input") {
            Section("Key pad") {
                if settings.virtualPadSliderMode {
                    Text("The pad works as virtual sliders, one row per key group\(bandListSuffix). Touches on it act immediately — VoiceOver gestures are bypassed. Swipe left or right to choose a row, swipe up to move forward through its keys, down to move back. Tap once to send the current key. A harder vibration means you reached the end of a row. Two-finger swipe left resets the row.")
                } else {
                    Text("The pad is a fixed grid of key zones\(bandListSuffix). Touches on it act immediately — VoiceOver gestures are bypassed. Drag a finger to hear the key under it, with a small tick at each boundary, and lift to send that key at once. Lift on a modifier to turn it on or off. Landing a second finger cancels the drag, so nothing is sent.")
                }
                Text("Two-finger tap on the pad clears all toggled modifiers. Sending is silent when it works; you only hear a message when something failed.")
            }
            Section("Modifiers") {
                Text("Modifiers you toggle on the pad stay on and wrap every key you send, until you clear them or press Send. The Will send line always shows what is active.")
            }
            Section("Text") {
                Text("Text without modifiers is typed on the PC exactly as written, including umlauts, regardless of the PC's keyboard layout. With modifiers toggled, each character becomes its US-position key instead — shortcuts match keys, not characters — and characters without a US key are skipped and announced.")
            }
            Section("Sending") {
                if settings.virtualInputKeepText {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the toggled modifiers plus the typed text. Keep text after sending is on, so the modifiers reset but the text stays in the field: pressing Send again repeats it. Clear the field yourself, or turn the button off, when you are done with that text.")
                } else {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the toggled modifiers plus the typed text, then resets both. To repeat the same text — a single letter for screen-reader navigation, say — turn on Keep text after sending, the button between the text field and Dismiss keyboard.")
                }
                Text("Sending needs forwarding: if it is off, Send turns it on and asks you to send again once connected.")
            }
        }
    }

    /// ", from modifiers at the top to function keys at the bottom" — with
    /// the extended band mentioned only when it is actually shown.
    private var bandListSuffix: String {
        settings.virtualPadExtendedFKeys
            ? ": modifiers, editing, navigation, F1 to F12, and F13 to F24"
            : ": modifiers, editing, navigation, and F1 to F12"
    }

    // MARK: Combination state

    private var orderedModifiers: [VirtualKey] {
        VirtualKeys.modifiers.filter { selectedModifiers.contains($0.vk) }
    }

    private var hasSomethingToSend: Bool {
        !selectedModifiers.isEmpty || !text.isEmpty
    }

    /// Human-readable spelling of exactly what Send will do, e.g.
    /// "Control + Shift + Escape" or "Control + “c”" or "“hello”".
    private var comboDescription: String {
        var parts = orderedModifiers.map(\.name)
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " + ")
    }

    // MARK: Sending

    /// Immediate path for the pad: exactly one key, wrapped in the toggled
    /// modifiers. Success is fully silent (the pad adds its own haptic) and
    /// nothing resets; modifiers only clear via Send or the pad's clear
    /// gesture. A failure doesn't flip forwarding on — it just says the key
    /// was not sent.
    private func sendImmediate(_ key: VirtualKey) {
        guard bridge.forwardingEnabled else {
            announce("\(key.name) not sent. Forwarding is off.")
            return
        }
        guard bridge.status.isConnected else {
            announce("\(key.name) not sent. \(bridge.status.announcement)")
            return
        }
        let modifiers = orderedModifiers.map(\.vk)
        for vk in modifiers { bridge.sendKey(vk: vk, pressed: true) }
        tap(key.vk)
        for vk in modifiers.reversed() { bridge.sendKey(vk: vk, pressed: false) }
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
        let modifiers = orderedModifiers.map(\.vk)
        for vk in modifiers { bridge.sendKey(vk: vk, pressed: true) }

        var skippedCharacters = 0
        if !text.isEmpty {
            if modifiers.isEmpty {
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
                    let wrapInShift = key.shift && !selectedModifiers.contains(VK.shift)
                    if wrapInShift { bridge.sendKey(vk: VK.shift, pressed: true) }
                    tap(key.vk)
                    if wrapInShift { bridge.sendKey(vk: VK.shift, pressed: false) }
                }
            }
        }

        for vk in modifiers.reversed() { bridge.sendKey(vk: vk, pressed: false) }

        // Reset so the next combination starts clean: modifiers off, text
        // cleared — unless the text is pinned, in which case it stays put so
        // the same keystroke can be fired again with a single Send.
        selectedModifiers.removeAll()
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
