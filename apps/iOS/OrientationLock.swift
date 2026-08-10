import UIKit
import BridgeCore

/// Pins the app to one interface orientation, or releases it back to the
/// device's own rotation.
///
/// Why an app needs this at all: the key pad's two arrangements want
/// different screen shapes, and the device is not always free to supply one.
/// **iOS rotation lock is commonly on for a VoiceOver user** — auto-rotation
/// is disorienting when you navigate by touch — and with it on the app is
/// never handed a landscape frame, so the keyboard layout would be stuck at
/// portrait's cramped key widths with nothing the app could do about it.
/// Requesting the orientation ourselves is the documented way out, and it
/// outranks the device's rotation lock.
///
/// Two halves are required and neither works alone: UIKit asks the app
/// delegate which orientations are allowed *right now*
/// (`supportedInterfaceOrientationsFor`), and a geometry request asks it to
/// actually rotate to one. Changing the allowed set without asking leaves the
/// screen where it is until the user physically turns the device.
enum OrientationLock {
    /// What `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
    /// answers. Defaults to everything, matching the Info.plist.
    private(set) static var mask: UIInterfaceOrientationMask = .all

    /// Apply a setting: narrow (or widen) what the app allows, then ask the
    /// scene to move if the current orientation is no longer one of them.
    @MainActor
    static func apply(_ lock: InterfaceOrientationLock) {
        switch lock {
        case .device: mask = .all
        case .portrait: mask = .portrait
        case .landscape: mask = .landscape
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        // The root controller has to be told its answer changed, or UIKit
        // keeps using the mask it cached when the view controller appeared.
        scene.windows.first?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()

        guard mask != .all else { return }
        // Errors here are expected rather than exceptional: iPad multitasking
        // and Stage Manager refuse geometry requests outright. The mask is
        // still in force, so the app simply stays wherever the system allows.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
