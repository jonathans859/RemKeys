import SwiftUI
import BridgeCore

@main
struct KeyBridgeApp: App {
    // Kills the SDK 26 default main menu so its key commands (Cmd+B/I/U,
    // Cmd+A/C/V/X/Z/F, …) can't swallow chords before capture sees them.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var padStore: PadStore
    @State private var connectionStore: ConnectionStore

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _bridge = State(initialValue: BridgeClient(settings: settings))

        // Pads sync through the iCloud key-value store. Local storage stays the
        // source of truth for reads, so this works offline and signed out (the
        // store then simply does nothing). Two triggers, both needed: a merge
        // now, because changes made while the app wasn't running never arrive
        // as notifications, and the notification for the ones that come later.
        let cloud = NSUbiquitousKeyValueStore.default
        // Saved connections ride the same store, under their own keys.
        let padStore = PadStore(cloud: cloud)
        let connectionStore = ConnectionStore(cloud: cloud)
        _padStore = State(initialValue: padStore)
        _connectionStore = State(initialValue: connectionStore)
        padStore.syncFromCloud()
        connectionStore.syncFromCloud()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { note in
            // On an account change Apple replaces the store's contents, so
            // records missing from it weren't deleted anywhere: the stores
            // start their bookkeeping over instead of merging deletions.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            if reason == NSUbiquitousKeyValueStoreAccountChange {
                padStore.cloudAccountChanged()
                connectionStore.cloudAccountChanged()
            } else {
                padStore.syncFromCloud()
                connectionStore.syncFromCloud()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(settings: settings, bridge: bridge, padStore: padStore, connectionStore: connectionStore)
        }
    }
}
