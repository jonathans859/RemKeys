import SwiftUI
import BridgeCore

@main
struct KeyBridgeApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _bridge = State(initialValue: BridgeClient(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, bridge: bridge)
        }
    }
}
