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
///
/// The screen is one **hero card** — state, connection line, and both of the
/// buttons a session is driven by (Start/Stop, then the screen curtain at the
/// same size directly under it) — over a single "Windows PC" section. All four
/// used to be separate `Form` rows in three sections with a paragraph of
/// footer between them, which buried the only things this tab is for.
/// Everything that explains rather than reports lives in the info sheet,
/// reachable from the toolbar.
struct ContentView: View {
    let settings: AppSettings
    let bridge: BridgeClient
    /// Saved Windows PCs, synced between iPhone and iPad through iCloud.
    let connections: ConnectionStore
    /// Raises the screen curtain, which lives in `RootTabView` so its overlay
    /// covers the tab bar too.
    let activateCurtain: () -> Void

    private var diagnostics: CaptureDiagnostics { .shared }

    private var isForwarding: Bool { bridge.forwardingEnabled }

    @State private var showInfo = false
    /// The Name field. Not a setting of its own: it is filled from the saved
    /// connection whenever one is selected, and saved with Add / Rename.
    @State private var nameDraft = ""

    var body: some View {
        ZStack {
            // Invisible first-responder view: the actual capture surface. It
            // sits behind the UI and holds the hardware keyboard.
            KeyboardCapture(bridge: bridge, settings: settings)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            NavigationStack {
                Form {
                    heroSection
                    connectionSection
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
            Section {
                Text("While forwarding is active, keys typed on a connected hardware keyboard are sent to the Windows PC instead of acting here. Keystrokes only forward while RemKeys is in the foreground with the screen on — that is an iOS rule, so the screen is kept awake while forwarding runs.")
                Text("Pulling down Control Center or the notifications, or glancing at the app switcher, does not stop forwarding: keys simply pause until RemKeys is in front again. Forwarding stops when you actually leave the app.")
            } header: {
                SectionHeader("How forwarding works", systemImage: "arrow.left.arrow.right")
            }
            Section {
                Text("A two-finger double tap anywhere toggles forwarding (on the Virtual Input tab it sends the built combination instead). A physical toggle shortcut can be recorded in Settings.")
                Text("The screen curtain blacks out the display to save battery on long sessions — forwarding keeps running. Double-tap the screen to turn it back on. Settings can raise it by itself as soon as a session connects with a keyboard attached. Locking the phone or leaving the app takes it down again.")
            } header: {
                SectionHeader("Tips", systemImage: "lightbulb")
            }
            diagnosticsSection
        }
    }

    // MARK: Sections

    /// State and action in one panel. The card fills with the accent while a
    /// session is live, so "is it on?" is answerable at a glance without
    /// reading a word.
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    statusDot
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isForwarding ? "Forwarding active" : "Forwarding paused")
                            .font(.title3.weight(.semibold))
                        Text(bridge.status.announcement)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(isForwarding ? "Forwarding active" : "Forwarding paused")
                .accessibilityValue(bridge.status.announcement)
                .accessibilityAddTraits(.updatesFrequently)

                // The two things this screen is for, stacked and the same
                // size. The curtain used to be a plain text row in a section
                // of its own further down; it is pressed just as often as
                // Start is (it is how a long session begins), so it gets a
                // button of the same weight, immediately below.
                VStack(spacing: 10) {
                    Button {
                        toggleForwarding()
                    } label: {
                        Text(isForwarding ? "Stop forwarding" : "Start forwarding")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(isForwarding ? .red : .accentColor)
                    .accessibilityHint(isForwarding
                        ? "Stops sending keystrokes to the Windows PC"
                        : "Connects and starts sending keystrokes to the Windows PC")

                    Button {
                        activateCurtain()
                    } label: {
                        Label("Turn the screen off", systemImage: "moon.fill")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    // Bordered, not prominent: same footprint as Start, but
                    // clearly the second of the two.
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    // No accessibilityLabel override anywhere in this stack:
                    // Voice Control matches on the visible text, so a label
                    // and its button must not drift apart.
                    .accessibilityHint("Blacks the screen out to save battery. Keystrokes keep forwarding. Double-tap the screen to turn it back on.")
                }
            }
            .remKeysCard(active: isForwarding)
            .cardRow()
        } footer: {
            Text("Double-tap the screen to turn it back on.")
        }
    }

    /// A status LED rather than a symbol: green live, amber reaching for the
    /// PC, grey idle. The halo is what makes a 14-point dot findable at a
    /// glance; the dot itself is decorative, since the card's own label and
    /// value already carry the state to VoiceOver.
    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.20))
                .frame(width: 38, height: 38)
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
        }
        .accessibilityHidden(true)
    }

    private var statusColor: Color {
        guard isForwarding else { return .secondary }
        return bridge.status.isConnected ? .green : .orange
    }

    private var connectionSection: some View {
        Section {
            // Saved connections first: a plain list, each row a button that
            // makes it the target. Delete comes from `onDelete`, which VoiceOver
            // offers as the row's own Delete action — no extra actions added,
            // so nothing shows up twice (see the note on `PadListView`).
            ForEach(connections.connections) { connection in
                savedConnectionRow(connection)
            }
            .onDelete { offsets in
                let doomed = offsets.map { connections.connections[$0] }
                doomed.forEach(connections.delete)
                postQueuedAnnouncement("\(doomed.map(\.displayName).joined(separator: ", ")) deleted")
            }

            // "IP address", not "Tailscale address": Tailscale is how this is
            // expected to be used and what the placeholder shows, but nothing
            // in the app requires it — a plain LAN address works exactly the
            // same, and the old label read as a requirement.
            LabeledContent("IP address") {
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
            .accessibilityHint("The Windows PC's address: its Tailscale IP, or a local one if both machines are on the same network")

            LabeledContent("Port") {
                TextField("5391", value: Binding(
                    get: { settings.targetPort },
                    set: { settings.targetPort = $0 }
                ), format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
            }
            .accessibilityHint("Must match the port in the Windows agent's appsettings.json")

            LabeledContent("Name") {
                TextField("Optional, e.g. Office PC", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { CaptureView.requestReclaim() }
            }
            .accessibilityHint("A friendly name the list shows instead of the address")

            Button {
                saveConnection()
            } label: {
                Label(saveButtonTitle, systemImage: saveButtonIcon)
            }
            .disabled(!canSave)
            .accessibilityHint("Saves the IP address, port and name above to the list of connections, on your iPhone and iPad")
        } header: {
            SectionHeader("Windows PC", systemImage: "desktopcomputer")
        }
        .onAppear { nameDraft = savedCurrent?.name ?? "" }
        // Typing another address must not carry the previous PC's name along.
        .onChange(of: settings.currentConnection?.id) { nameDraft = savedCurrent?.name ?? "" }
    }

    /// The saved entry for what the fields hold now, if there is one.
    private var savedCurrent: SavedConnection? { connections.saved(settings.currentConnection) }

    private var trimmedNameDraft: String { nameDraft.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        guard settings.currentConnection != nil else { return false }
        return savedCurrent.map { $0.name != trimmedNameDraft } ?? true
    }

    /// Says in words what pressing it will do — the visible title is what
    /// VoiceOver reads and Voice Control matches.
    private var saveButtonTitle: String {
        guard let saved = savedCurrent else { return "Add connection" }
        return saved.name == trimmedNameDraft ? "Connection saved" : "Rename connection"
    }

    private var saveButtonIcon: String {
        guard let saved = savedCurrent else { return "plus.circle" }
        return saved.name == trimmedNameDraft ? "checkmark.circle" : "pencil.circle"
    }

    private func savedConnectionRow(_ connection: SavedConnection) -> some View {
        let isSelected = connection.isSameTarget(as: settings.currentConnection)
        return Button {
            select(connection)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .foregroundStyle(.primary)
                    if !connection.name.isEmpty {
                        Text(connection.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        // The visible name is the label, so Voice Control can say "Tap Office
        // PC"; the address rides in the value, the selection in the Selected
        // trait, not just the checkmark.
        .accessibilityLabel(connection.displayName)
        .accessibilityValue(connection.name.isEmpty ? "" : connection.address)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "" : "Makes this the Windows PC to connect to")
    }

    private func select(_ connection: SavedConnection) {
        nameDraft = connection.name
        guard !connection.isSameTarget(as: settings.currentConnection) else { return }
        settings.select(connection)
        // A session in progress follows the new target straight away.
        if bridge.forwardingEnabled { bridge.connect() }
        postQueuedAnnouncement("\(connection.displayName) selected")
        CaptureView.requestReclaim()
    }

    private func saveConnection() {
        guard let current = settings.currentConnection else { return }
        let named = SavedConnection(host: current.host, port: current.port, name: nameDraft)
        switch connections.save(named) {
        case .added: postQueuedAnnouncement("\(named.displayName) added")
        case .renamed: postQueuedAnnouncement("Renamed to \(named.displayName)")
        case .unchanged: break
        }
        nameDraft = named.name
        CaptureView.requestReclaim()
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
            LabeledContent("HID capture") {
                Text(diagnostics.gameControllerIsLive
                     ? "Live, \(diagnostics.gameControllerKeysSeen) events"
                     : "No events yet")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Last HID key") {
                Text(diagnostics.lastGameControllerKey ?? "None yet")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent("Command chords claimed") {
                Text("\(diagnostics.chordsClaimed)")
            }
            .accessibilityAddTraits(.updatesFrequently)
            if diagnostics.unmappedSeen > 0 {
                LabeledContent("Unmapped key-downs") {
                    Text("\(diagnostics.unmappedSeen)")
                }
            }
        } header: {
            SectionHeader("Diagnostics", systemImage: "waveform.path.ecg")
        } footer: {
            Text("If a keyboard is detected but Key-downs seen stays at zero while you type, another layer is consuming keys before they reach RemKeys — with VoiceOver running that is usually QuickNav. Try turning QuickNav off (press Left and Right arrow together) and typing again. Key-downs seen counts keys UIKit delivers; HID capture counts the same keys read straight from the keyboard, which is the path that still sees Command chords when the system keeps them.")
        }
    }

    // MARK: Behavior

    private func toggleForwarding() {
        bridge.forwardingEnabled.toggle()
        // Take the hardware keyboard back after the button press moved focus.
        CaptureView.requestReclaim()
    }
}
