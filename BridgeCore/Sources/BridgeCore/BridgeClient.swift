import Foundation
import Observation

/// TCP client that ships key transitions to the Windows agent over Tailscale.
///
/// Tailscale already encrypts and authenticates the link, so there is no
/// app-level crypto here — just a plain framed-text connection to a
/// user-supplied IP. The connection is kept alive while forwarding is enabled
/// and transparently re-established if it drops.
@Observable
@MainActor
public final class BridgeClient {
    public enum ConnectionStatus: Equatable, Sendable {
        case idle              // forwarding off, no connection wanted
        case connecting
        case connected
        case failed(String)    // last error; we keep retrying while enabled

        /// Full-sentence description — doubles as the VoiceOver value/status
        /// line, so it is written to be read aloud verbatim.
        public var announcement: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .failed(let message): return "Connection failed: \(message)"
            }
        }

        public var isConnected: Bool { self == .connected }

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        /// Whether moving from `previous` to this status is news worth an
        /// announcement or audio cue. One failure followed by another — the
        /// automatic retries while the PC is asleep or out of reach, each with
        /// its own error text — is not: the status line still shows the latest
        /// reason, but speaking every attempt would repeat indefinitely,
        /// under the screen curtain too.
        public func isWorthAnnouncing(after previous: ConnectionStatus) -> Bool {
            !(isFailed && previous.isFailed)
        }
    }

    /// Master gate. Capture code checks this before forwarding; flipping it
    /// starts/stops the connection and flushes held keys so a chord can't
    /// strand a modifier on the remote.
    public var forwardingEnabled: Bool = false {
        didSet {
            guard forwardingEnabled != oldValue else { return }
            if forwardingEnabled {
                connect()
            } else {
                releaseHeldKeys()
                disconnect()
            }
            forwardingDidChange?(forwardingEnabled)
        }
    }

    /// Observable connection state for the UI / accessibility layer.
    public private(set) var status: ConnectionStatus = .idle

    /// Optional hook fired after `forwardingEnabled` changes (used by the apps
    /// to post an announcement / play an audio cue on the same thread).
    public var forwardingDidChange: (@MainActor (Bool) -> Void)?
    /// Optional hook fired whenever `status` changes, with the new status and
    /// the one it replaced (see `ConnectionStatus.isWorthAnnouncing(after:)`).
    public var statusDidChange: (@MainActor (_ status: ConnectionStatus, _ previous: ConnectionStatus) -> Void)?
    /// Optional hook fired when a keystroke the user typed was lost instead of
    /// sent: forwarding is on but there is no live connection, or the
    /// transport refused the write. The apps turn it into a tick so typing
    /// into a dead link is noticed. Only key-downs and characters count —
    /// never key-ups or the synthetic releases from `releaseHeldKeys()` — and
    /// it is throttled: the first drop fires at once, then at most once per
    /// `dropCueInterval` until a write succeeds again. Gated on
    /// `AppSettings.dropCueEnabled`.
    ///
    /// A missing tick is not proof of delivery: keys written into a link that
    /// died without closing look sent until keepalive notices (~10–25s).
    public var keystrokeWasDropped: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var connection: BridgeTransport?
    /// Builds the transport for each connection attempt. Network.framework in
    /// the apps, a fake in tests.
    @ObservationIgnored private let makeTransport: BridgeTransportFactory
    /// How a recovery timer waits. `Task.sleep` in the apps; tests swap it so
    /// they don't sit out real reconnect delays.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// How the heartbeat waits between beats. Separate from `sleep` so tests
    /// can fire recovery timers and heartbeats independently.
    @ObservationIgnored private let heartbeatSleep: @Sendable (Duration) async throws -> Void
    /// VKs we've sent a down for but not yet an up — flushed on disconnect so
    /// the remote never gets stuck with a held key.
    @ObservationIgnored private var heldKeys: Set<UInt16> = [] {
        didSet { updateHeartbeat() }
    }
    /// Sends `Heartbeat` every `Heartbeat.interval` while any key is held, so
    /// the agent can tell a held key from a stalled link. Nil while nothing is
    /// held: an idle connection carries no extra traffic.
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// The pending reconnect timer, if any. One at a time, and owned by the
    /// connection it was scheduled for: `connect()` / `disconnect()` cancel it,
    /// so a timer left over from a previous connection can neither block the
    /// current one from scheduling its own recovery nor act on it.
    private var recoveryTask: Task<Void, Never>?
    /// Bumped by every `connect()` / `disconnect()`, so a recovery scheduled
    /// for one connection can tell it no longer concerns the current one and
    /// bow out instead of tearing down a healthy successor.
    private var connectionGeneration = 0
    /// Last viability the path reported. `false` means the connection object is
    /// still `.ready` but its route is gone — the state that a moving phone
    /// (tower handover, border crossing) ends up in, and the one where sending
    /// keystrokes is pointless.
    private var pathIsViable = true
    /// When `keystrokeWasDropped` last fired; nil once a write has succeeded
    /// since, so the next drop is heard immediately.
    @ObservationIgnored private var lastDropCue: ContinuousClock.Instant?
    /// Minimum gap between drop cues while drops continue. Typing into a dead
    /// link loses tens of keys a second; one tick each would be a buzz.
    @ObservationIgnored var dropCueInterval: Duration = .seconds(1)

    #if canImport(Network)
    public convenience init(settings: AppSettings) {
        self.init(settings: settings,
                  transportFactory: { NWConnectionTransport(host: $0, port: $1) })
    }
    #endif

    /// The seam: everything the client does to a connection goes through
    /// `transportFactory`'s transports, and every reconnect delay through
    /// `sleep`.
    init(settings: AppSettings,
         transportFactory: @escaping BridgeTransportFactory,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         heartbeatSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.settings = settings
        self.makeTransport = transportFactory
        self.sleep = sleep
        self.heartbeatSleep = heartbeatSleep
    }

    // MARK: Sending

    /// Forward one physical key transition. Returns whether it was actually
    /// written to the connection, so callers count real sends only.
    ///
    /// Nothing is sent unless forwarding is on and we have a live connection;
    /// while connecting, presses are dropped rather than queued (a stale
    /// keystroke replayed seconds later is worse than a lost one for a
    /// screen-reader user) and a dropped press fires `keystrokeWasDropped`.
    /// A release is sent only for a key whose press went out: the PC never
    /// saw a dropped press, and a lone Alt up focuses the menu bar in many
    /// Windows apps.
    @discardableResult
    public func sendKey(vk: UInt16, pressed: Bool) -> Bool {
        guard forwardingEnabled else { return false }
        if !pressed, !heldKeys.contains(vk) { return false }
        guard write(KeyEvent(vk: vk, pressed: pressed).wireData, cueIfLost: pressed) else {
            if pressed { noteDrop() }
            return false
        }
        if pressed { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
        return true
    }

    /// Type one character on the remote via the layout-independent unicode
    /// path (`char` wire line). The agent injects a full down+up, so there is
    /// no held-key bookkeeping. Same gating, return value and drop cue as
    /// `sendKey` — a whole string sent at once ticks once, by the throttle.
    @discardableResult
    public func sendCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard forwardingEnabled else { return false }
        guard write(CharEvent(scalar: scalar).wireData, cueIfLost: true) else {
            noteDrop()
            return false
        }
        return true
    }

    /// Hand one wire line to the connection; false when there is no live one.
    /// `.contentProcessed` means Network.framework took the bytes, not that
    /// the PC got them — an error there is a write the transport refused, so
    /// it counts as a drop (when `cueIfLost`), and success re-arms the cue.
    private func write(_ data: Data, cueIfLost: Bool) -> Bool {
        guard let connection, status.isConnected else { return false }
        connection.send(data) { [weak self] error in
            guard let self else { return }
            if error == nil {
                if self.lastDropCue != nil { self.lastDropCue = nil }
            } else if cueIfLost {
                self.noteDrop()
            }
        }
        return true
    }

    /// Fire `keystrokeWasDropped`, throttled (see there).
    private func noteDrop() {
        guard settings.dropCueEnabled, let keystrokeWasDropped else { return }
        let now = ContinuousClock.now
        if let lastDropCue, now - lastDropCue < dropCueInterval { return }
        lastDropCue = now
        keystrokeWasDropped()
    }

    /// Start or stop the heartbeat to match `heldKeys`. The beat keeps going
    /// across a connection that is briefly not `.connected` (its writes just
    /// fail quietly); `connect()` empties `heldKeys`, which stops it.
    private func updateHeartbeat() {
        if heldKeys.isEmpty {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }
        let sleep = heartbeatSleep
        heartbeatTask = Task { @MainActor [weak self] in
            while true {
                // Cancelled means `heldKeys` emptied and a later hold may
                // already own `heartbeatTask` — leave it alone.
                do { try await sleep(Heartbeat.interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                // Never a drop cue: a heartbeat is not a keystroke.
                _ = self.write(Heartbeat.wireData, cueIfLost: false)
            }
        }
    }

    /// Emit an up for every key we believe is still held, then clear the set.
    /// Runs before a deliberate disconnect / forwarding-off, and whenever the
    /// capture layer stops being able to see key-ups — an iOS app that goes
    /// inactive (Control Center, the app switcher) keeps forwarding, but a key
    /// that was physically down when the overlay appeared may never report its
    /// release, and the agent would repeat it forever.
    public func releaseHeldKeys() {
        for vk in heldKeys {
            _ = write(KeyEvent(vk: vk, pressed: false).wireData, cueIfLost: false)
        }
        heldKeys.removeAll()
    }

    // MARK: Connection lifecycle

    /// (Re)connect using the current host/port. Safe to call repeatedly; tears
    /// down any existing connection first.
    public func connect() {
        connect(isAutomaticRetry: false)
    }

    /// `isAutomaticRetry`: a rebuild the client scheduled itself. If the link
    /// is already down, the status stays at that failure instead of passing
    /// through `.connecting` — otherwise every retry against an unreachable PC
    /// flips the status twice and the apps announce both, every 10 seconds.
    private func connect(isAutomaticRetry: Bool) {
        disconnect(resetStatus: false)

        let host = settings.targetHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            setStatus(.failed("No target address set"))
            return
        }
        guard let port = UInt16(exactly: settings.targetPort), port != 0 else {
            setStatus(.failed("Invalid port"))
            return
        }

        if !(isAutomaticRetry && status.isFailed) {
            setStatus(.connecting)
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        pathIsViable = true
        // The agent starts every session holding nothing, so whatever we
        // thought was down on the old connection is not down on the new one.
        heldKeys.removeAll()

        // TCP options (no Nagle, keepalive, drop time) are the transport's
        // business: see `NWConnectionTransport`.
        let conn = makeTransport(host, port)
        // Every handler carries the generation it was created for, so a late
        // callback from a connection that has since been replaced can't touch
        // the status or schedule recovery on behalf of its successor.
        conn.stateHandler = { [weak self] state in
            self?.handleState(state, generation: generation)
        }
        // A `.ready` connection whose path is no longer viable is the failure
        // mode keepalive takes ~25s to catch; this catches it in one hop.
        conn.viabilityHandler = { [weak self] viable in
            self?.handleViability(viable, generation: generation)
        }
        // Wi-Fi came back, or a better interface appeared: retry a connection
        // that is currently stuck waiting, right away, instead of sitting out
        // the recovery delay. A healthy connection is left alone — see
        // handleBetterPath.
        conn.betterPathHandler = { [weak self] available in
            self?.handleBetterPath(available, generation: generation)
        }
        connection = conn
        conn.start()
    }

    /// Tear down the connection. Keeps `status` unless asked to reset it, so an
    /// internal reconnect doesn't flicker the UI to `.idle`.
    public func disconnect(resetStatus: Bool = true) {
        connectionGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        connection?.cancel()
        connection = nil
        if resetStatus {
            heldKeys.removeAll()
            setStatus(.idle)
        }
    }

    private func handleState(_ state: TransportState, generation: Int) {
        guard generation == connectionGeneration else { return }
        switch state {
        case .ready:
            setStatus(.connected)
            // Tells the agent this peer keeps the held-key lease, before any
            // key can be held — see `Heartbeat`. Older agents log it as an
            // unknown line and carry on.
            _ = write(Heartbeat.wireData, cueIfLost: false)
        case .waiting(let error):
            // Reachability problem (host down, no route). Network.framework
            // keeps the connection and retries on its own — but a connection
            // that started on a network the device has since left can wait
            // forever, so rebuild it if it hasn't recovered shortly.
            setStatus(.failed(error))
            scheduleRecovery(after: 10)
        case .failed(let error):
            setStatus(.failed(error))
            scheduleRecovery(after: 2)
        case .cancelled, .other:
            break
        }
    }

    private func handleViability(_ viable: Bool, generation: Int) {
        guard generation == connectionGeneration else { return }
        pathIsViable = viable
        guard forwardingEnabled else { return }
        guard viable else {
            setStatus(.failed("Network connection lost"))
            // Give the path a moment to come back on its own (a brief cellular
            // gap) before spending a reconnect on it.
            scheduleRecovery(after: 3)
            return
        }
        // Came back on the same path before the recovery fired.
        if let connection, connection.isReady {
            setStatus(.connected)
        }
    }

    /// `scheduleRecovery` bows out if the connection is healthy, so this only
    /// ever rescues a stuck one. That is deliberate: hopping a *working*
    /// connection onto a new interface would drop keystrokes for no gain —
    /// and over Tailscale the socket lives on the tunnel interface anyway, so
    /// the interface underneath it changing is not our business.
    private func handleBetterPath(_ available: Bool, generation: Int) {
        guard generation == connectionGeneration, available, forwardingEnabled else { return }
        scheduleRecovery(after: 1)
    }

    /// Rebuild the connection after `seconds`, unless it has recovered on its
    /// own by then or has been superseded in the meantime. One timer at a time:
    /// the triggers overlap (a dead path usually reports non-viable *and*
    /// fails), and reconnecting twice would just interrupt itself.
    private func scheduleRecovery(after seconds: Int) {
        guard forwardingEnabled, recoveryTask == nil else { return }
        let generation = connectionGeneration
        let sleep = self.sleep
        recoveryTask = Task { @MainActor [weak self] in
            // Cancelled means connect()/disconnect() superseded this timer and
            // may already have scheduled a new one — leave `recoveryTask` alone.
            do { try await sleep(.seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard self.forwardingEnabled, self.connectionGeneration == generation else { return }
            guard !(self.status.isConnected && self.pathIsViable) else { return }
            self.connect(isAutomaticRetry: true)
        }
    }

    private func setStatus(_ newStatus: ConnectionStatus) {
        guard newStatus != status else { return }
        let previous = status
        status = newStatus
        statusDidChange?(newStatus, previous)
    }
}
