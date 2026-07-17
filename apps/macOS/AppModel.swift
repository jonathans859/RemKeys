import AppKit
import Observation
import BridgeCore

/// Owns the macOS app's long-lived objects and wires capture-state changes to
/// their side effects: the border overlay, audio cues, and VoiceOver
/// announcements.
///
/// Accessibility note: NSAccessibility announcements from a menu-bar
/// (`LSUIElement`) app are unreliable, so state is carried by **three**
/// redundant channels — a distinct audio cue, an announcement attempt, and an
/// always-current status line in the menu (`statusLine`). A screen-reader user
/// can track remote state from the sound alone without opening the menu.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let bridge: BridgeClient
    @ObservationIgnored let capture: KeyCapture
    @ObservationIgnored private let overlay = CaptureOverlay()

    /// One-line, always-current summary for the menu. Doubles as the VoiceOver
    /// value; written as a full sentence.
    private(set) var statusLine: String = "Forwarding off"

    init() {
        let settings = AppSettings()
        let bridge = BridgeClient(settings: settings)
        self.settings = settings
        self.bridge = bridge
        self.capture = KeyCapture(bridge: bridge, settings: settings)

        bridge.forwardingDidChange = { [weak self] enabled in
            self?.handleForwardingChange(enabled)
        }
        bridge.statusDidChange = { [weak self] status in
            self?.handleStatusChange(status)
        }
    }

    /// Install the event tap once at launch (gated behind the forwarding
    /// boolean per the UTM pattern — never rebuilt on toggle).
    func start() {
        capture.start()
        refreshStatusLine()
    }

    /// Re-run permission checks + tap install after the user grants access.
    func recheck() {
        capture.recheck()
        refreshStatusLine()
    }

    var isForwarding: Bool { bridge.forwardingEnabled }

    func toggleForwarding() {
        capture.toggleForwarding()
    }

    // MARK: Toggle-shortcut recording

    var isRecordingShortcut: Bool { capture.isRecording }

    /// Arm the recorder; the next chord the user presses becomes the shortcut.
    func recordToggleShortcut() {
        capture.beginRecording { [weak self] shortcut in
            self?.settings.toggleShortcut = shortcut
            self?.announce("Toggle shortcut set to \(shortcut.displayString)")
        }
    }

    func cancelRecordingShortcut() {
        capture.cancelRecording()
    }

    func clearToggleShortcut() {
        settings.toggleShortcut = nil
        announce("Toggle shortcut cleared. Use the button to toggle forwarding.")
    }

    // MARK: State side effects

    private func handleForwardingChange(_ enabled: Bool) {
        overlay.setVisible(enabled)
        play(enabled ? .toggleOn : .toggleOff)
        announce(enabled ? "Forwarding on" : "Forwarding off")
        refreshStatusLine()
    }

    private func handleStatusChange(_ status: BridgeClient.ConnectionStatus) {
        switch status {
        case .connected: play(.connected)
        case .failed: play(.failed)
        default: break
        }
        announce(status.announcement)
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        if bridge.forwardingEnabled {
            statusLine = "Forwarding on — \(bridge.status.announcement)"
        } else {
            statusLine = "Forwarding off"
        }
    }

    // MARK: Cues

    private enum Cue: String {
        case toggleOn = "Tink"
        case toggleOff = "Pop"
        case connected = "Glass"
        case failed = "Funk"
    }

    private func play(_ cue: Cue) {
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
