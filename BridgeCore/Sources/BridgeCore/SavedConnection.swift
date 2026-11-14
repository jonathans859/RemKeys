import Foundation

/// One remembered Windows PC: an address and the agent's port. The pair *is*
/// the identity — the same address on another port is another agent — so
/// there is no separate id or name to keep in sync.
public struct SavedConnection: Codable, Hashable, Identifiable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var id: String { displayName }

    /// `host:port`, the form it is shown, spoken and matched in.
    public var displayName: String { "\(host):\(port)" }
}
