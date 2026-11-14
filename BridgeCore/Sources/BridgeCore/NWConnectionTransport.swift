#if canImport(Network)
import Foundation
import Network

/// `BridgeTransport` over a Network.framework TCP connection: the real one.
@MainActor
final class NWConnectionTransport: BridgeTransport {
    var stateHandler: ((TransportState) -> Void)?
    var viabilityHandler: ((Bool) -> Void)?
    var betterPathHandler: ((Bool) -> Void)?

    private let connection: NWConnection

    init(host: String, port: UInt16) {
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
        // `Port(rawValue:)` only fails for values a UInt16 can't hold, and the
        // client has already rejected port 0.
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? .any,
                                  using: params)
    }

    var isReady: Bool {
        if case .ready = connection.state { return true }
        return false
    }

    func start() {
        // Callbacks hop to the main actor in a Task rather than running inline,
        // so none of them can land inside one of our own calls.
        connection.stateUpdateHandler = { [weak self] state in
            let mapped = Self.map(state)
            Task { @MainActor in self?.stateHandler?(mapped) }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            Task { @MainActor in self?.viabilityHandler?(viable) }
        }
        connection.betterPathUpdateHandler = { [weak self] available in
            Task { @MainActor in self?.betterPathHandler?(available) }
        }
        connection.start(queue: .main)
    }

    /// Completions run on `.main`, where the connection was started.
    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            MainActor.assumeIsolated { completion(error) }
        })
    }

    func cancel() {
        connection.cancel()
    }

    private nonisolated static func map(_ state: NWConnection.State) -> TransportState {
        switch state {
        case .ready: return .ready
        case .waiting(let error): return .waiting(describe(error))
        case .failed(let error): return .failed(describe(error))
        case .cancelled: return .cancelled
        default: return .other
        }
    }

    private nonisolated static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        default: return error.localizedDescription
        }
    }
}
#endif
