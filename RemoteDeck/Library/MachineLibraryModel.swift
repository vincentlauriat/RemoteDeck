import Foundation
import Observation
import SwiftData
import RemoteDeckCore

/// One sidebar section of the Library Window.
struct LibrarySection: Identifiable {
    enum Kind: Equatable {
        /// Pinned at the top (DesignBrief › Library Window).
        case favorites
        case group(UUID)
        /// Machines without a group.
        case ungrouped
    }

    let kind: Kind
    let title: String
    let machines: [Machine]
    /// The group behind a `.group` section (for its context menu).
    let group: MachineGroup?

    var id: String {
        switch kind {
        case .favorites: "favorites"
        case .group(let id): "group.\(id.uuidString)"
        case .ungrouped: "ungrouped"
        }
    }
}

/// Library Window state: search, sections, selection, delete (AppFlow › Library Window).
@Observable
@MainActor
final class MachineLibraryModel {
    var searchText = ""
    var selection: UUID?

    /// The Keychain item of a deleted machine could not be removed (the machine itself is gone).
    var deleteWarning: KeychainError?
    /// SwiftData failed to save a deletion; nothing was deleted.
    var deleteError: String?

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let passwords: any MachinePasswordStore

    init(context: ModelContext, passwords: any MachinePasswordStore) {
        self.context = context
        self.passwords = passwords
    }

    // MARK: Search and sections

    /// Live filter on name and host, case- and diacritic-insensitive (AppFlow › Search).
    static func filter(_ machines: [Machine], query: String) -> [Machine] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return machines }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return machines.filter {
            $0.name.range(of: query, options: options) != nil || $0.host.range(of: query, options: options) != nil
        }
    }

    /// Favorites first, then groups (by `sortOrder`, then name), then ungrouped machines. A favorite is
    /// listed only under Favorites, so each machine has exactly one row (one selection id).
    /// Empty sections are dropped while searching; empty groups stay visible otherwise.
    static func sections(machines: [Machine], groups: [MachineGroup], query: String,
                         t: (String) -> String) -> [LibrarySection] {
        let byName: (Machine, Machine) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let visible = filter(machines, query: query).sorted(by: byName)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var sections: [LibrarySection] = []
        let favorites = visible.filter(\.isFavorite)
        if !favorites.isEmpty {
            sections.append(LibrarySection(kind: .favorites, title: t("section_favorites"),
                                           machines: favorites, group: nil))
        }
        let others = visible.filter { !$0.isFavorite }
        let sortedGroups = groups.sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }
        for group in sortedGroups {
            let members = others.filter { $0.group?.id == group.id }
            if searching && members.isEmpty { continue }
            sections.append(LibrarySection(kind: .group(group.id), title: group.name,
                                           machines: members, group: group))
        }
        let ungrouped = others.filter { $0.group == nil }
        if !ungrouped.isEmpty {
            sections.append(LibrarySection(kind: .ungrouped, title: t("section_machines"),
                                           machines: ungrouped, group: nil))
        }
        return sections
    }

    // MARK: Delete

    /// Deletes the machine and its Keychain password (BackendSchema › Retention and deletion).
    /// The machine goes first: if SwiftData fails, nothing changes (password kept). A Keychain
    /// failure afterwards does not resurrect the machine; it is reported in `deleteWarning`,
    /// never swallowed. Its SessionRecords are kept (soft link).
    func delete(_ machine: Machine) {
        let id = machine.id
        context.delete(machine)
        do {
            try context.save()
        } catch {
            context.rollback()
            deleteError = error.localizedDescription
            return
        }
        if selection == id { selection = nil }
        do {
            try passwords.deletePassword(for: id)
        } catch {
            deleteWarning = error
        }
    }

    /// Deletes a group; its machines become ungrouped (`.nullify`).
    func delete(_ group: MachineGroup) {
        context.delete(group)
        do {
            try context.save()
        } catch {
            context.rollback()
            deleteError = error.localizedDescription
        }
    }
}
