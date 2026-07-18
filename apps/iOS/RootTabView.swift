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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    // Screen curtain: black overlay + brightness 0 = effectively display-off
    // (fully off on OLED) while the app stays foreground and keeps capturing —
    // the battery saver for long forwarding sessions with the idle timer held.
    // Only offered while VoiceOver is off; VoiceOver has its own Screen
    // Curtain (three-finger triple tap) and our double-tap-to-dismiss would
    // collide with its gestures.
    @State private var curtainActive = false
    @State private var brightnessBeforeCurtain: CGFloat = 1

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ContentView(settings: settings, bridge: bridge, activateCurtain: { setCurtain(true) })
                    .tabItem { Label("Start", systemImage: "keyboard") }
                    .tag(AppTab.start)

                VirtualInputView(bridge: bridge, settings: settings)
                    .tabItem { Label("Virtual Input", systemImage: "hand.tap") }
                    .tag(AppTab.virtualInput)

                SettingsView(settings: settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }

            if curtainActive {
                curtain
            }
        }
        .statusBarHidden(curtainActive)
        .persistentSystemOverlays(curtainActive ? .hidden : .automatic)
        .accessibilityAction(.magicTap) { handleMagicTap() }
        .onAppear { wireUpBridge() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground means we can't capture anyway; stop
            // forwarding so the remote never sits with a half-held chord.
            if phase != .active, bridge.forwardingEnabled {
                bridge.forwardingEnabled = false
            }
            // Brightness is a system-wide setting that outlives the app —
            // never leave the backgrounded user with a dark phone.
            if phase != .active {
                setCurtain(false)
            }
        }
        .onChange(of: voiceOverEnabled) { _, on in
            // VoiceOver turned on mid-curtain: hand the screen back — from
            // here on its own Screen Curtain is the right tool.
            if on {
                setCurtain(false)
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

    private var curtain: some View {
        Color.black
            .ignoresSafeArea()
            .onTapGesture(count: 2) { setCurtain(false) }
            // VoiceOver never meets this (the feature is gated off), but
            // Switch Control / Full Keyboard Access users need a labeled way
            // back out.
            .accessibilityLabel("Screen curtain")
            .accessibilityHint("Turns the screen back on")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setCurtain(false) }
    }

    private func setCurtain(_ on: Bool) {
        guard curtainActive != on else { return }
        curtainActive = on
        if on {
            brightnessBeforeCurtain = screen?.brightness ?? 1
            screen?.brightness = 0
        } else {
            screen?.brightness = brightnessBeforeCurtain
        }
        updateIdleTimer()
    }

    /// The scene's screen; `UIScreen.main` is deprecated in scene-based apps.
    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
    }

    /// The screen must stay awake while forwarding (capture dies with it) and
    /// while curtained (brightness 0 must not auto-lock into a real suspend).
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = bridge.forwardingEnabled || curtainActive
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
            updateIdleTimer()
            postQueuedAnnouncement(enabled ? "Forwarding on" : "Forwarding off")
        }
        bridge.statusDidChange = { status in
            postQueuedAnnouncement(status.announcement)
        }
    }
}
