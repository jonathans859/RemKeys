import SwiftUI
import UIKit
import BridgeCore

/// On-screen key sender: build a key combination without a physical keyboard
/// and ship it to the PC in one tap. VoiceOver-first by design:
///
/// - Each key row is ONE adjustable element ("slider"): swipe up/down browses
///   the row's keys, double tap toggles (modifiers, multi-select) or selects
///   (main key, single-select) the current one. Left/right swipes jump
///   between rows — 8 stops for the whole screen instead of one per key.
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
    @State private var selectedKey: VirtualKey?
    @State private var text = ""
    @FocusState private var textFieldFocused: Bool

    // VoiceOver browse cursors. Each key row is exposed as a single
    // *adjustable* element (a "slider"): swipe up/down moves this cursor
    // through the row's keys, double tap acts on the current one. One swipe
    // stop per category instead of one per key.
    @State private var modifierBrowseIndex = 0
    @State private var keyBrowseIndices: [String: Int] = [:]

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
                let modifier = VirtualKeys.modifiers[modifierBrowseIndex]
                if selectedModifiers.contains(modifier.vk) {
                    selectedModifiers.remove(modifier.vk)
                    announce("\(modifier.name) off")
                } else {
                    selectedModifiers.insert(modifier.vk)
                    announce("\(modifier.name) on")
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
        let browsed = category.keys[keyBrowseIndices[category.id, default: 0]]
        return Section {
            keyRow {
                ForEach(category.keys) { key in
                    keyButton(key)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.title)
            .accessibilityValue(selectedKey == browsed ? "\(browsed.name), selected" : browsed.name)
            .accessibilityHint("Swipe up or down to move through the keys, double tap to make the current one the key to send. One key at a time, across all rows.")
            .accessibilityAdjustableAction { direction in
                keyBrowseIndices[category.id] = adjusted(
                    keyBrowseIndices[category.id, default: 0], direction, count: category.keys.count)
            }
            .accessibilityAction {
                let key = category.keys[keyBrowseIndices[category.id, default: 0]]
                if selectedKey == key {
                    selectedKey = nil
                    announce("\(key.name) removed")
                } else {
                    selectedKey = key
                    announce("\(key.name) selected")
                }
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

    private func keyButton(_ key: VirtualKey) -> some View {
        let isSelected = selectedKey == key
        return Button(key.name) {
            selectedKey = isSelected ? nil : key
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? Color.accentColor : nil)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected
            ? "Removes this key from the combination"
            : "Makes this the key the combination sends. One key at a time.")
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
            Text("Tip: on this tab, a two-finger double tap sends the combination. The selection clears after sending.")
        }
    }

    // MARK: Combination state

    private var orderedModifiers: [VirtualKey] {
        VirtualKeys.modifiers.filter { selectedModifiers.contains($0.vk) }
    }

    private var hasSomethingToSend: Bool {
        !selectedModifiers.isEmpty || selectedKey != nil || !text.isEmpty
    }

    /// Human-readable spelling of exactly what Send will do, e.g.
    /// "Control + Shift + Escape" or "Control + “c”" or "“hello” + Enter".
    private var comboDescription: String {
        var parts = orderedModifiers.map(\.name)
        if !text.isEmpty { parts.append("“\(text)”") }
        if let selectedKey { parts.append(selectedKey.name) }
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

        if let selectedKey { tap(selectedKey.vk) }
        for vk in modifiers.reversed() { bridge.sendKey(vk: vk, pressed: false) }

        selectedModifiers.removeAll()
        selectedKey = nil
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
