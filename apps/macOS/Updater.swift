import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed, the signing key and the "never
/// install unasked" policy live in Info.plist (`project.yml`); the appcast is
/// written by `deploy-macos.yml` on every Mac build.
///
/// **Gentle reminders.** RemKeys is a menu-bar app, so a scheduled check must
/// not throw a dialog in front of whatever the user is doing — least of all
/// mid-session, when every key is going to the PC and the dialog couldn't be
/// answered from the keyboard anyway. Sparkle shows its own alert only right
/// after launch (forwarding is always off then); otherwise the update is
/// handed to `availableUpdateDidChange`, and `AppModel` reports it on the same
/// channels as every other state change: status line, sound, announcement.
/// "Check for Updates…" then brings up Sparkle's dialog on request.
///
/// Sparkle calls its delegate on the main thread but its protocol isn't
/// actor-annotated, hence the `nonisolated` members hopping back with
/// `assumeIsolated` (the same pattern as `KeyCapture`'s C callbacks).
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// The build number of an update found by a scheduled check that Sparkle
    /// is *not* showing itself, or `nil` once the user has seen it.
    var availableUpdateDidChange: (@MainActor (String?) -> Void)?

    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// Show Sparkle's dialog: "up to date", or the waiting update with its
    /// Install button.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `immediateFocus` is true only when the app has just launched — the one
    /// moment a dialog can't interrupt anything.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let build = update.versionString
        MainActor.assumeIsolated { availableUpdateDidChange?(build) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableUpdateDidChange?(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableUpdateDidChange?(nil) }
    }
}
