import SwiftUI
import UIKit
import BridgeCore

/// Root iOS screen.
///
/// Physical keyboard input only reaches an iOS app while it is foreground and
/// the screen is on — a sandbox restriction with no background workaround. The
/// UI is therefore built around a clear, always-visible "forwarding active"
/// state, and the idle timer is held off while forwarding so the screen never
/// sleeps out from under the user.
struct ContentView: View {
    let settings: AppSettings
    let bridge: BridgeClient

    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private var isForwarding: Bool { bridge.forwardingEnabled }

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
                }
                .navigationTitle("KeyBridge")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityHint("Modifier key mappings")
                    }
                }
                .sheet(isPresented: $showingSettings, onDismiss: {
                    // A text field in settings stole first responder; give it
                    // back to the capture view so keys flow again.
                    CaptureView.requestReclaim()
                }) {
                    SettingsView(settings: settings)
                }
            }
        }
        // The app's single most important toggle — reachable from anywhere in
        // the screen with a two-finger double tap.
        .accessibilityAction(.magicTap) { toggleForwarding() }
        .onAppear { wireUpBridge() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground means we can't capture anyway; stop
            // forwarding so the remote never sits with a half-held chord.
            if phase != .active, bridge.forwardingEnabled {
                bridge.forwardingEnabled = false
            }
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
                Text("Keep KeyBridge open and the screen on. Keystrokes only forward while this app is in the foreground.")
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
        } footer: {
            Text("Tip: two-finger double tap anywhere toggles forwarding.")
        }
    }

    // MARK: Behavior

    private func toggleForwarding() {
        bridge.forwardingEnabled.toggle()
        // Take the hardware keyboard back after the button press moved focus.
        CaptureView.requestReclaim()
    }

    /// Wire bridge callbacks to VoiceOver announcements and the idle timer.
    /// Announcements are the accessible channel for state a sighted user reads
    /// off the border/icon.
    private func wireUpBridge() {
        bridge.forwardingDidChange = { enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled
            UIAccessibility.post(
                notification: .announcement,
                argument: enabled ? "Forwarding on" : "Forwarding off"
            )
        }
        bridge.statusDidChange = { status in
            UIAccessibility.post(notification: .announcement, argument: status.announcement)
        }
    }
}
