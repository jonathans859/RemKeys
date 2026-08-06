import SwiftUI
import UIKit
import BridgeCore

/// Start tab: forwarding status, connection target, and the physical capture
/// surface.
///
/// Physical keyboard input only reaches an iOS app while it is foreground and
/// the screen is on — a sandbox restriction with no background workaround. The
/// UI is therefore built around a clear, always-visible "forwarding active"
/// state, and the idle timer is held off while forwarding so the screen never
/// sleeps out from under the user. App-wide behavior (magic tap, scene-phase
/// stop, bridge callbacks) lives in `RootTabView`.
struct ContentView: View {
    let settings: AppSettings
    let bridge: BridgeClient
    /// Raises the screen curtain, which lives in `RootTabView` so its overlay
    /// covers the tab bar too.
    let activateCurtain: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var diagnostics: CaptureDiagnostics { .shared }

    private var isForwarding: Bool { bridge.forwardingEnabled }

    @State private var showInfo = false

    var body: some View {
        ZStack {
            // Invisible first-responder view: the actual capture surface. It
            // sits behind the UI and holds the hardware keyboard.
            KeyboardCapture(bridge: bridge, settings: settings)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            NavigationStack {
                Form {
                    statusSection
                    connectionSection
                    forwardingSection
                    if !voiceOverEnabled {
                        curtainSection
                    }
                }
                .navigationTitle("RemKeys")
                // Compact title app-wide: it sits at the top of the screen and
                // leaves the content the height the large title would take.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        InfoButton { showInfo = true }
                    }
                }
                .sheet(isPresented: $showInfo, onDismiss: {
                    // The sheet took first responder; hand the hardware
                    // keyboard back to the capture view.
                    CaptureView.requestReclaim()
                }) { infoSheet }
            }
        }
    }

    /// Explanation + tips + the live diagnostics, moved off the main screen
    /// (field request 2026-07-19) so Start stays a lean status-and-go page.
    private var infoSheet: some View {
        InfoSheet(title: "Start") {
            Section("How forwarding works") {
                Text("While forwarding is active, keys typed on a connected hardware keyboard are sent to the Windows PC instead of acting here. Keystrokes only forward while RemKeys is in the foreground with the screen on — that is an iOS rule, so the screen is kept awake while forwarding runs.")
            }
            Section("Tips") {
                Text("A two-finger double tap anywhere toggles forwarding (on the Virtual Input tab it sends the built combination instead). A physical toggle shortcut can be recorded in Settings.")
                if !voiceOverEnabled {
                    Text("The screen curtain blacks out the display and drops brightness to zero to save battery on long sessions — forwarding keeps running. Double-tap the screen to turn it back on.")
                }
            }
            diagnosticsSection
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: isForwarding ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(isForwarding ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isForwarding ? "Forwarding active" : "Forwarding paused")
                        .font(.headline)
                    Text(bridge.status.announcement)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isForwarding ? "Forwarding active" : "Forwarding paused")
            .accessibilityValue(bridge.status.announcement)
            .accessibilityAddTraits(.updatesFrequently)
        } footer: {
            if isForwarding {
                Text("Keep RemKeys open and the screen on. Keystrokes only forward while this app is in the foreground.")
            }
        }
    }

    private var connectionSection: some View {
        Section("Windows PC") {
            LabeledContent("Tailscale address") {
                TextField("100.x.y.z", text: Binding(
                    get: { settings.targetHost },
                    set: { settings.targetHost = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .onSubmit { CaptureView.requestReclaim() }
            }
            .accessibilityHint("The target computer's Tailscale IP address")

            LabeledContent("Port") {
                TextField("5391", value: Binding(
                    get: { settings.targetPort },
                    set: { settings.targetPort = $0 }
                ), format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
            }
            .accessibilityHint("Must match the port in the Windows agent's appsettings.json")
        }
    }

    private var forwardingSection: some View {
        Section {
            Button {
                toggleForwarding()
            } label: {
                Text(isForwarding ? "Stop forwarding" : "Start forwarding")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(isForwarding ? .red : .accentColor)
            .accessibilityLabel(isForwarding ? "Stop forwarding" : "Start forwarding")
            .accessibilityHint(isForwarding
                ? "Stops sending keystrokes to the Windows PC"
                : "Connects and starts sending keystrokes to the Windows PC")
        }
        // The magic-tap tip and the rest of the teaching text live in the
        // info sheet — Start stays lean.
    }

    /// Battery saver for long forwarding sessions: black overlay + brightness
    /// zero (see `RootTabView`). Hidden entirely while VoiceOver runs —
    /// VoiceOver's own Screen Curtain (three-finger triple tap) does the same
    /// job, and the double-tap dismissal would fight VoiceOver gestures.
    private var curtainSection: some View {
        Section {
            Button("Screen curtain") {
                activateCurtain()
            }
            .accessibilityHint("Turns the screen black to save battery. Keystrokes keep forwarding.")
        } footer: {
            Text("Double-tap the screen to turn it back on.")
        }
    }

    /// Live telemetry for debugging "keys don't arrive" in the field: is a
    /// keyboard detected, does the capture view hold focus, and do presses
    /// actually reach the app?
    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Target") {
                Text(settings.targetHost.isEmpty
                     ? "Not set"
                     : "\(settings.targetHost):\(String(settings.targetPort))")
            }
            LabeledContent("Connection") {
                Text(bridge.status.announcement)
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Hardware keyboard") {
                Text(diagnostics.keyboardName ?? "None detected")
            }
            LabeledContent("Capture focus") {
                Text(diagnostics.captureViewIsFirstResponder ? "Held" : "Not held")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Key-downs seen") {
                Text("\(diagnostics.pressesSeen)")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Events forwarded") {
                Text("\(diagnostics.eventsForwarded)")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Last key seen") {
                Text(diagnostics.lastKey ?? "None yet")
            }
            .accessibilityAddTraits(.updatesFrequently)
            if diagnostics.unmappedSeen > 0 {
                LabeledContent("Unmapped key-downs") {
                    Text("\(diagnostics.unmappedSeen)")
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("If a keyboard is detected but Key-downs seen stays at zero while you type, another layer is consuming keys before they reach RemKeys — with VoiceOver running that is usually QuickNav. Try turning QuickNav off (press Left and Right arrow together) and typing again.")
        }
    }

    // MARK: Behavior

    private func toggleForwarding() {
        bridge.forwardingEnabled.toggle()
        // Take the hardware keyboard back after the button press moved focus.
        CaptureView.requestReclaim()
    }
}
