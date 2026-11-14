import UIKit
import GameController
import Observation

/// Live telemetry for the Diagnostics section, answering the questions that
/// matter when "keys don't arrive": does iOS see a hardware keyboard at all,
/// does the capture view hold first responder, and do key events actually
/// reach `pressesBegan`?
///
/// GameController also supplies the keyboard's presence and name. Its
/// `keyChangedHandler` is the second capture source (`GameControllerCapture`,
/// the only one that sees Cmd chords), merged with `pressesBegan` in
/// `CaptureView`. It silently never fires on some devices (SDL #6465), which
/// is what `gameControllerIsLive` shows.
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
    /// Key transitions (downs and ups) the bridge actually wrote to the
    /// connection. Keys dropped because the link was down don't count.
    var eventsForwarded = 0
    /// Readable name of the last key-down seen.
    var lastKey: String?
    /// Key-downs seen that had no Windows VK mapping.
    var unmappedSeen = 0
    /// Whether the HID-level (GameController) source has ever delivered a key.
    /// False while typing means `keyChangedHandler` is silently dead on this
    /// device (SDL #6465) and Cmd chords depend on the UIKeyCommand claim.
    var gameControllerIsLive = false
    /// Key transitions seen on the HID-level source, forwarded or not.
    var gameControllerKeysSeen = 0
    /// Readable name of the last key-down the HID-level source reported. The
    /// decisive row for a stolen chord: a name here with nothing in
    /// `lastKey` means UIKit never got the key but the app did.
    var lastGameControllerKey: String?
    /// Cmd chords intercepted by the priority `UIKeyCommand` claim.
    var chordsClaimed = 0
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
