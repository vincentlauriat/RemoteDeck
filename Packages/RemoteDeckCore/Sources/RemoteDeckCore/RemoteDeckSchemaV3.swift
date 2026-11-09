import Foundation
import SwiftData

/// Version 3 of the SwiftData schema (BackendSchema › Tables), the current one. V3 adds SSH machines:
/// the `ssh` kind value and the optional `Machine.sshAuthMethod`, `sshKeyFileName` and
/// `portForwardsData` (lightweight from V2; V1 and V2 stay frozen). V2 added `Machine.modifiedAt`.
///
/// Every stored property is optional or defaulted, relationships are optional and
/// there is no `@Attribute(.unique)`: CloudKit rules, applied to the local models too.
/// Stored property names match BackendSchema verbatim because CloudKit field names
/// are permanent once deployed; enum fields get a typed `…Value` accessor.
public enum RemoteDeckSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Machine.self, MachineGroup.self, SessionRecord.self, AssistantAction.self]
    }

    // MARK: Synced store

    /// A remote endpoint the user can open a session on.
    @Model
    public final class Machine {
        #Index<Machine>([\.host], [\.name])

        public var id: UUID = UUID()
        public var name: String = ""
        public var kind: String = MachineKind.macARD.rawValue
        public var host: String = ""
        public var port: Int = 5900
        public var username: String?
        public var group: MachineGroup?
        public var isFavorite: Bool = false
        public var isWatched: Bool = false
        public var scalingMode: String = ScalingMode.fit.rawValue
        public var sharedClipboard: Bool = true
        public var lastConnectedAt: Date?
        public var createdAt: Date = Date.now
        /// Last edit saved from the Machine Editor on any Mac; `nil` for a machine never edited
        /// since V1. In a duplicate merge, the survivor takes the fields of the most recently
        /// modified copy (`LibraryDeduplication`, T4.3).
        public var modifiedAt: Date?
        /// SSH only (V3): `SSHAuthMethod` raw value; nil reads as `.password` (`sshAuth`).
        public var sshAuthMethod: String?
        /// SSH `keyInSSHFolder` only (V3): the key file's path relative to `~/.ssh` (`id_ed25519`),
        /// never absolute. The key itself is never copied anywhere.
        public var sshKeyFileName: String?
        /// SSH only (V3): JSON array of `PortForward`; read and write it through `portForwards`.
        public var portForwardsData: Data?

        public init(
            id: UUID = UUID(),
            name: String = "",
            kind: MachineKind = .macARD,
            host: String = "",
            port: Int = 5900,
            username: String? = nil,
            isFavorite: Bool = false,
            isWatched: Bool = false,
            scalingMode: ScalingMode = .fit,
            sharedClipboard: Bool = true,
            lastConnectedAt: Date? = nil,
            createdAt: Date = .now,
            modifiedAt: Date? = nil,
            sshAuthMethod: SSHAuthMethod? = nil,
            sshKeyFileName: String? = nil,
            portForwards: [PortForward] = []
        ) {
            self.id = id
            self.name = name
            self.kind = kind.rawValue
            self.host = host
            self.port = port
            self.username = username
            self.isFavorite = isFavorite
            self.isWatched = isWatched
            self.scalingMode = scalingMode.rawValue
            self.sharedClipboard = sharedClipboard
            self.lastConnectedAt = lastConnectedAt
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.sshAuthMethod = sshAuthMethod?.rawValue
            self.sshKeyFileName = sshKeyFileName
            self.portForwardsData = PortForward.encodeList(portForwards)
        }

        /// Typed `kind`; an unknown raw value (newer app version) reads as `.macARD`.
        public var kindValue: MachineKind {
            get { MachineKind(rawValue: kind) ?? .macARD }
            set { kind = newValue.rawValue }
        }

        /// Typed `scalingMode`; an unknown raw value reads as `.fit`.
        public var scalingModeValue: ScalingMode {
            get { ScalingMode(rawValue: scalingMode) ?? .fit }
            set { scalingMode = newValue.rawValue }
        }

        /// Typed `sshAuthMethod`; nil or an unknown raw value reads as `.password`.
        public var sshAuth: SSHAuthMethod {
            get { sshAuthMethod.flatMap(SSHAuthMethod.init(rawValue:)) ?? .password }
            set { sshAuthMethod = newValue.rawValue }
        }

        /// Decoded `portForwardsData`; nil or invalid data reads as `[]`, and `[]` stores nil.
        public var portForwards: [PortForward] {
            get { PortForward.decodeList(portForwardsData) }
            set { portForwardsData = PortForward.encodeList(newValue) }
        }

        /// Lowercased `host:port`, the uniqueness key (BackendSchema › Data validation).
        public var normalizedKey: String {
            MachineValidator.normalizedKey(host: host, port: port)
        }
    }

    /// A named folder that organizes machines in the sidebar.
    @Model
    public final class MachineGroup {
        public var id: UUID = UUID()
        public var name: String = ""
        public var sortOrder: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \Machine.group)
        public var machines: [Machine]? = []

        public init(id: UUID = UUID(), name: String = "", sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
        }
    }

    // MARK: Local store

    /// One session attempt with its timing and outcome (Session History).
    @Model
    public final class SessionRecord {
        #Index<SessionRecord>([\.startedAt], [\.machineID])

        public var id: UUID = UUID()
        /// Soft link to `Machine.id`: a plain id, since the two live in different stores.
        public var machineID: UUID = UUID()
        /// Name snapshot, kept after the machine is deleted.
        public var machineName: String = ""
        public var startedAt: Date = Date.now
        public var connectMillis: Int?
        public var endedAt: Date?
        public var outcome: String = SessionOutcome.cancelled.rawValue
        public var bytesReceived: Int64 = 0
        public var assistantTokens: Int = 0
        @Relationship(deleteRule: .cascade, inverse: \AssistantAction.session)
        public var actions: [AssistantAction]? = []

        /// `machineID`, `machineName` and `outcome` have no schema default, so they are
        /// required here; the declaration defaults only satisfy the CloudKit discipline.
        public init(
            id: UUID = UUID(),
            machineID: UUID,
            machineName: String,
            startedAt: Date = .now,
            connectMillis: Int? = nil,
            endedAt: Date? = nil,
            outcome: SessionOutcome,
            bytesReceived: Int64 = 0,
            assistantTokens: Int = 0
        ) {
            self.id = id
            self.machineID = machineID
            self.machineName = machineName
            self.startedAt = startedAt
            self.connectMillis = connectMillis
            self.endedAt = endedAt
            self.outcome = outcome.rawValue
            self.bytesReceived = bytesReceived
            self.assistantTokens = assistantTokens
        }

        /// Typed `outcome`; an unknown raw value reads as `.cancelled`.
        public var outcomeValue: SessionOutcome {
            get { SessionOutcome(rawValue: outcome) ?? .cancelled }
            set { outcome = newValue.rawValue }
        }
    }

    /// One action proposed by the Claude Assistant, and the user's decision on it.
    @Model
    public final class AssistantAction {
        public var id: UUID = UUID()
        /// Required by BackendSchema, optional here (relationship discipline); set it on creation.
        public var session: SessionRecord?
        public var createdAt: Date = Date.now
        public var kind: String = AssistantActionKind.screenshot.rawValue
        /// JSON: coordinates, text, key combo.
        public var payload: String = "{}"
        public var decision: String = AssistantDecision.pending.rawValue

        public init(
            id: UUID = UUID(),
            session: SessionRecord? = nil,
            createdAt: Date = .now,
            kind: AssistantActionKind,
            payload: String = "{}",
            decision: AssistantDecision = .pending
        ) {
            self.id = id
            self.session = session
            self.createdAt = createdAt
            self.kind = kind.rawValue
            self.payload = payload
            self.decision = decision.rawValue
        }

        /// Typed `kind`; an unknown raw value reads as `.screenshot`.
        public var kindValue: AssistantActionKind {
            get { AssistantActionKind(rawValue: kind) ?? .screenshot }
            set { kind = newValue.rawValue }
        }

        /// Typed `decision`; an unknown raw value reads as `.pending`.
        public var decisionValue: AssistantDecision {
            get { AssistantDecision(rawValue: decision) ?? .pending }
            set { decision = newValue.rawValue }
        }
    }
}

public typealias Machine = RemoteDeckSchemaV3.Machine
public typealias MachineGroup = RemoteDeckSchemaV3.MachineGroup
public typealias SessionRecord = RemoteDeckSchemaV3.SessionRecord
public typealias AssistantAction = RemoteDeckSchemaV3.AssistantAction
