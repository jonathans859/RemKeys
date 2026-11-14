import Foundation

/// The part of a connection that `BridgeClient` uses. Separated out so the
/// client's reconnect logic can be driven by a fake in tests, and so the client
/// itself builds without Network.framework. The real one is
/// `NWConnectionTransport`.
///
/// Contract: every handler and every send completion runs on the main actor.
/// None of them is called from inside `start()`, `send` or `cancel()`.
@MainActor
protocol BridgeTransport: AnyObject {
    /// Connection state changes (`NWConnection.stateUpdateHandler`).
    var stateHandler: ((TransportState) -> Void)? { get set }
    /// Path viability changes (`NWConnection.viabilityUpdateHandler`).
    var viabilityHandler: ((Bool) -> Void)? { get set }
    /// A better path appeared or went away (`betterPathUpdateHandler`).
    var betterPathHandler: ((Bool) -> Void)? { get set }
    /// Whether the connection is `.ready` right now.
    var isReady: Bool { get }

    func start()
    /// Hand bytes over. The completion gets nil once the transport has taken
    /// them, which says nothing about whether the PC got them, or an error
    /// when the transport refused them.
    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void)
    func cancel()
}

/// The `NWConnection.State`s the client acts on. Errors are already turned
/// into the sentence the status line shows.
enum TransportState: Equatable {
    case ready
    /// No route right now. The transport keeps retrying by itself.
    case waiting(String)
    case failed(String)
    case cancelled
    /// `.setup` / `.preparing`: nothing to do.
    case other
}

/// Builds a transport for one connection attempt to host:port.
typealias BridgeTransportFactory = @MainActor (_ host: String, _ port: UInt16) -> BridgeTransport
