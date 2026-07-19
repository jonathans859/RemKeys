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
///   favor (field decision 2026-07-19: with the pad working, the rows only
///   cost screen space) — the pad now takes that room, which also makes its
///   zones bigger. The pad is pinned OUTSIDE the Form below it: a
///   scroll-view ancestor cancels direct-touch drags (field-verified dead
///   pad in build 25).
/// - Plain text is typed into a normal text field and sent through the
///   layout-independent unicode path, so it types verbatim on any PC layout;
///   when modifiers are held it switches to US-position keys, because
///   shortcuts match keys, not characters.
/// - The combination about to be sent is spelled out above the Send button,
///   and a two-finger double tap (magic tap) sends from anywhere on this tab.
struct VirtualInputView: View {
    let bridge: BridgeClient
    let settings: AppSettings

    /// Posted by the root magic-tap handler while this tab is frontmost.
    static let sendRequested = Notification.Name("KeyBridge.virtualInputSendRequested")

    @State private var selectedModifiers: Set<UInt16> = []
    @State private var text = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pad
                Form {
                    textSection
                    sendSection
                }
            }
            .navigationTitle("Virtual Input")
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sendRequested)) { _ in
            send()
        }
    }

    // MARK: Sections

    /// The pad owns the toggled modifiers (toggle zones on its top band);
    /// the "Will send" readout and Send read the same state. Pad sends
    /// always wrap in the toggled modifiers — the modifier band makes that
    /// intent explicit.
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
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var textSection: some View {
        Section {
            TextField("Text to type", text: $text, axis: .vertical)
                .focused($textFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityHint("Typed on the PC as part of the combination. With no modifiers it is sent as literal text, including umlauts.")
            Button("Dismiss keyboard") {
                textFieldFocused = false
            }
            .disabled(!textFieldFocused)
            .accessibilityHint("Closes the on-screen keyboard")
        } header: {
            Text("Text").accessibilityAddTraits(.isHeader)
        }
    }

    private var sendSection: some View {
        Section {
            LabeledContent("Will send") {
                Text(comboDescription)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            Button {
                send()
            } label: {
                Text("Send")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasSomethingToSend)
            .accessibilityHint("Sends the combination to the Windows PC")
        } footer: {
            Text("Lifting on a pad key sends it right away, wrapped in the toggled modifiers. Send (or a two-finger double tap on this tab) delivers the modifiers plus the typed text, then resets both.")
        }
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
        // cleared.
        selectedModifiers.removeAll()
        text = ""

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
