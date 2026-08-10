import UIKit

/// Strips UIKit's default main menu (File/Edit/Format/View/…), which the
/// iOS 26 SDK builds automatically for every app via `UIMainMenuSystem`.
/// Hardware-keyboard chords that resolve to a main-menu command are consumed
/// by the menu system and never reach `pressesBegan` — field-verified
/// 2026-07-19: Cmd+B (Format → Bold) arrived at the PC as a bare Win press
/// because the B was eaten on-device, while unbound chords like Cmd+D
/// forwarded fine. This app has no use for a menu: while forwarding, every
/// chord belongs to the remote PC, so remove everything removable. On iPhone
/// there is no visible menu bar to lose; on iPad an emptied menu bar is the
/// correct trade. (System-reserved chords like Cmd+H / Cmd+Tab / Cmd+Space
/// still never reach the app — that's an iOS platform limit, not this menu.)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Removing menus in `buildMenu(with:)` happens *after* the system has
        // already built the main menu and reserved its shortcuts, which is the
        // likeliest reason the removals below changed nothing in the field.
        // iOS 26's configuration API is the upfront version of the same wish:
        // these groups are never created, so their chords are never claimed.
        if #available(iOS 26.0, *) {
            let configuration = UIMainMenuSystem.Configuration()
            configuration.textFormattingPreference = .removed   // Cmd+B/I/U
            configuration.findingPreference = .removed          // Cmd+F/G
            configuration.newScenePreference = .removed         // Cmd+N
            configuration.documentPreference = .removed
            configuration.printingPreference = .removed         // Cmd+P
            configuration.toolbarPreference = .removed
            configuration.sidebarPreference = .removed
            configuration.inspectorPreference = .removed
            UIMainMenuSystem.shared.setBuildConfiguration(configuration)
        }
        return true
    }

    /// UIKit asks this every time it re-evaluates rotation. `OrientationLock`
    /// owns the answer so the Virtual Input tab can pin the app sideways —
    /// the only way to get a landscape-shaped key pad on a device whose
    /// rotation lock is on, which for a VoiceOver user it usually is.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .file)
        builder.remove(menu: .edit)
        builder.remove(menu: .format)
        builder.remove(menu: .view)
        builder.remove(menu: .window)
        builder.remove(menu: .help)
    }
}
