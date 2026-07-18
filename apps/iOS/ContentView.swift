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

    private var diagnostics: CaptureDiagnostics { .shared }

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
                    diagnosticsSection
                }
                .navigationTitle("RemKeys")
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
        } footer: {
            Text("Tip: two-finger double tap anywhere toggles forwarding. On the Virtual Input tab, the same gesture sends the built combination instead.")
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
