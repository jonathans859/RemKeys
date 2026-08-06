import GameController
import UIKit

/// Second, redundant capture source, sitting *beside* `pressesBegan` rather
/// than replacing it.
///
/// Why it exists: UIKit hands presses to the first responder only after the
/// system has had its turn, and since the iOS 26 SDK the system keeps Cmd
/// chords for itself — Cmd+B and friends never reach `pressesBegan` at all
/// (field-verified 2026-07-19; claiming them back with priority
/// `UIKeyCommand`s was field-verified insufficient too, 2026-08-06).
/// GameController reads the keyboard at the HID layer, below the responder
/// chain and below the menu system, so keys the system swallows still arrive
/// here.
///
/// Why it is *not* the only source: `keyChangedHandler` has a history of
/// silently never firing on real devices (SDL #6465), which disqualifies it as
/// a lone input path. So both sources run and `CaptureView` merges them —
/// whichever one sees a key carries it, and a key seen by both is forwarded
/// once. `isLive` records whether this path has ever actually delivered
/// anything, which is also what the Diagnostics screen reports.
@MainActor
final class GameControllerCapture {
    static let shared = GameControllerCapture()

    /// True once a key event has actually been delivered here. Until then the
    /// UIKit path is on its own and callers must not rely on this source.
    private(set) var isLive = false

    /// Receives every key transition GameController reports. Set by the active
    /// capture view; cleared when it leaves the window.
    var onKey: ((UIKeyboardHIDUsage, Bool) -> Void)?

    private init() {
        attachIfPossible()
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.attachIfPossible() }
        }
    }

    /// Start observing. Cheap and idempotent — a reconnected keyboard is a new
    /// `GCKeyboard` object, so the handler has to be installed again.
    func attachIfPossible() {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // The handler is not documented to run on the main thread; the
            // bridge and the diagnostics are both main-actor.
            Task { @MainActor in self?.deliver(keyCode: keyCode, pressed: pressed) }
        }
    }

    private func deliver(keyCode: GCKeyCode, pressed: Bool) {
        // GCKeyCode raw values are USB HID usage codes — the same numbers
        // UIKit reports as UIKey.keyCode, so no separate table is needed.
        guard let usage = UIKeyboardHIDUsage(rawValue: keyCode.rawValue) else { return }
        isLive = true
        CaptureDiagnostics.shared.gameControllerIsLive = true
        CaptureDiagnostics.shared.gameControllerKeysSeen += 1
        if pressed {
            CaptureDiagnostics.shared.lastGameControllerKey = HIDToVK.keyName(forUsage: usage)
        }
        onKey?(usage, pressed)
    }
}
