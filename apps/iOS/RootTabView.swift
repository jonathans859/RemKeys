import SwiftUI
import UIKit
import GameController
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
    let padStore: PadStore
    let connectionStore: ConnectionStore

    private enum AppTab {
        case start, virtualInput, settings
    }

    @State private var selectedTab: AppTab = .start
    @Environment(\.scenePhase) private var scenePhase

    // Screen curtain: a full-screen black overlay while the app stays
    // foreground and keeps capturing — the battery saver for long forwarding
    // sessions with the idle timer held. On OLED iPhones black pixels are off,
    // so the overlay alone is effectively display-off.
    //
    // It deliberately does NOT touch `UIScreen.brightness` (it used to drop it
    // to 0). Brightness is the whole phone's setting, and a lock with it at 0
    // left the lock screen dark until unlock: once locking starts iOS ignores
    // the app's writes ("set 0.84, reads 0.00" in the field log, 2026-11-08)
    // and keeps the 0 as the phone's brightness, and a lock cannot be seen
    // coming. Only LCD models (SE, XR, 11) lose some saving; the user chose
    // that trade.
    //
    // Offered whether or not VoiceOver is running: VoiceOver's own Screen
    // Curtain is a separate switch that has to be found and flipped. With
    // VoiceOver on the overlay is the only element on screen and its
    // dismissal is a plain activation.
    @State private var curtainActive = false
    /// Whether this forwarding session has already raised the curtain by
    /// itself. Reset when forwarding stops, so `autoScreenCurtain` fires once
    /// per session and a reconnect never re-blacks a screen the user just
    /// asked to see.
    @State private var curtainAutoRaised = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ContentView(settings: settings, bridge: bridge, connections: connectionStore, activateCurtain: { setCurtain(true) })
                    .tabItem { Label("Start", systemImage: "keyboard") }
                    .tag(AppTab.start)

                VirtualInputView(bridge: bridge, settings: settings, padStore: padStore)
                    .tabItem { Label("Virtual Input", systemImage: "hand.tap") }
                    .tag(AppTab.virtualInput)

                SettingsView(settings: settings, padStore: padStore)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            // With the curtain up the screen is meant to be gone. Hiding the
            // tabs from the accessibility tree leaves VoiceOver exactly one
            // element — the curtain itself — so a swipe cannot wander into UI
            // the user can no longer see.
            .accessibilityHidden(curtainActive)

            if curtainActive {
                curtain
            }
        }
        .statusBarHidden(curtainActive)
        .persistentSystemOverlays(curtainActive ? .hidden : .automatic)
        .accessibilityAction(.magicTap) { handleMagicTap() }
        .onAppear {
            wireUpBridge()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            raiseCurtainAutomaticallyIfWanted()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                // NOT a reason to stop. `.inactive` is Control Center,
                // Notification Center, the app switcher, a call banner — the
                // app is still frontmost and comes back in a second, and
                // having to press Start again after every glance at Control
                // Center was the whole complaint. Presses genuinely do stop
                // arriving while that overlay is up, though, so a key that was
                // physically down right then may never report its release:
                // let go of it at both ends and carry on forwarding.
                if bridge.forwardingEnabled {
                    bridge.releaseHeldKeys()
                    CaptureView.requestForgetHeldKeys()
                }
                // The curtain stays up: coming back finds it still there and
                // the session was never interrupted.
            case .background:
                // Actually gone. Capture is impossible from here, so stop
                // forwarding rather than leave the remote holding a chord.
                if bridge.forwardingEnabled {
                    bridge.forwardingEnabled = false
                }
                // Locking the phone or leaving the app ends the curtain, not
                // just the session: the app is no longer in use, so coming
                // back should find the screen as it was before the curtain.
                // (Control Center and other overlays are `.inactive` and keep
                // it up.)
                setCurtain(false)
            case .active:
                // Whatever took the screen may have taken first responder too.
                CaptureView.requestReclaim()
            @unknown default:
                break
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
            // The tap gesture serves everyone else; VoiceOver, Switch Control
            // and Full Keyboard Access users leave through the action below,
            // which a VoiceOver double tap triggers just the same.
            .accessibilityLabel("Screen curtain")
            .accessibilityHint("Turns the screen back on")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setCurtain(false) }
    }

    private func setCurtain(_ on: Bool) {
        guard curtainActive != on else { return }
        curtainActive = on
        updateIdleTimer()
    }

    /// The screen must stay awake while forwarding (capture dies with it) and
    /// while curtained (an auto-lock would end the session).
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = bridge.forwardingEnabled || curtainActive
    }

    /// `autoScreenCurtain`: the session has reached the PC **and a hardware
    /// keyboard is connected**, so black the screen without being asked.
    /// Without a keyboard the session is about the Virtual Input pad, which a
    /// curtain would cover (field-requested 2026-11-08). Once per session (see
    /// `curtainAutoRaised`), and only from the Start tab — connecting from
    /// Virtual Input means the user is about to touch the key pad. A keyboard
    /// that connects later in the session raises it then.
    private func raiseCurtainAutomaticallyIfWanted() {
        guard settings.autoScreenCurtain,
              !curtainAutoRaised,
              !curtainActive,
              bridge.status.isConnected,
              GCKeyboard.coalesced != nil,
              selectedTab == .start else { return }
        curtainAutoRaised = true
        setCurtain(true)
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
            if !enabled { curtainAutoRaised = false }
            postQueuedAnnouncement(enabled ? "Forwarding on" : "Forwarding off")
        }
        bridge.statusDidChange = { status, previous in
            if status.isWorthAnnouncing(after: previous) {
                postQueuedAnnouncement(status.announcement)
            }
            if status.isConnected { raiseCurtainAutomaticallyIfWanted() }
        }
        // Created here, not at the first drop, so the tick's sound is loaded
        // before it is needed.
        let dropCue = DropCue.shared
        bridge.keystrokeWasDropped = { dropCue.play() }
    }
}
