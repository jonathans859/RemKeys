import UIKit
import GameController
import Observation

/// Live telemetry for the Diagnostics section, answering the questions that
/// matter when "keys don't arrive": does iOS see a hardware keyboard at all,
/// does the capture view hold first responder, and do key events actually
/// reach `pressesBegan`?
///
/// GameController is used only to *detect* the keyboard (presence + name) —
/// capture itself stays on the pressesBegan path; `keyChangedHandler` is
/// deliberately not used (it silently fails on some devices, SDL #6465).
@MainActor
@Observable
final class CaptureDiagnostics {
    static let shared = CaptureDiagnostics()

    /// Name of the attached hardware keyboard; nil when iOS reports none.
    private(set) var keyboardName: String?
    /// Whether the capture view currently holds first responder.
    var captureViewIsFirstResponder = false
    /// Key-downs the capture view has received, mapped or not. The decisive
    /// number: keyboard detected but this stays 0 while typing means another
    /// layer (VoiceOver QuickNav, Full Keyboard Access) consumes keys first.
    var pressesSeen = 0
    /// Key transitions (downs and ups) handed to the bridge.
    var eventsForwarded = 0
    /// Readable name of the last key-down seen.
    var lastKey: String?
    /// Key-downs seen that had no Windows VK mapping.
    var unmappedSeen = 0

    private init() {
        refreshKeyboard()
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshKeyboard() }
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshKeyboard() }
        }
    }

    private func refreshKeyboard() {
        if let keyboard = GCKeyboard.coalesced {
            keyboardName = keyboard.vendorName ?? "Hardware keyboard"
        } else {
            keyboardName = nil
        }
    }
}
