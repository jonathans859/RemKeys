import SwiftUI
import UIKit
import BridgeCore

/// A tiny first-responder view used only while recording the forwarding-toggle
/// shortcut. It captures the next physical chord straight from `pressesBegan`
/// (the only path that exposes individual modifiers and non-character keys),
/// then hands back a `ToggleShortcut`. Escape cancels.
struct ShortcutRecorder: UIViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: ToggleShortcut?

    func makeUIView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.isAccessibilityElement = false
        wire(v)
        return v
    }

    func updateUIView(_ view: ShortcutRecorderView, context: Context) {
        wire(view)
        if isRecording {
            if !view.isFirstResponder {
                Task { @MainActor in _ = view.becomeFirstResponder() }
            }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    private func wire(_ view: ShortcutRecorderView) {
        view.onCapture = { captured in
            shortcut = captured
            isRecording = false
            UIAccessibility.post(notification: .announcement,
                                 argument: "Shortcut set to \(captured.displayString)")
        }
        view.onCancel = {
            isRecording = false
            UIAccessibility.post(notification: .announcement, argument: "Recording cancelled")
        }
    }
}

/// First-responder UIView that records one chord.
final class ShortcutRecorderView: UIView {
    var onCapture: ((ToggleShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // Tab/arrows/etc. reach `pressesBegan` here because the recorder claims
    // every press (never calls super); the focus engine only acts on presses
    // passed up the chain. See the matching note in KeyboardCapture.swift.
    override var keyCommands: [UIKeyCommand]? { [] }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardEscape { onCancel?(); return }
            // Wait until a non-modifier "main" key completes the chord.
            if HIDToVK.isModifier(key) { continue }
            let shortcut = ToggleShortcut(
                keyCode: Int(key.keyCode.rawValue),
                modifiers: HIDToVK.modifiers(from: key.modifierFlags),
                keyName: HIDToVK.keyName(for: key)
            )
            onCapture?(shortcut)
            return
        }
        // Only modifiers held so far — keep waiting for the main key.
    }
}
