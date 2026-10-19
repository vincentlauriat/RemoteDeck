import Foundation
import SwiftData
import Testing
@testable import RemoteDeckCore

@MainActor
struct ModelTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    @Test func containerHasSyncedAndLocalConfigurations() {
        let names = container.configurations.map(\.name).sorted()
        #expect(names == ["Local", "Synced"])
        // `CloudKitDatabase` is not Equatable: compare descriptions, and make sure they discriminate.
        let none = String(describing: ModelConfiguration.CloudKitDatabase.none)
        #expect(none != String(describing: ModelConfiguration.CloudKitDatabase.automatic))
        for configuration in container.configurations {
            #expect(String(describing: configuration.cloudKitDatabase) == none)
        }
        let synced = container.configurations.first { $0.name == "Synced" }
        let local = container.configurations.first { $0.name == "Local" }
        #expect(Set(synced?.schema?.entities.map(\.name) ?? []) == ["Machine", "MachineGroup"])
        #expect(Set(local?.schema?.entities.map(\.name) ?? []) == ["SessionRecord", "AssistantAction"])
    }

    // MARK: Defaults (BackendSchema)

    @Test func machineDefaultsMatchSchema() throws {
        context.insert(Machine())
        try context.save()
        let machine = try #require(try context.fetch(FetchDescriptor<Machine>()).first)
        #expect(machine.name == "")
        #expect(machine.kind == "macARD")
        #expect(machine.host == "")
        #expect(machine.port == 5900)
        #expect(machine.username == nil)
        #expect(machine.group == nil)
        #expect(machine.isFavorite == false)
        #expect(machine.isWatched == false)
        #expect(machine.scalingMode == "fit")
        #expect(machine.sharedClipboard == true)
        #expect(machine.lastConnectedAt == nil)
        #expect(abs(machine.createdAt.timeIntervalSinceNow) < 60)
    }

    @Test func groupSessionAndActionDefaultsMatchSchema() throws {
        let group = MachineGroup()
        let session = SessionRecord(machineID: UUID(), machineName: "Studio", outcome: .connected)
        let action = AssistantAction(kind: .click)
        context.insert(group)
        context.insert(session)
        context.insert(action)
        try context.save()

        #expect(group.name == "" && group.sortOrder == 0 && (group.machines ?? []).isEmpty)
        #expect(session.connectMillis == nil && session.endedAt == nil)
        #expect(session.bytesReceived == 0 && session.assistantTokens == 0)
        #expect(abs(session.startedAt.timeIntervalSinceNow) < 60)
        #expect(action.payload == "{}")
        #expect(action.decision == "pending")
        #expect(abs(action.createdAt.timeIntervalSinceNow) < 60)
    }

    // MARK: CRUD

    @Test func createsFetchesAndDeletesMachine() throws {
        let machine = Machine(name: "Studio", host: "studio.local", username: "vincent")
        context.insert(machine)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.host == "studio.local" }))
        #expect(fetched.map(\.id) == [machine.id])

        context.delete(machine)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 0)
    }

    @Test func createsFetchesAndDeletesGroup() throws {
        let group = MachineGroup(name: "Office", sortOrder: 2)
        context.insert(group)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<MachineGroup>()).map(\.name) == ["Office"])

        context.delete(group)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<MachineGroup>()) == 0)
    }

    @Test func createsFetchesAndDeletesSessionAndAction() throws {
        let machineID = UUID()
        let session = SessionRecord(machineID: machineID, machineName: "Studio", outcome: .authFailed)
        let action = AssistantAction(kind: .type, payload: #"{"text":"hi"}"#)
        context.insert(session)
        context.insert(action)
        action.session = session
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.machineID == machineID }))
        #expect(sessions.count == 1)
        #expect(sessions.first?.actions?.map(\.id) == [action.id])

        context.delete(action)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AssistantAction>()) == 0)
        #expect(session.actions?.isEmpty == true)

        context.delete(session)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SessionRecord>()) == 0)
    }

    // MARK: Delete rules

    @Test func deletingGroupNullifiesItsMachines() throws {
        let group = MachineGroup(name: "Office")
        let first = Machine(name: "A", host: "a.local")
        let second = Machine(name: "B", host: "b.local")
        context.insert(group)
        context.insert(first)
        context.insert(second)
        first.group = group
        second.group = group
        try context.save()
        #expect(group.machines?.count == 2)

        context.delete(group)
        try context.save()

        let machines = try context.fetch(FetchDescriptor<Machine>())
        #expect(machines.count == 2)
        #expect(machines.allSatisfy { $0.group == nil })
    }

    @Test func deletingSessionCascadesToActions() throws {
        let session = SessionRecord(machineID: UUID(), machineName: "Studio", outcome: .connected)
        context.insert(session)
        for kind in [AssistantActionKind.screenshot, .click, .scroll] {
            let action = AssistantAction(kind: kind)
            context.insert(action)
            action.session = session
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AssistantAction>()) == 3)

        context.delete(session)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AssistantAction>()) == 0)
    }

    // MARK: Typed accessors

    @Test(arguments: MachineKind.allCases)
    func machineKindRoundTrips(_ kind: MachineKind) {
        let machine = Machine()
        machine.kindValue = kind
        #expect(machine.kind == kind.rawValue && machine.kindValue == kind)
    }

    @Test(arguments: ScalingMode.allCases)
    func scalingModeRoundTrips(_ mode: ScalingMode) {
        let machine = Machine(scalingMode: mode)
        #expect(machine.scalingMode == mode.rawValue && machine.scalingModeValue == mode)
    }

    @Test(arguments: SessionOutcome.allCases)
    func outcomeRoundTrips(_ outcome: SessionOutcome) {
        let session = SessionRecord(machineID: UUID(), machineName: "", outcome: .connected)
        session.outcomeValue = outcome
        #expect(session.outcome == outcome.rawValue && session.outcomeValue == outcome)
    }

    @Test(arguments: AssistantActionKind.allCases, AssistantDecision.allCases)
    func actionKindAndDecisionRoundTrip(_ kind: AssistantActionKind, _ decision: AssistantDecision) {
        let action = AssistantAction(kind: .screenshot)
        action.kindValue = kind
        action.decisionValue = decision
        #expect(action.kind == kind.rawValue && action.kindValue == kind)
        #expect(action.decision == decision.rawValue && action.decisionValue == decision)
    }

    @Test func unknownRawValuesFallBack() {
        let machine = Machine()
        machine.kind = "future"
        machine.scalingMode = "future"
        #expect(machine.kindValue == .macARD && machine.scalingModeValue == .fit)
    }

    @Test func persistedRawValuesSurviveRefetch() throws {
        let machine = Machine(kind: .anthropicVM, scalingMode: .actual)
        context.insert(machine)
        try context.save()
        let fresh = ModelContext(container)
        let fetched = try #require(try fresh.fetch(FetchDescriptor<Machine>()).first)
        #expect(fetched.kindValue == .anthropicVM && fetched.scalingModeValue == .actual)
    }
}
