import SwiftUI
import UIKit
import BridgeCore

/// On-screen key sender: build a key combination without a physical keyboard
/// and ship it to the PC. VoiceOver-first by design, and — since 2026-08-20 —
/// deliberately small.
///
/// **The concept in one sentence: the pad carries the keys the iPhone's own
/// keyboard doesn't have, the iPhone's keyboard carries the letters, and
/// nothing on the pad is smaller than a thumb.**
///
/// That is a retreat from the full 60-key PC keyboard layout, and the retreat
/// is the point. Letters on glass at 23 pt a key are not faster than the
/// system keyboard the user already types on at speed (with Braille Screen
/// Input or dictation behind it), and paying for them shrank every other key
/// on the screen. So letters go back to the text field — with sticky text, a
/// repeated single letter for screen-reader navigation costs one Send — and
/// the pad spends its whole area on the keys a phone keyboard cannot express.
///
/// - The **direct-touch key pad** (`VirtualKeyPad`) IS the key interface: one
///   accessibility element whose raw touches bypass VoiceOver's gesture
///   round-trip entirely. Drag to hear, lift to send, lift on a modifier to
///   toggle it, hold to press a key down on the PC until you lift. Three zones
///   wide: a page of nine (or twelve) keys on top, the six modifiers welded to
///   the bottom edge underneath, never moving.
/// - **Pages** — Navigation, Editing, Function keys — change by two-finger
///   swipe on the pad or from the adjustable page control in the toolbar. Two
///   ways in: one fast, one discoverable.
/// - Plain text is typed into a normal text field and sent through the
///   layout-independent unicode path, so it types verbatim on any PC layout;
///   when modifiers are held it switches to US-position keys, because
///   shortcuts match keys, not characters. The field normally clears after
///   Send; `virtualInputKeepText` pins it instead.
/// - A two-finger double tap (magic tap) sends from anywhere on this tab, and
///   the top-right info button explains the screen as it is configured.
///
/// Layout rules that were paid for in the field and must survive edits: the
/// pad stays OUTSIDE any scroll container (a scroll ancestor cancels
/// direct-touch drags — build 25 shipped a dead pad inside a Form); the
/// control row is a bottom `safeAreaInset`, the messenger input-bar pattern,
/// so the on-screen keyboard pushes it up instead of burying Send; and every
/// title on iOS is inline, because a large title sits low and overlapped the
/// non-scrollable pad.
struct VirtualInputView: View {
    let bridge: BridgeClient
    let settings: AppSettings

    /// Posted by the root magic-tap handler while this tab is frontmost.
    static let sendRequested = Notification.Name("KeyBridge.virtualInputSendRequested")

    /// The modifiers currently turned on. Only modifiers can be on — holding
    /// a key now presses it down on the PC rather than latching it — so this
    /// is a plain set of VKs and the send order comes from
    /// `VirtualKeys.modifiers`.
    @State private var latchedVKs: Set<UInt16> = []
    /// The key the pad is holding *down* on the PC right now, plus the keys
    /// pressed around it, so the release lets go of exactly what it pressed.
    @State private var heldKey: VirtualKey?
    @State private var holdWrap: [VirtualKey] = []
    @State private var pageIndex = 0
    @State private var text = ""
    @State private var showInfo = false
    @FocusState private var textFieldFocused: Bool
    /// Compact height is a phone held sideways: there the on-screen keyboard
    /// takes almost the whole screen, and what is left cannot hold a pad.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var pages: [PadPage] {
        VirtualKeys.pages(includeExtendedFKeys: settings.virtualPadExtendedFKeys)
    }

    private var currentPage: PadPage {
        let all = pages
        return all[min(max(pageIndex, 0), all.count - 1)]
    }

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
                // gives up the height and gets it back when the keyboard goes.
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
                        pageControl
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
        // Turning off the F13–F24 page while it is the one on screen would
        // otherwise leave the index past the end.
        .onChange(of: settings.virtualPadExtendedFKeys) { _, _ in
            pageIndex = min(pageIndex, pages.count - 1)
        }
        // Turning the phone sideways takes the text field away with the rest
        // of the typing controls; the focus state has to follow, or the field
        // comes back focused (and the keyboard with it) on the way back.
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue == .compact { textFieldFocused = false }
        }
    }

    // MARK: Page control

    /// Which keys the top of the pad shows. **One adjustable element**, not a
    /// row of buttons or a menu: flick up or down to move through the pages
    /// and VoiceOver speaks the new one, which is a single gesture against a
    /// menu's open-pick-dismiss. A tap does the same thing for a sighted user,
    /// and the pad's own two-finger swipe is the fast path once the pages are
    /// known.
    private var pageControl: some View {
        Text(currentPage.title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { stepPage(by: 1) }
            .accessibilityElement()
            .accessibilityLabel("Key page")
            .accessibilityValue(currentPage.title)
            .accessibilityHint("Chooses which keys fill the top of the pad. The modifiers below them never change. A two-finger swipe left or right on the pad does the same.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { stepPage(by: 1) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: stepPage(by: 1)
                case .decrement: stepPage(by: -1)
                @unknown default: break
                }
            }
    }

    /// Wraps, unlike the pad's own swipe: a flick that runs off the end of an
    /// adjustable element is a dead end, while the pad answers an edge with a
    /// harder vibration the finger can feel.
    ///
    /// It says nothing itself — this is an adjustable element, so VoiceOver
    /// reads the new value out of `accessibilityValue` on its own, and the pad
    /// only announces page changes that came from its own swipe.
    private func stepPage(by delta: Int) {
        let count = pages.count
        guard count > 0 else { return }
        pageIndex = (pageIndex + delta + count) % count
    }

    // MARK: Layout

    /// The one and only chrome row, under the pad: text field, dismiss
    /// keyboard, keep text, Send. Everything but the field is icon-sized so
    /// the field keeps usable width on a phone, and the row sits right above
    /// the on-screen keyboard when it comes up.
    ///
    /// **Sideways on a phone it is Send alone** (field-requested 2026-08-10).
    /// Focusing the field in that orientation raises the on-screen keyboard,
    /// which leaves a strip of screen; removing the field is what makes it
    /// impossible to raise, so the pad keeps its height. Text typed upright
    /// survives and Send still delivers it (its hint spells out what).
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
        // The combination is spoken as the hint, so focusing Send tells you
        // what it delivers without a readout row of its own. Recomputed on
        // every focus, so it never goes stale as modifiers are toggled.
        .accessibilityHint(hasSomethingToSend
            ? "Sends \(comboDescription) to the Windows PC"
            : "Nothing selected to send")
    }

    /// The pad drives the modifiers and tints the ones that are on; Send reads
    /// the same state for its hint. Pad sends always wrap in them.
    private var pad: some View {
        VirtualKeyPad(
            settings: settings,
            pageIndex: pageIndex,
            latchedKeys: latchedVKs,
            onPageStep: { delta in
                let target = pageIndex + delta
                if pages.indices.contains(target) { pageIndex = target }
            },
            onSetLatched: { key, on in
                if on { latchedVKs.insert(key.vk) } else { latchedVKs.remove(key.vk) }
            },
            onClearLatched: { latchedVKs.removeAll() },
            onSend: { key in sendImmediate(key) },
            onHoldBegin: { key in beginHold(key) },
            onHoldEnd: { key in endHold(key) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Info sheet

    /// Explains the tab as it currently behaves — the text follows the pages
    /// that exist and the hold and haptics settings, so it never describes
    /// something the pad isn't doing right now.
    private var infoSheet: some View {
        InfoSheet(title: "Virtual Input") {
            Section("Key pad") {
                Text("The pad is three zones wide, so every zone is a corner, the middle of an edge, or the centre — something a finger can find without counting along a row. Touches on it act immediately; VoiceOver gestures are bypassed. Drag to hear the key under your finger, with a tick at each boundary, and lift to send it at once. Landing a second finger cancels the drag, so nothing is sent.")
                Text("The bottom two rows are always the six modifiers — Control, Shift, Alt, Windows, AltGr, Caps Lock — in that order, and they stay exactly there whichever keys are above them. Lift on one to turn it on or off. Two-finger tap anywhere on the pad turns them all off.")
            }
            Section("Pages") {
                Text("Everything above the modifiers is one page at a time: \(pageList). Two-finger swipe left for the next page, right for the previous one; a harder vibration means there is no page that way. The page control at the top left does the same — flick up or down on it with VoiceOver.")
                Text("On the Navigation page the arrows are laid out as they mean: Up along the top edge, Down along the bottom, Left and Right at the sides, with Enter in the middle. The corners are Home and Page Up above, End and Page Down below.")
                if !settings.virtualPadExtendedFKeys {
                    Text("F13 to F24 can be added as a further page under Key pad in Settings. It costs nothing to the other pages.")
                }
            }
            Section("Letters and text") {
                Text("Letters, digits and punctuation are not on the pad. They go in the text field instead, typed with the iPhone's own keyboard — which is faster than any keyboard we could draw on glass, and which Braille Screen Input and dictation already work with.")
                Text("Text without modifiers is typed on the PC exactly as written, including umlauts, regardless of the PC's keyboard layout. With modifiers turned on, each character becomes its US-position key instead — shortcuts match keys, not characters — and characters without a US key are skipped and announced.")
                Text("For screen-reader navigation on the PC — Caps Lock plus H for headings, say — turn Caps Lock on at the pad, type the letter once, and turn on Keep text after sending: every further heading is then a single Send.")
                Text("To empty the field in one step, focus it with VoiceOver and use its Clear text action — swipe up or down to find it, then double tap.")
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
                    Text("Press and keep holding any key on the pad. After \(VirtualKeys.secondsDescription(settings.virtualPadHoldDelay)) it is pressed down on the PC and stays down until you lift, with a firm vibration to mark the moment: that is how you get key repeat, such as holding Backspace to delete a run of text or Down to keep scrolling. On the pad the key gets a strong coloured background while it is down.")
                    Text("Holding works on modifiers too, which is how to send a plain Caps Lock press and flip the lock itself. The timing and the spoken cues can be changed in Settings; the vibrations stay either way.")
                }
            }
            Section("Sending") {
                if settings.virtualInputKeepText {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the modifiers that are on plus the typed text. Keep text after sending is on, so the modifiers reset but the text stays in the field: pressing Send again repeats it. Clear the field yourself, or turn the button off, when you are done with that text.")
                } else {
                    Text("Send — or a two-finger double tap anywhere on this tab — delivers the modifiers that are on plus the typed text, then resets both. To repeat the same text, turn on Keep text after sending, the button just left of Send.")
                }
                Text("Sending needs forwarding: if it is off, Send turns it on and asks you to send again once connected. Keys sent straight from the pad are silent when they work; you only hear a message when something failed.")
            }
        }
    }

    /// The page names, spoken as a list: "Navigation, Editing and Function
    /// keys".
    private var pageList: String {
        let titles = pages.map(\.title)
        guard let last = titles.last, titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Combination state

    /// What gets pressed around whatever is sent, in the canonical order the
    /// modifier block shows them.
    private var wrapKeys: [VirtualKey] {
        VirtualKeys.modifiers.filter { latchedVKs.contains($0.vk) }
    }

    private var hasSomethingToSend: Bool {
        !latchedVKs.isEmpty || !text.isEmpty
    }

    /// Human-readable spelling of exactly what Send will do, e.g.
    /// "Control + Shift + Escape" or "Control + “c”" or "“hello”".
    private var comboDescription: String {
        var parts = wrapKeys.map(\.spokenName)
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " + ")
    }

    // MARK: Sending

    /// Immediate path for the pad: exactly one key, wrapped in whatever is on.
    /// Success is fully silent (the pad adds its own haptic) and nothing
    /// resets; modifiers only clear via Send, pressing them again, or the
    /// pad's clear gesture. A failure doesn't flip forwarding on — it just
    /// says the key was not sent.
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

    /// The pad's hold: the key goes *down* on the PC and stays down until the
    /// finger lifts, so it repeats there (hold Backspace to eat a word). The
    /// repeat is generated by the Windows agent, at the PC's own delay and
    /// rate — Windows itself never repeats injected keys. The modifiers that
    /// are on are pressed around it exactly as they wrap a tap, the held key
    /// itself excluded, since a modifier can be on and then held. Returns
    /// false when nothing was sent, so the pad doesn't claim a key is down
    /// that never went out.
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

        // Reset so the next combination starts clean: modifiers off, text
        // cleared — unless the text is pinned, in which case it stays put so
        // the same keystroke can be fired again with a single Send.
        latchedVKs.removeAll()
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
