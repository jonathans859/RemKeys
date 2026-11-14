import Foundation

/// One remembered Windows PC: an address, the agent's port, and an optional
/// friendly name. `host:port` *is* the identity — the same address on another
/// port is another agent — and the name is the only part that can change.
public struct SavedConnection: Codable, Hashable, Identifiable, Sendable {
    public var host: String
    public var port: Int
    /// Empty when the user gave none.
    public var name: String

    public init(host: String, port: Int, name: String = "") {
        self.host = host
        self.port = port
        self.name = name.trimmingCharacters(in: .whitespaces)
    }

    public var id: String { address }

    /// `host:port`.
    public var address: String { "\(host):\(port)" }

    /// What the row shows and VoiceOver speaks: the name, else the address.
    public var displayName: String { name.isEmpty ? address : name }

    /// Same PC, whatever either is called.
    public func isSameTarget(as other: SavedConnection?) -> Bool { id == other?.id }

    // Tolerates records written before names existed.
    private enum CodingKeys: String, CodingKey { case host, port, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}
