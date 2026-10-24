import Foundation

/// Machines whose unencrypted connection across the public Internet the user confirmed once ("Connect
/// anyway" on the sheet, T5.3 H1), each for the host it had then: editing the host invalidates the
/// confirmation (the new host is unconfirmed). Kept on this Mac only, in UserDefaults keyed by machine
/// id: whether a network path is acceptable is a judgement about this Mac's networks, so it does not
/// follow the library through CloudKit (and a Machine property would change the SwiftData schema's
/// hash).
@MainActor
protocol PublicAddressConsents: AnyObject {
    func hasConfirmed(_ machineID: UUID, host: String) -> Bool
    func confirm(_ machineID: UUID, host: String)
    /// The machine was deleted.
    func forget(_ machineID: UUID)
}

extension PublicAddressConsents {
    /// Hosts compare trimmed and case-insensitively (DNS names are).
    nonisolated static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

@MainActor
final class UserDefaultsPublicAddressConsents: PublicAddressConsents {
    /// `publicInternetConfirmed.<uuid>` = the host confirmed (BackendSchema › AppSettings).
    static let keyPrefix = "publicInternetConfirmed."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ machineID: UUID) -> String { keyPrefix + machineID.uuidString }

    func hasConfirmed(_ machineID: UUID, host: String) -> Bool {
        guard let confirmed = defaults.string(forKey: Self.key(machineID)) else { return false }
        return confirmed == Self.normalized(host)
    }

    func confirm(_ machineID: UUID, host: String) {
        defaults.set(Self.normalized(host), forKey: Self.key(machineID))
    }

    func forget(_ machineID: UUID) { defaults.removeObject(forKey: Self.key(machineID)) }
}

/// The hosted tests and the Debug demo: nothing is written to the user's defaults.
@MainActor
final class InMemoryPublicAddressConsents: PublicAddressConsents {
    private(set) var confirmed: [UUID: String] = [:]

    init() {}

    func hasConfirmed(_ machineID: UUID, host: String) -> Bool { confirmed[machineID] == Self.normalized(host) }
    func confirm(_ machineID: UUID, host: String) { confirmed[machineID] = Self.normalized(host) }
    func forget(_ machineID: UUID) { confirmed[machineID] = nil }
}
