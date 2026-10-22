import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

@MainActor
struct MachineLibraryModelTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    // MARK: Delete

    @Test func deleteRemovesTheMachineAndItsKeychainItem() throws {
        let machine = Machine(name: "Mini", host: "mini.local", username: "v")
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "s3cret"
        let library = MachineLibraryModel(context: context, passwords: passwords)
        library.selection = machine.id

        library.delete(machine)

        #expect(try context.fetch(FetchDescriptor<Machine>()).isEmpty)
        #expect(passwords.items[machine.id] == nil)
        #expect(library.selection == nil)
        #expect(library.deleteWarning == nil)
    }

    @Test func keychainFailureOnDeleteIsReportedNotSwallowed() throws {
        let machine = Machine(name: "Mini", host: "mini.local", username: "v")
        context.insert(machine)
        try context.save()
        passwords.deleteError = KeychainError(status: -25293)
        let library = MachineLibraryModel(context: context, passwords: passwords)

        library.delete(machine)

        #expect(try context.fetch(FetchDescriptor<Machine>()).isEmpty)
        #expect(library.deleteWarning == KeychainError(status: -25293))
    }

    @Test func deleteKeepsSessionHistory() throws {
        let machine = Machine(name: "Mini", host: "mini.local", username: "v")
        context.insert(machine)
        context.insert(SessionRecord(machineID: machine.id, machineName: "Mini", outcome: .connected))
        try context.save()

        MachineLibraryModel(context: context, passwords: passwords).delete(machine)

        #expect(try context.fetchCount(FetchDescriptor<SessionRecord>()) == 1)
    }

    @Test func deletingAGroupKeepsItsMachines() throws {
        let group = MachineGroup(name: "Servers")
        let machine = Machine(name: "Mini", host: "mini.local", username: "v")
        context.insert(group)
        context.insert(machine)
        machine.group = group
        try context.save()

        MachineLibraryModel(context: context, passwords: passwords).delete(group)

        #expect(try context.fetch(FetchDescriptor<MachineGroup>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Machine>()).first?.group == nil)
    }

    // MARK: Search and sections

    private func sample() -> (machines: [Machine], groups: [MachineGroup]) {
        let servers = MachineGroup(name: "Servers", sortOrder: 1)
        let office = MachineGroup(name: "Office", sortOrder: 0)
        let empty = MachineGroup(name: "Empty", sortOrder: 2)
        let machines = [
            Machine(name: "Studio", host: "studio.local", isFavorite: true),
            Machine(name: "Build", host: "10.0.1.20"),
            Machine(name: "Élysée", host: "elysee.lan"),
            Machine(name: "nas", host: "nas.local"),
            Machine(name: "Alpha", host: "alpha.local"),
        ]
        machines[0].group = office   // favorite: listed under Favorites only
        machines[1].group = servers
        machines[2].group = office
        return (machines, [servers, office, empty])
    }

    @Test func searchMatchesNameAndHostIgnoringCaseAndDiacritics() {
        let (machines, _) = sample()
        let names = { (query: String) in MachineLibraryModel.filter(machines, query: query).map(\.name).sorted() }
        #expect(names("") == ["Alpha", "Build", "nas", "Studio", "Élysée"].sorted())
        #expect(names("ELYSEE") == ["Élysée"])        // name, diacritic-insensitive
        #expect(names("10.0.1") == ["Build"])         // host
        #expect(names("  NAS ") == ["nas"])           // trimmed, case-insensitive
        #expect(names(".local").count == 3)
        #expect(names("zzz").isEmpty)
    }

    @Test func sectionsPinFavoritesThenGroupsByOrderThenUngrouped() {
        let (machines, groups) = sample()
        let sections = MachineLibraryModel.sections(machines: machines, groups: groups, query: "", t: english)

        #expect(sections.map(\.title) == ["Favorites", "Office", "Servers", "Empty", "Machines"])
        #expect(sections[0].machines.map(\.name) == ["Studio"])
        #expect(sections[1].machines.map(\.name) == ["Élysée"])
        #expect(sections[2].machines.map(\.name) == ["Build"])
        #expect(sections[3].machines.isEmpty)
        #expect(sections[4].machines.map(\.name) == ["Alpha", "nas"])
        // Each machine appears exactly once (one selection id per row).
        let ids = sections.flatMap(\.machines).map(\.id)
        #expect(ids.count == Set(ids).count && ids.count == machines.count)
    }

    @Test func searchingDropsEmptySections() {
        let (machines, groups) = sample()
        let sections = MachineLibraryModel.sections(machines: machines, groups: groups, query: "build", t: english)
        #expect(sections.map(\.title) == ["Servers"])
        #expect(MachineLibraryModel.sections(machines: machines, groups: groups, query: "zzz", t: english).isEmpty)
    }
}
