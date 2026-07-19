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
