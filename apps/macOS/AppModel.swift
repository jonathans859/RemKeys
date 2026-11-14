import AppKit
import Observation
import BridgeCore

/// Owns the macOS app's long-lived objects and wires capture-state changes to
/// their side effects: the border overlay, audio cues, and VoiceOver
/// announcements.
///
/// Accessibility note: NSAccessibility announcements from a menu-bar
/// (`LSUIElement`) app are unreliable, so state is carried by **three**
/// redundant channels — a distinct audio cue, an announcement attempt, and an
/// always-current status line in the menu (`statusLine`). A screen-reader user
/// can track remote state from the sound alone without opening the menu.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let bridge: BridgeClient
    /// Saved Windows PCs. Local to this Mac: the Mac target has no iCloud
    /// entitlement (an App-ID capability breaks its CI signing), so the list
    /// the iPhone and iPad share doesn't reach it.
    let connections = ConnectionStore()
    @ObservationIgnored let capture: KeyCapture
    @ObservationIgnored private let overlay = CaptureOverlay()
    @ObservationIgnored private let updater = Updater()

    /// Build number of an update a scheduled check found and Sparkle left for
    /// us to report (see `Updater`), until the user opens the update dialog.
    private(set) var availableUpdate: String?

    /// One-line, always-current summary for the menu. Doubles as the VoiceOver
    /// value; written as a full sentence.
    private(set) var statusLine: String = "Forwarding off"

    /// Fires whenever `statusLine` / forwarding state changes, so the AppKit
    /// status item (which isn't a SwiftUI view and can't observe) can refresh
    /// its icon, tooltip and VoiceOver value.
    @ObservationIgnored var menuStateDidChange: (@MainActor () -> Void)?

    /// True while our `hidutil` fn-row remap is installed. Tracked so we only
    /// ever clear a mapping we put there ourselves — `hidutil` keeps one
    /// system-wide list per user.
    @ObservationIgnored private var functionKeyRowApplied = false

    init() {
        let settings = AppSettings()
        let bridge = BridgeClient(settings: settings)
        self.settings = settings
        self.bridge = bridge
        self.capture = KeyCapture(bridge: bridge, settings: settings)

        bridge.forwardingDidChange = { [weak self] enabled in
            self?.handleForwardingChange(enabled)
        }
        bridge.statusDidChange = { [weak self] status, previous in
            self?.handleStatusChange(status, previous: previous)
        }
        // A keystroke typed into a link that is down. Sound only: the status
        // line already says why, and announcing every burst would talk over
        // the screen reader. Throttled and gated on the setting by the bridge.
        bridge.keystrokeWasDropped = { [weak self] in
            self?.play(.dropped)
        }
        updater.availableUpdateDidChange = { [weak self] build in
            self?.handleAvailableUpdate(build)
        }
    }

    /// Install the event tap once at launch (gated behind the forwarding
    /// boolean per the UTM pattern — never rebuilt on toggle).
    func start() {
        refreshConnectionNameDraft()
        capture.start()
        refreshStatusLine()
    }

    /// Re-run permission checks + tap install after the user grants access.
    func recheck() {
        capture.recheck()
        refreshStatusLine()
    }

    /// Tear down state that outlives the process. Called from
    /// `applicationWillTerminate`, so the fn-row remap can't be left behind.
    func shutdown() {
        if functionKeyRowApplied {
            FunctionKeyRow.clear(waitForCompletion: true)
            functionKeyRowApplied = false
        }
    }

    var isForwarding: Bool { bridge.forwardingEnabled }

    func toggleForwarding() {
        capture.toggleForwarding()
    }

    // MARK: Saved connections

    /// The Name field: filled from the saved connection whenever one is
    /// selected (or the address typed matches one), saved with Add / Rename.
    var connectionNameDraft = ""

    func refreshConnectionNameDraft() {
        connectionNameDraft = connections.saved(settings.currentConnection)?.name ?? ""
    }

    private var trimmedNameDraft: String { connectionNameDraft.trimmingCharacters(in: .whitespaces) }

    var canSaveConnection: Bool {
        guard settings.currentConnection != nil else { return false }
        return connections.saved(settings.currentConnection).map { $0.name != trimmedNameDraft } ?? true
    }

    /// Says in words what the button will do.
    var saveConnectionTitle: String {
        guard let saved = connections.saved(settings.currentConnection) else { return "Add connection" }
        return saved.name == trimmedNameDraft ? "Connection saved" : "Rename connection"
    }

    /// Makes a saved connection the target; a session in progress follows it
    /// straight away.
    func selectConnection(_ connection: SavedConnection) {
        connectionNameDraft = connection.name
        guard !connection.isSameTarget(as: settings.currentConnection) else { return }
        settings.select(connection)
        if bridge.forwardingEnabled { bridge.connect() }
        announce("\(connection.displayName) selected")
    }

    /// Saves the address, port and name currently in the fields; an address
    /// already saved just takes the new name.
    func saveCurrentConnection() {
        guard let current = settings.currentConnection else { return }
        let named = SavedConnection(host: current.host, port: current.port, name: connectionNameDraft)
        switch connections.save(named) {
        case .added: announce("\(named.displayName) added")
        case .renamed: announce("Renamed to \(named.displayName)")
        case .unchanged: break
        }
        connectionNameDraft = named.name
    }

    func deleteConnection(_ connection: SavedConnection) {
        connections.delete(connection)
        announce("\(connection.displayName) deleted")
    }

    // MARK: Function-key row

    /// Mirrors `settings.forwardFunctionKeyRow`, but going through the model
    /// means flipping it mid-session installs or removes the remap right away
    /// instead of at the next forwarding toggle.
    var forwardFunctionKeyRow: Bool {
        get { settings.forwardFunctionKeyRow }
        set {
            settings.forwardFunctionKeyRow = newValue
            syncFunctionKeyRow()
        }
    }

    /// The remap is macOS-wide, so it is installed only while forwarding is
    /// actually running and removed the moment it stops.
    private func syncFunctionKeyRow() {
        let shouldApply = settings.forwardFunctionKeyRow && bridge.forwardingEnabled
        guard shouldApply != functionKeyRowApplied else { return }
        functionKeyRowApplied = shouldApply
        if shouldApply {
            FunctionKeyRow.apply()
        } else {
            FunctionKeyRow.clear()
        }
    }

    // MARK: Pointer

    /// Mirrors `settings.ignorePointerWhileForwarding`, going through the model
    /// so flipping it mid-session takes effect at once. The setting refuses to
    /// turn on without a toggle shortcut, so read it back rather than trusting
    /// `newValue`.
    var ignorePointerWhileForwarding: Bool {
        get { settings.ignorePointerWhileForwarding }
        set {
            settings.ignorePointerWhileForwarding = newValue
            syncPointerBlocking()
        }
    }

    /// The trackpad is ignored only while forwarding is actually on. The
    /// shortcut check repeats the setting's own invariant on purpose: this is
    /// the line that decides whether the user can still stop forwarding.
    private func syncPointerBlocking() {
        capture.setPointerBlocking(
            settings.ignorePointerWhileForwarding
                && settings.toggleShortcut != nil
                && bridge.forwardingEnabled
        )
    }

    // MARK: Updates

    /// Opens Sparkle's dialog: "up to date", or the waiting update.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    private func handleAvailableUpdate(_ build: String?) {
        guard build != availableUpdate else { return }
        availableUpdate = build
        if let build {
            play(.updateAvailable)
            announce("RemKeys update available, build \(build)")
        }
        refreshStatusLine()
    }

    // MARK: Toggle-shortcut recording

    var isRecordingShortcut: Bool { capture.isRecording }

    /// Arm the recorder; the next chord the user presses becomes the shortcut.
    func recordToggleShortcut() {
        capture.beginRecording { [weak self] shortcut in
            self?.settings.toggleShortcut = shortcut
            self?.announce("Toggle shortcut set to \(shortcut.displayString)")
        }
    }

    func cancelRecordingShortcut() {
        capture.cancelRecording()
    }

    func clearToggleShortcut() {
        let wasIgnoringPointer = settings.ignorePointerWhileForwarding
        settings.toggleShortcut = nil   // also turns ignoring the pointer off
        syncPointerBlocking()
        announce(wasIgnoringPointer
            ? "Toggle shortcut cleared. Ignoring the trackpad is off too, since it needs the shortcut."
            : "Toggle shortcut cleared. Use the button to toggle forwarding.")
    }

    // MARK: State side effects

    private func handleForwardingChange(_ enabled: Bool) {
        overlay.setVisible(enabled)
        syncFunctionKeyRow()
        syncPointerBlocking()
        play(enabled ? .toggleOn : .toggleOff)
        announce(enabled ? "Forwarding on" : "Forwarding off")
        refreshStatusLine()
    }

    private func handleStatusChange(_ status: BridgeClient.ConnectionStatus,
                                    previous: BridgeClient.ConnectionStatus) {
        // The status line always shows the latest reason; the cue and the
        // announcement skip failure-to-failure retries (see isWorthAnnouncing).
        if status.isWorthAnnouncing(after: previous) {
            switch status {
            case .connected: play(.connected)
            case .failed: play(.failed)
            default: break
            }
            announce(status.announcement)
        }
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        var line = bridge.forwardingEnabled
            ? "Forwarding on — \(bridge.status.announcement)"
            : "Forwarding off"
        if let availableUpdate {
            line += " · Update available (build \(availableUpdate))"
        }
        statusLine = line
        menuStateDidChange?()
    }

    // MARK: Cues

    private enum Cue: String {
        case toggleOn = "Tink"
        case toggleOff = "Pop"
        case connected = "Glass"
        case failed = "Funk"
        case updateAvailable = "Hero"
        /// Short and dry, unlike `failed`'s Funk, so "a key was lost" and
        /// "the connection failed" never blur.
        case dropped = "Bottle"
    }

    private func play(_ cue: Cue) {
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
