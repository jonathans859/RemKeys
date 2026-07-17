import SwiftUI
import AppKit
import BridgeCore

@main
struct KeyBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            // The label also carries state for VoiceOver users navigating the
            // menu bar (state is never conveyed by the icon alone).
            Image(systemName: model.isForwarding ? "keyboard.fill" : "keyboard")
                .accessibilityLabel("RemKeys")
                .accessibilityValue(model.statusLine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Installs the capture tap at launch. A menu-bar-only app (`LSUIElement`)
/// never gets a window `onAppear`, so launch-time setup lives here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}
