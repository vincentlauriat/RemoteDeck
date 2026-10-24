import Foundation

/// Duplicate rule of the synced library (BackendSchema › Data validation, T4.3): one Machine per
/// lowercase `host:port`, one MachineGroup per name (trimmed, case-insensitive). Two Macs that
/// added the same machine before they synced each import the other's copy and run this plan, each
/// on its own snapshot. The survivor is elected from fields that never change once a record exists
/// (`createdAt`, then `id`; a group by `id`), so both Macs keep the same one even when one of them
/// has not received the other's latest edit: an order on `modifiedAt` or `sortOrder` could let
/// each Mac delete the other's copy (and its synced password), and the machine would vanish.
/// "Most recently modified wins" applies to the content instead: `fieldsFrom` names the duplicate
/// whose fields the survivor takes.
///
/// Pure: the app applies a plan (passwords first, then deletions, then one save).
public enum LibraryDeduplication {
    /// What the plan needs of a Machine.
    public struct MachineFacts: Equatable, Sendable {
        public let id: UUID
        public let key: String
        public let modifiedAt: Date?
        public let createdAt: Date

        public init(id: UUID, key: String, modifiedAt: Date?, createdAt: Date) {
            self.id = id
            self.key = key
            self.modifiedAt = modifiedAt
            self.createdAt = createdAt
        }

        public init(_ machine: Machine) {
            self.init(id: machine.id, key: machine.normalizedKey, modifiedAt: machine.modifiedAt,
                      createdAt: machine.createdAt)
        }
    }

    /// What the plan needs of a MachineGroup.
    public struct GroupFacts: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let sortOrder: Int

        public init(id: UUID, name: String, sortOrder: Int) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
        }

        public init(_ group: MachineGroup) {
            self.init(id: group.id, name: group.name, sortOrder: group.sortOrder)
        }

        var key: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    /// One set of duplicates: `survivor` stays, `dropped` go (their content folds into it).
    /// `fieldsFrom`: a dropped machine edited more recently than the survivor, whose user-visible
    /// fields the survivor takes; nil when the survivor is the most recently modified (always nil
    /// for groups).
    public struct Merge: Equatable, Sendable {
        public let survivor: UUID
        public let dropped: [UUID]
        public let fieldsFrom: UUID?

        public init(survivor: UUID, dropped: [UUID], fieldsFrom: UUID? = nil) {
            self.survivor = survivor
            self.dropped = dropped
            self.fieldsFrom = fieldsFrom
        }
    }

    /// The machine kept among duplicates: the first created, then the smaller id. Both never change.
    public static func prefers(_ a: MachineFacts, over b: MachineFacts) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// The group kept among groups of the same name: the smaller id (the only field of a group that
    /// never changes; `sortOrder` can differ between two Macs' snapshots).
    public static func prefers(_ a: GroupFacts, over b: GroupFacts) -> Bool {
        a.id.uuidString < b.id.uuidString
    }

    /// Duplicate machines, one merge per key with more than one machine, in key order.
    public static func machineMerges(_ machines: [MachineFacts]) -> [Merge] {
        let byKey = Dictionary(grouping: machines, by: \.key)
        return byKey.keys.sorted().compactMap { key in
            guard let members = byKey[key], members.count > 1 else { return nil }
            let ordered = members.sorted(by: prefers)
            let survivor = ordered[0]
            // The newest edit among the dropped ones, if newer than the survivor's (ties: the
            // survivor keeps its own fields; between dropped ones, the elected order decides).
            let newest = ordered.dropFirst().reduce(nil as MachineFacts?) { best, next in
                guard let nextModified = next.modifiedAt else { return best }
                guard let bestModified = best?.modifiedAt else { return next }
                return nextModified > bestModified ? next : best
            }
            let fieldsFrom = newest.flatMap { candidate -> UUID? in
                guard let modified = candidate.modifiedAt else { return nil }
                return modified > (survivor.modifiedAt ?? .distantPast) ? candidate.id : nil
            }
            return Merge(survivor: survivor.id, dropped: ordered.dropFirst().map(\.id), fieldsFrom: fieldsFrom)
        }
    }

    /// Duplicate groups, one merge per name with more than one group, in name order.
    public static func groupMerges(_ groups: [GroupFacts]) -> [Merge] {
        let byKey = Dictionary(grouping: groups, by: \.key)
        return byKey.keys.sorted().compactMap { key in
            guard let members = byKey[key], members.count > 1 else { return nil }
            let ordered = members.sorted(by: prefers)
            return Merge(survivor: ordered[0].id, dropped: ordered.dropFirst().map(\.id))
        }
    }
}

