import SwiftUI
import UIKit
import BridgeCore

/// On-screen key sender: build a key combination without a physical keyboard
/// and ship it to the PC in one tap. VoiceOver-first by design:
///
/// - Each key row is ONE adjustable element ("slider") whose position IS the
///   selection: option 0 is "None", swiping up/down lands on the key the row
///   will send — no double tap involved (activation is slow under VoiceOver,
///   field-reported). Rows reset to None after each send. The modifiers row
///   is the exception: it keeps browse + double-tap-to-toggle because several
///   modifiers can be on at once, which a single slider value can't express.
///   Left/right swipes jump between rows — 8 stops for the whole screen.
///   The visible buttons remain for touch users only.
/// - Plain text is typed into a normal text field and sent through the
///   layout-independent unicode path, so it types verbatim on any PC layout;
///   when modifiers are held it switches to US-position keys, because
///   shortcuts match keys, not characters.
/// - The combination about to be sent is spelled out above the Send button,
///   and a two-finger double tap (magic tap) sends from anywhere on this tab.
struct VirtualInputView: View {
    let bridge: BridgeClient

    /// Posted by the root magic-tap handler while this tab is frontmost.
    static let sendRequested = Notification.Name("KeyBridge.virtualInputSendRequested")

    @State private var selectedModifiers: Set<UInt16> = []
    @State private var text = ""
    @FocusState private var textFieldFocused: Bool

    // The modifiers row's VoiceOver browse cursor (browse + double-tap model,
    // multi-select).
    @State private var modifierBrowseIndex = 0
    // Per-category slider position, 0 = "None", i = category.keys[i - 1].
    // The position is the selection — what each row shows is what Send sends.
    @State private var keySelectionIndices: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            Form {
                modifierSection
                ForEach(VirtualKeys.categories) { category in
                    keySection(category)
                }
                textSection
                sendSection
            }
            .navigationTitle("Virtual Input")
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sendRequested)) { _ in
            send()
        }
    }

    // MARK: Sections

    private var modifierSection: some View {
        Section {
            keyRow {
                ForEach(VirtualKeys.modifiers) { modifier in
                    Toggle(modifier.name, isOn: Binding(
                        get: { selectedModifiers.contains(modifier.vk) },
                        set: { on in
                            if on { selectedModifiers.insert(modifier.vk) }
                            else { selectedModifiers.remove(modifier.vk) }
                        }
                    ))
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                }
            }
            // One adjustable element for the whole row: swipe up/down browses
            // the modifiers, double tap toggles the current one. The visible
            // toggles stay for touch; VoiceOver never sees them individually.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Modifiers")
            .accessibilityValue(modifierBrowseValue)
            .accessibilityHint("Swipe up or down to move through the modifiers, double tap to turn the current one on or off. Several can be on at once.")
            .accessibilityAdjustableAction { direction in
                modifierBrowseIndex = adjusted(modifierBrowseIndex, direction, count: VirtualKeys.modifiers.count)
            }
            .accessibilityAction {
                // No custom announcement here: the value flips to
                // "<name>, on/off" and VoiceOver speaks that on its own —
                // any announcement posted alongside clips it mid-sentence
                // (field-tested, including with low/queued priority).
                let modifier = VirtualKeys.modifiers[modifierBrowseIndex]
                if selectedModifiers.contains(modifier.vk) {
                    selectedModifiers.remove(modifier.vk)
                } else {
                    selectedModifiers.insert(modifier.vk)
                }
            }
        } header: {
            Text("Modifiers").accessibilityHidden(true)
        }
    }

    private var modifierBrowseValue: String {
        let modifier = VirtualKeys.modifiers[modifierBrowseIndex]
        return "\(modifier.name), \(selectedModifiers.contains(modifier.vk) ? "on" : "off")"
    }

    private func keySection(_ category: VirtualKeyCategory) -> some View {
        let index = keySelectionIndices[category.id, default: 0]
        return Section {
            keyRow {
                ForEach(category.keys) { key in
                    keyButton(key, in: category)
                }
            }
            // The slider position is the selection: no double tap anywhere
            // (activation is noticeably slow under VoiceOver). Option 0 is
            // "None"; swiping to a key selects it, swiping back to None
            // clears the row.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.title)
            .accessibilityValue(index == 0 ? "None" : category.keys[index - 1].name)
            .accessibilityHint("Swipe up or down to choose the key this row sends. The first option, None, sends nothing.")
            .accessibilityAdjustableAction { direction in
                keySelectionIndices[category.id] = adjusted(index, direction, count: category.keys.count + 1)
            }
        } header: {
            Text(category.title).accessibilityHidden(true)
        }
    }

    /// Move a browse cursor one step, clamped to the row's ends.
    private func adjusted(_ index: Int, _ direction: AccessibilityAdjustmentDirection, count: Int) -> Int {
        switch direction {
        case .increment: return min(index + 1, count - 1)
        case .decrement: return max(index - 1, 0)
        @unknown default: return index
        }
    }

    /// Touch-only (VoiceOver sees the enclosing row, not the buttons): tap
    /// selects the key in its row, tapping the selected key clears the row.
    private func keyButton(_ key: VirtualKey, in category: VirtualKeyCategory) -> some View {
        let position = (category.keys.firstIndex(of: key) ?? 0) + 1
        let isSelected = keySelectionIndices[category.id, default: 0] == position
        return Button(key.name) {
            keySelectionIndices[category.id] = isSelected ? 0 : position
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? Color.accentColor : nil)
    }

    /// A horizontally scrolling "slider" of keys.
    private func keyRow(@ViewBuilder content: () -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.vertical, 4)
        }
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
            Text("Each row sends the key it shows; None sends nothing. Tip: on this tab, a two-finger double tap sends the combination. Everything resets after sending.")
        }
    }

    // MARK: Combination state

    private var orderedModifiers: [VirtualKey] {
        VirtualKeys.modifiers.filter { selectedModifiers.contains($0.vk) }
    }

    /// The key each row's slider currently shows (rows on "None" contribute
    /// nothing), in row order — sent top to bottom.
    private var selectedKeys: [VirtualKey] {
        VirtualKeys.categories.compactMap { category in
            let index = keySelectionIndices[category.id, default: 0]
            return index > 0 ? category.keys[index - 1] : nil
        }
    }

    private var hasSomethingToSend: Bool {
        !selectedModifiers.isEmpty || !selectedKeys.isEmpty || !text.isEmpty
    }

    /// Human-readable spelling of exactly what Send will do, e.g.
    /// "Control + Shift + Escape" or "Control + “c”" or "“hello” + Enter".
    private var comboDescription: String {
        var parts = orderedModifiers.map(\.name)
        if !text.isEmpty { parts.append("“\(text)”") }
        parts.append(contentsOf: selectedKeys.map(\.name))
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " + ")
    }

    // MARK: Sending

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

        for key in selectedKeys { tap(key.vk) }
        for vk in modifiers.reversed() { bridge.sendKey(vk: vk, pressed: false) }

        // Reset everything so the next combination starts clean: rows back
        // to None, modifiers off, text cleared.
        selectedModifiers.removeAll()
        modifierBrowseIndex = 0
        keySelectionIndices = [:]
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

    /// Queued so it never clips the speech VoiceOver produces for the row's
    /// own state change — see `postQueuedAnnouncement`.
    private func announce(_ message: String) {
        postQueuedAnnouncement(message)
    }
}
