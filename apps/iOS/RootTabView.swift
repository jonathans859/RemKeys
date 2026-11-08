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

    private enum AppTab {
        case start, virtualInput, settings
    }

    @State private var selectedTab: AppTab = .start
    @Environment(\.scenePhase) private var scenePhase

    // Screen curtain: black overlay + brightness 0 = effectively display-off
    // (fully off on OLED) while the app stays foreground and keeps capturing —
    // the battery saver for long forwarding sessions with the idle timer held.
    // Offered whether or not VoiceOver is running: VoiceOver has a Screen
    // Curtain of its own, but it is a separate switch that has to be found and
    // flipped, and it says nothing about brightness — which is the half that
    // saves the battery. With VoiceOver on the overlay is the only element on
    // screen and its dismissal is a plain activation, so nothing about the
    // behaviour changes.
    @State private var curtainActive = false
    @State private var brightnessBeforeCurtain: CGFloat = 1
    /// Whether we are currently holding the screen's brightness at zero.
    /// Tracked apart from `curtainActive` because the two have to part company
    /// the moment the app stops being frontmost: the black overlay is ours to
    /// keep, but the brightness belongs to the whole phone. See the
    /// scene-phase handler.
    @State private var brightnessHeldDown = false
    /// Set when leaving the app took the curtain down: the brightness written
    /// on the way out may have been dropped (iOS appears to ignore a change
    /// made while the phone is locking — field-reported 2026-11-08 as "after
    /// unlocking the screen is still dark"), so it is written again on return.
    @State private var restoreBrightnessOnReturn = false
    /// Until when, after coming back, a brightness that drops to near zero
    /// by itself (with the curtain down) is put back. iOS restores its own
    /// saved brightness when the display comes on after a lock — and the
    /// saved value is the 0 the curtain set — possibly *after* our write on
    /// `.active`. Field-reported 2026-11-08: leaving the app and Control
    /// Center restored fine, lock + unlock stayed dark.
    @State private var brightnessWatchUntil = Date.distantPast
    /// Whether this forwarding session has already raised the curtain by
    /// itself. Reset when forwarding stops, so `autoScreenCurtain` fires once
    /// per session and a reconnect never re-blacks a screen the user just
    /// asked to see.
    @State private var curtainAutoRaised = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ContentView(settings: settings, bridge: bridge, activateCurtain: { setCurtain(true) })
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
        // The explicit lock signal (only with a passcode set). Treated like
        // leaving the app, in case the scene phase is late or missing.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification
        )) { _ in
            logCurtain("locking")
            endCurtainForLeaving("lock")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification
        )) { _ in
            logCurtain("unlocked")
            if restoreBrightnessOnReturn { restoreBrightnessAfterReturn("unlock") }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIScreen.brightnessDidChangeNotification
        )) { _ in
            guard let screen else { return }
            let now = screen.brightness
            guard Date() < brightnessWatchUntil, !curtainActive, now < 0.05,
                  brightnessBeforeCurtain > now + 0.02 else { return }
            writeBrightness("iOS lowered it to \(level(now))")
        }
        .onChange(of: scenePhase) { _, phase in
            logCurtain("phase \(phase)")
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
                // Hand the brightness back here, not at `.background`.
                // `.inactive` is where the user is looking at something that
                // is NOT us — Control Center, the app switcher, the home
                // screen mid-swipe — and those can last as long as they like
                // without ever reaching `.background`, leaving a phone that is
                // simply dark everywhere. It is also the last callback a
                // force-quit from the switcher is sure to deliver. The curtain
                // itself stays up: coming back re-blacks the screen and the
                // session was never interrupted.
                releaseBrightness()
            case .background:
                // Actually gone. Capture is impossible from here, so stop
                // forwarding rather than leave the remote holding a chord —
                // and brightness is a system-wide setting that outlives the
                // app, so never leave the user with a dark phone.
                if bridge.forwardingEnabled {
                    bridge.forwardingEnabled = false
                }
                // Locking the phone or leaving the app ends the curtain, not
                // just the session: the app is no longer in use, so coming
                // back should find the screen as it was before the curtain.
                // (Control Center and other overlays are `.inactive` and keep
                // it up.)
                endCurtainForLeaving("background")
            case .active:
                // Whatever took the screen may have taken first responder too.
                CaptureView.requestReclaim()
                // Frontmost again, so the curtain that stayed up gets its
                // brightness back down. Re-reads the current level first, so a
                // brightness the user changed while they were away is what we
                // restore to later.
                if curtainActive { holdBrightnessDown(returning: true) }
                // Back after the curtain was taken down by leaving: write the
                // remembered level again, in case the write made while
                // locking never landed.
                if restoreBrightnessOnReturn { restoreBrightnessAfterReturn("active") }
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
        logCurtain(on ? "curtain up" : "curtain down")
        if on {
            holdBrightnessDown()
        } else {
            releaseBrightness()
        }
        updateIdleTimer()
    }

    /// Take the screen to zero, remembering what it was. Both halves are
    /// idempotent on `brightnessHeldDown`, or a second call would record zero
    /// as the level to restore to and the phone would never come back.
    ///
    /// - Parameter returning: re-darkening on the way back to `.active`,
    ///   rather than raising the curtain. Then a near-zero reading is never
    ///   remembered as "the user's level": right after an overlay or a lock
    ///   the screen can still report the 0 we set, and restoring to that
    ///   leaves the phone dark everywhere. Raising the curtain always
    ///   remembers, so a genuinely dim screen comes back dim.
    private func holdBrightnessDown(returning: Bool = false) {
        guard !brightnessHeldDown, let screen else { return }
        if !returning || screen.brightness > 0.05 { brightnessBeforeCurtain = screen.brightness }
        logCurtain("darken, remembering \(level(brightnessBeforeCurtain))")
        brightnessHeldDown = true
        screen.brightness = 0
    }

    /// Give the brightness back. Safe to call when we are not holding it.
    private func releaseBrightness() {
        guard brightnessHeldDown, let screen else { return }
        brightnessHeldDown = false
        screen.brightness = brightnessBeforeCurtain
    }

    /// Locking the phone or leaving the app: take the curtain down and give
    /// the brightness back, and remember to give it back again on return —
    /// a write made while the display goes off may never land.
    private func endCurtainForLeaving(_ reason: String) {
        guard curtainActive || brightnessHeldDown else { return }
        setCurtain(false)
        writeBrightness("restore on \(reason)")
        restoreBrightnessOnReturn = true
    }

    /// Back after leaving: write the remembered level now and twice more while
    /// the display settles, and for a few seconds put it back if iOS lowers it
    /// to near zero by itself.
    ///
    /// Every write here is **nudged** (see `writeBrightness`): the field log
    /// of 2026-11-08 showed the write made while locking "reading" 1.00 and
    /// the one on return "reading" 1.00 too, with the screen still dark. The
    /// getter reports the last value set, not the panel, and a write equal to
    /// that value appears to be dropped. The retries stop as soon as the
    /// reading differs from what was set, i.e. the user changed it.
    private func restoreBrightnessAfterReturn(_ reason: String) {
        restoreBrightnessOnReturn = false
        guard !curtainActive else { return }
        writeBrightness("restore on \(reason)", nudge: true)
        brightnessWatchUntil = Date().addingTimeInterval(5)
        Task { @MainActor in
            for delay in [0.3, 1.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !curtainActive, let screen,
                      abs(screen.brightness - brightnessBeforeCurtain) < 0.005 else { return }
                writeBrightness("retry after \(delay)s", nudge: true)
            }
        }
    }

    /// Set the remembered level and log what the screen reports straight
    /// after. With `nudge`, first set a value 0.02 away, so the real write is
    /// always a change — UIKit seems to skip a write equal to its cached
    /// value, and after a lock that cache no longer matches the panel.
    private func writeBrightness(_ reason: String, nudge: Bool = false) {
        guard let screen else {
            logCurtain("\(reason): no screen")
            return
        }
        let target = brightnessBeforeCurtain
        if nudge {
            screen.brightness = target > 0.5 ? target - 0.02 : target + 0.02
        }
        screen.brightness = target
        logCurtain("\(reason)\(nudge ? " (nudged)" : ""): set \(level(target)), reads \(level(screen.brightness))")
    }

    private func level(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func logCurtain(_ event: String) {
        CaptureDiagnostics.shared.logCurtain(event)
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
        bridge.statusDidChange = { status in
            postQueuedAnnouncement(status.announcement)
            if status.isConnected { raiseCurtainAutomaticallyIfWanted() }
        }
    }
}
