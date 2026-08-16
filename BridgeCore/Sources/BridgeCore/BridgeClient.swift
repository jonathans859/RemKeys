import Foundation
import Network
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
    /// Optional hook fired whenever `status` changes.
    public var statusDidChange: (@MainActor (ConnectionStatus) -> Void)?

    private let settings: AppSettings
    private var connection: NWConnection?
    /// VKs we've sent a down for but not yet an up — flushed on disconnect so
    /// the remote never gets stuck with a held key.
    private var heldKeys: Set<UInt16> = []
    /// Guards against overlapping reconnect timers.
    private var reconnectScheduled = false
    /// Bumped by every `connect()` / `disconnect()`, so a recovery scheduled
    /// for one connection can tell it no longer concerns the current one and
    /// bow out instead of tearing down a healthy successor.
    private var connectionGeneration = 0
    /// Last viability the path reported. `false` means the connection object is
    /// still `.ready` but its route is gone — the state that a moving phone
    /// (tower handover, border crossing) ends up in, and the one where sending
    /// keystrokes is pointless.
    private var pathIsViable = true

    public init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Sending

    /// Forward one physical key transition. No-op unless forwarding is on and
    /// we have a live connection; while connecting, presses are dropped rather
    /// than queued (a stale keystroke replayed seconds later is worse than a
    /// lost one for a screen-reader user).
    public func sendKey(vk: UInt16, pressed: Bool) {
        guard forwardingEnabled else { return }
        if pressed { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
        send(KeyEvent(vk: vk, pressed: pressed))
    }

    /// Type one character on the remote via the layout-independent unicode
    /// path (`char` wire line). The agent injects a full down+up, so there is
    /// no held-key bookkeeping. Same gating as `sendKey`.
    public func sendCharacter(_ scalar: Unicode.Scalar) {
        guard forwardingEnabled else { return }
        guard let connection, status.isConnected else { return }
        connection.send(content: CharEvent(scalar: scalar).wireData, completion: .contentProcessed { _ in })
    }

    private func send(_ event: KeyEvent) {
        guard let connection, status.isConnected else { return }
        connection.send(content: event.wireData, completion: .contentProcessed { _ in })
    }

    /// Emit an up for every key we believe is still held, then clear the set.
    /// Runs before a deliberate disconnect / forwarding-off.
    private func releaseHeldKeys() {
        for vk in heldKeys {
            send(KeyEvent(vk: vk, pressed: false))
        }
        heldKeys.removeAll()
    }

    // MARK: Connection lifecycle

    /// (Re)connect using the current host/port. Safe to call repeatedly; tears
    /// down any existing connection first.
    public func connect() {
        disconnect(resetStatus: false)

        let host = settings.targetHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            setStatus(.failed("No target address set"))
            return
        }
        guard let portValue = UInt16(exactly: settings.targetPort),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            setStatus(.failed("Invalid port"))
            return
        }

        setStatus(.connecting)
        connectionGeneration &+= 1
        pathIsViable = true
        // The agent starts every session holding nothing, so whatever we
        // thought was down on the old connection is not down on the new one.
        heldKeys.removeAll()

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Keep latency low: disable Nagle so single keystrokes aren't buffered.
            tcp.noDelay = true
            // Notice a link that died without closing. When the phone moves
            // between towers or countries the old path just stops carrying
            // packets — no FIN, no RST — and without keepalive this connection
            // stays `.ready` forever while every keystroke vanishes. Probe
            // after 10s idle, three times, 5s apart: dead in about 25s.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveCount = 3
            tcp.keepaliveInterval = 5
            // And when we *are* typing, don't retransmit into the void for the
            // system default (minutes). Unacknowledged for 10s means gone.
            tcp.connectionDropTime = 10
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        // A `.ready` connection whose path is no longer viable is the failure
        // mode keepalive takes ~25s to catch; this catches it in one hop.
        conn.viabilityUpdateHandler = { [weak self] viable in
            Task { @MainActor in self?.handleViability(viable) }
        }
        // Wi-Fi came back, or a better interface appeared: retry a connection
        // that is currently stuck waiting, right away, instead of sitting out
        // the recovery delay. A healthy connection is left alone — see
        // handleBetterPath.
        conn.betterPathUpdateHandler = { [weak self] available in
            Task { @MainActor in self?.handleBetterPath(available) }
        }
        connection = conn
        conn.start(queue: .main)
    }

    /// Tear down the connection. Keeps `status` unless asked to reset it, so an
    /// internal reconnect doesn't flicker the UI to `.idle`.
    public func disconnect(resetStatus: Bool = true) {
        connectionGeneration &+= 1
        connection?.cancel()
        connection = nil
        if resetStatus {
            heldKeys.removeAll()
            setStatus(.idle)
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            setStatus(.connected)
        case .waiting(let error):
            // Reachability problem (host down, no route). Network.framework
            // keeps the connection and retries on its own — but a connection
            // that started on a network the device has since left can wait
            // forever, so rebuild it if it hasn't recovered shortly.
            setStatus(.failed(Self.describe(error)))
            scheduleRecovery(after: 10)
        case .failed(let error):
            setStatus(.failed(Self.describe(error)))
            scheduleRecovery(after: 2)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleViability(_ viable: Bool) {
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
        if let connection, case .ready = connection.state {
            setStatus(.connected)
        }
    }

    /// `scheduleRecovery` bows out if the connection is healthy, so this only
    /// ever rescues a stuck one. That is deliberate: hopping a *working*
    /// connection onto a new interface would drop keystrokes for no gain —
    /// and over Tailscale the socket lives on the tunnel interface anyway, so
    /// the interface underneath it changing is not our business.
    private func handleBetterPath(_ available: Bool) {
        guard available, forwardingEnabled else { return }
        scheduleRecovery(after: 1)
    }

    /// Rebuild the connection after `seconds`, unless it has recovered on its
    /// own by then or has been superseded in the meantime. One timer at a time:
    /// the triggers overlap (a dead path usually reports non-viable *and*
    /// fails), and reconnecting twice would just interrupt itself.
    private func scheduleRecovery(after seconds: Int) {
        guard forwardingEnabled, !reconnectScheduled else { return }
        reconnectScheduled = true
        let generation = connectionGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            self.reconnectScheduled = false
            guard self.forwardingEnabled, self.connectionGeneration == generation else { return }
            guard !(self.status.isConnected && self.pathIsViable) else { return }
            self.connect()
        }
    }

    private func setStatus(_ newStatus: ConnectionStatus) {
        guard newStatus != status else { return }
        status = newStatus
        statusDidChange?(newStatus)
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        default: return error.localizedDescription
        }
    }
}
