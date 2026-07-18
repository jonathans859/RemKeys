import SwiftUI
import UIKit
import BridgeCore

/// App root: Start (status + physical capture), Virtual Input (on-screen key
/// sender), Settings. App-wide behavior lives here — bridge callbacks, the
/// scene-phase stop, and the magic tap, which is attached to the root so it
/// resolves wherever VoiceOver focus is (including the tab bar) and routes by
/// tab: on Virtual Input it sends the built combination, elsewhere it toggles
/// forwarding.
struct RootTabView: View {
    let settings: AppSettings
    let bridge: BridgeClient

    private enum AppTab {
        case start, virtualInput, settings
    }

    @State private var selectedTab: AppTab = .start
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(settings: settings, bridge: bridge)
                .tabItem { Label("Start", systemImage: "keyboard") }
                .tag(AppTab.start)

            VirtualInputView(bridge: bridge)
                .tabItem { Label("Virtual Input", systemImage: "hand.tap") }
                .tag(AppTab.virtualInput)

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .accessibilityAction(.magicTap) { handleMagicTap() }
        .onAppear { wireUpBridge() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground means we can't capture anyway; stop
            // forwarding so the remote never sits with a half-held chord.
            if phase != .active, bridge.forwardingEnabled {
                bridge.forwardingEnabled = false
            }
        }
        .onChange(of: selectedTab) { _, tab in
            // Settings and Virtual Input both put first responder elsewhere
            // (pickers, text field); returning to Start hands the hardware
            // keyboard back to the capture view.
            if tab == .start {
                CaptureView.requestReclaim()
            }
        }
    }

    private func handleMagicTap() {
        switch selectedTab {
        case .virtualInput:
            NotificationCenter.default.post(name: VirtualInputView.sendRequested, object: nil)
        case .start, .settings:
            bridge.forwardingEnabled.toggle()
            CaptureView.requestReclaim()
        }
    }

    /// Wire bridge callbacks to VoiceOver announcements and the idle timer.
    /// Announcements are the accessible channel for state a sighted user reads
    /// off the status line.
    private func wireUpBridge() {
        bridge.forwardingDidChange = { enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled
            postQueuedAnnouncement(enabled ? "Forwarding on" : "Forwarding off")
        }
        bridge.statusDidChange = { status in
            postQueuedAnnouncement(status.announcement)
        }
    }
}
