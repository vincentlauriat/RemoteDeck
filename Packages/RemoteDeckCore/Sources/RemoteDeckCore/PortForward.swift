import Foundation

/// One saved local (`-L`) port forward of an SSH machine (BackendSchema › PortForward). Not an entity:
/// a list of them is JSON in `Machine.portForwardsData`, synced with the machine. The run-time state
/// (starting, active, failed, stopped) is never stored.
public struct PortForward: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Shown instead of `localhost:8080 → localhost:80` when set.
    public var label: String?
    /// 1024–65535, listened on loopback only; unique within the machine.
    public var localPort: Int
    /// Resolved on the server side; `localhost` is the machine itself.
    public var remoteHost: String = "localhost"
    /// 1–65535.
    public var remotePort: Int

    public init(id: UUID = UUID(), label: String? = nil, localPort: Int, remoteHost: String = "localhost",
                remotePort: Int) {
        self.id = id
        self.label = label
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    /// `portForwardsData` → forwards; nil or data that does not decode (a newer or damaged record)
    /// reads as none.
    static func decodeList(_ data: Data?) -> [PortForward] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([PortForward].self, from: data)) ?? []
    }

    /// Forwards → `portForwardsData`: nil for none, so a machine without forwards stores nothing;
    /// sorted keys, so the same list always encodes to the same bytes (no spurious CloudKit change).
    static func encodeList(_ forwards: [PortForward]) -> Data? {
        guard !forwards.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(forwards)
    }
}
