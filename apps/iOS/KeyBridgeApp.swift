import SwiftUI
import BridgeCore

@main
struct KeyBridgeApp: App {
    // Kills the SDK 26 default main menu so its key commands (Cmd+B/I/U,
    // Cmd+A/C/V/X/Z/F, …) can't swallow chords before capture sees them.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var bridge: BridgeClient

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _bridge = State(initialValue: BridgeClient(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(settings: settings, bridge: bridge)
        }
    }
}
