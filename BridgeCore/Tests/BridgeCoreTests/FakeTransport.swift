import Foundation
@testable import BridgeCore

/// A transport the test drives by hand: it records what the client did to it,
/// and the test plays the network's part by calling `deliver`.
@MainActor
final class FakeTransport: BridgeTransport {
    let host: String
    let port: UInt16
    var stateHandler: ((TransportState) -> Void)?
    var viabilityHandler: ((Bool) -> Void)?
    var betterPathHandler: ((Bool) -> Void)?

    private(set) var started = false
    private(set) var cancelled = false
    /// Every wire line sent, decoded.
    private(set) var sent: [String] = []
    /// When set, every send completes with this error.
    var sendError: Error?
    var isReady = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() { started = true }

    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        sent.append(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines))
        completion(sendError)
    }

    func cancel() { cancelled = true }

    func clearSent() { sent.removeAll() }

    /// Play the network: report a state change.
    func deliver(_ state: TransportState) {
        isReady = state == .ready
        stateHandler?(state)
    }
}

/// Makes and keeps every transport the client asks for.
@MainActor
final class FakeTransportFactory {
    private(set) var made: [FakeTransport] = []
    var latest: FakeTransport? { made.last }

    func make(host: String, port: UInt16) -> BridgeTransport {
        let transport = FakeTransport(host: host, port: port)
        made.append(transport)
        return transport
    }
}

/// A recovery timer that only goes off when the test says so.
@MainActor
final class ManualSleeper {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pending: Int { waiters.count }

    nonisolated func sleep(_ duration: Duration) async throws {
        await wait(duration)
    }

    private func wait(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Fire every pending timer, then let their tasks run.
    func fireAll() async {
        let fired = waiters
        waiters.removeAll()
        fired.forEach { $0.resume() }
        await settle()
    }
}

/// Let pending main-actor tasks run.
@MainActor
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

struct FakeSendError: Error {}
