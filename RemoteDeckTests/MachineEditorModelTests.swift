import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

@MainActor
struct MachineEditorModelTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let tester = FakeConnectionTester()

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func editor(_ machine: Machine? = nil, sharedClipboard: Bool = true,
                        tester: FakeConnectionTester? = nil) -> MachineEditorModel {
        MachineEditorModel(machine: machine, context: context, passwords: passwords,
                           tester: tester ?? self.tester, defaultSharedClipboard: sharedClipboard)
    }

    private func machines() throws -> [Machine] {
        try context.fetch(FetchDescriptor<Machine>())
    }

    private func fill(_ model: MachineEditorModel, name: String = "Mini", host: String = "mini.local",
                      port: String = "5900", username: String = "vincent", password: String = "s3cret") {
        model.name = name
        model.host = host
        model.portText = port
        model.username = username
        model.password = password
    }

    // MARK: Create (PRD acceptance criterion 1)

    @Test func createSavesMachineAndPutsPasswordInKeychainOnly() throws {
        let model = editor()
        fill(model, name: "  Mini  ", host: " mini.local ")
        model.isFavorite = true
        model.isWatched = true
        model.scalingMode = .actual
        model.sharedClipboard = false

        let saved = try #require(model.save())

        let stored = try #require(try machines().first)
        #expect(stored.id == saved.id)
        #expect(stored.name == "Mini")
        #expect(stored.host == "mini.local")
        #expect(stored.port == 5900)
        #expect(stored.kindValue == .macARD)
        #expect(stored.username == "vincent")
        #expect(stored.isFavorite && stored.isWatched)
        #expect(stored.scalingModeValue == .actual)
        #expect(stored.sharedClipboard == false)
        #expect(passwords.items[saved.id] == "s3cret")
        #expect(model.passwordScope == .synced)
    }

    @Test func emptyPasswordMakesNoKeychainWrite() throws {
        let model = editor()
        fill(model, password: "")
        #expect(model.save() != nil)
        #expect(passwords.writes.isEmpty)
    }

    @Test func newMachineTakesSharedClipboardDefaultFromSettings() {
        #expect(editor(sharedClipboard: false).sharedClipboard == false)
        #expect(editor(sharedClipboard: true).sharedClipboard == true)
    }

    // MARK: Validation

    @Test func validationErrorsAreSurfacedPerFieldAndNothingIsSaved() throws {
        let model = editor()
        fill(model, name: " ", host: "http://mini.local", port: "abc", username: "", password: "pw")

        #expect(model.save() == nil)

        #expect(model.issue(for: .name) == .empty)
        #expect(model.issue(for: .host) == .invalidHost)
        #expect(model.issue(for: .port) == .outOfRange)
        #expect(model.issue(for: .username) == .empty)
        #expect(try machines().isEmpty)
        #expect(passwords.writes.isEmpty)

        model.clearIssue(for: .name)
        #expect(model.issue(for: .name) == nil)
        #expect(model.issue(for: .host) == .invalidHost)
    }

    @Test(arguments: ["0", "65536", "-1", "59 00"])
    func portOutOfRangeIsRejected(_ port: String) {
        let model = editor()
        fill(model, port: port)
        #expect(model.save() == nil)
        #expect(model.issue(for: .port) == .outOfRange)
    }

    @Test func anthropicVMHasNoUsername() throws {
        let model = editor()
        fill(model, username: "ignored")
        model.kind = .anthropicVM
        #expect(!model.showsUsername)

        let saved = try #require(model.save())
        #expect(saved.username == nil)
        #expect(saved.kindValue == .anthropicVM)
    }

    /// AC4: the reference computer use container serves VNC on 5900 with no password (x11vnc -nopw).
    @Test func anthropicVMSavesOnPort5900WithoutPassword() throws {
        let model = editor()
        #expect(model.portText == "5900")
        model.kind = .anthropicVM
        model.name = "Computer use"
        model.host = "127.0.0.1"
        #expect(model.passwordIsOptional)

        let saved = try #require(model.save())
        #expect(saved.port == 5900 && saved.username == nil && saved.kindValue == .anthropicVM)
        #expect(passwords.items.isEmpty && passwords.localItems.isEmpty)
        model.kind = .macARD
        #expect(!model.passwordIsOptional)
    }

    @Test func vncUsernameIsOptional() throws {
        let model = editor()
        fill(model, username: "")
        model.kind = .vnc
        #expect(model.showsUsername && !model.requiresUsername)
        #expect(model.save() != nil)
    }

    @Test func duplicateHostAndPortIsRejectedButEditingItselfIsNot() throws {
        let first = editor()
        fill(first)
        let existing = try #require(first.save())

        let second = editor()
        fill(second, name: "Other", host: "MINI.local.")
        #expect(second.save() == nil)
        #expect(second.issue(for: .host) == .duplicate)
        #expect(try machines().count == 1)

        second.portText = "5901"
        #expect(second.save() != nil)

        let edit = editor(existing)
        edit.name = "Renamed"
        #expect(edit.save() != nil)
        #expect(edit.issues.isEmpty)
    }

    // MARK: Edit and password changes

    @Test func editKeepsUnchangedPasswordWithoutKeychainWrite() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())
        let writesAfterCreate = passwords.writes.count

        let edit = editor(machine)
        #expect(edit.password == "s3cret")
        #expect(edit.name == "Mini" && edit.username == "vincent" && edit.portText == "5900")
        edit.host = "mini2.local"
        #expect(edit.save() != nil)

        #expect(passwords.writes.count == writesAfterCreate)
        #expect(machine.host == "mini2.local")
        #expect(try machines().count == 1)
    }

    @Test func editReplacesOrClearsThePassword() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())

        let change = editor(machine)
        change.password = "new"
        #expect(change.save() != nil)
        #expect(passwords.items[machine.id] == "new")

        let clear = editor(machine)
        clear.password = ""
        #expect(clear.save() != nil)
        #expect(passwords.items[machine.id] == nil)
        #expect(passwords.log.last == "delete")
        #expect(clear.passwordScope == nil)
    }

    @Test func unreadablePasswordIsNeverDeletedByAnEmptyField() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())
        passwords.readError = .interactionNotAllowed

        let edit = editor(machine)
        #expect(edit.passwordReadError == .interactionNotAllowed)
        #expect(edit.password.isEmpty)
        edit.name = "Renamed"
        #expect(edit.save() != nil)
        #expect(!passwords.log.contains("delete"))
        #expect(passwords.items[machine.id] == "s3cret")
    }

    @Test func missingEntitlementFallsBackToALocalPasswordAndSaves() throws {
        passwords.syncedSaveError = .missingEntitlement
        let model = editor()
        fill(model)

        let saved = try #require(model.save())

        #expect(model.passwordFailure == nil)
        #expect(model.passwordScope == .local)
        #expect(passwords.items[saved.id] == nil)
        #expect(passwords.localItems[saved.id] == "s3cret")
        #expect(try machines().count == 1)

        // Reopened, the editor finds the local password and shows the "this Mac only" note.
        let edit = editor(saved)
        #expect(edit.password == "s3cret")
        #expect(edit.passwordScope == .local)
    }

    @Test func otherKeychainRefusalSavesNothingAndExplainsIt() throws {
        passwords.saveError = .interactionNotAllowed
        let model = editor()
        fill(model)
        model.groupChoice = .new
        model.newGroupName = "Servers"

        #expect(model.save() == nil)

        let failure = try #require(model.passwordFailure)
        #expect(failure == .init(error: .interactionNotAllowed, deleting: false))
        #expect(try machines().isEmpty)
        #expect(try context.fetch(FetchDescriptor<MachineGroup>()).isEmpty)
        #expect(failure.error.passwordMessage(deleting: false, english)
            == "The password could not be saved to the Keychain (-25308). Nothing was saved.")

        // Clearing the password lets the machine be saved without it.
        model.password = ""
        model.clearPasswordError()
        #expect(model.save() != nil)
        #expect(model.passwordFailure == nil)
    }

    @Test func failingToDeleteAClearedPasswordHasItsOwnMessage() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())
        passwords.deleteError = .interactionNotAllowed

        let edit = editor(machine)
        edit.password = ""
        #expect(edit.save() == nil)
        let failure = try #require(edit.passwordFailure)
        #expect(failure.deleting)
        #expect(failure.error.passwordMessage(deleting: true, english)
            == "The cleared password could not be removed from the Keychain (-25308). Nothing was saved.")
    }

    // MARK: SwiftData failure after the Keychain changed

    @Test func editRestoresThePreviousPasswordWhenSwiftDataFails() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())

        let edit = editor(machine)
        edit.password = "new"
        edit.persist = { _ in throw CocoaError(.validationMissingMandatoryProperty) }
        #expect(edit.save() == nil)
        #expect(edit.saveError != nil)
        #expect(passwords.items[machine.id] == "s3cret")

        let clear = editor(machine)
        clear.password = ""
        clear.persist = { _ in throw CocoaError(.validationMissingMandatoryProperty) }
        #expect(clear.save() == nil)
        #expect(passwords.items[machine.id] == "s3cret")
    }

    @Test func newMachinePasswordIsRemovedWhenSwiftDataFails() throws {
        let model = editor()
        fill(model)
        model.persist = { _ in throw CocoaError(.validationMissingMandatoryProperty) }
        #expect(model.save() == nil)
        #expect(passwords.items.isEmpty && passwords.localItems.isEmpty)
        #expect(try machines().isEmpty)
    }

    @Test func editWithKeychainRefusalLeavesTheMachineUnchanged() throws {
        let create = editor()
        fill(create)
        let machine = try #require(create.save())
        passwords.saveError = .interactionNotAllowed

        let edit = editor(machine)
        edit.name = "Renamed"
        edit.password = "other"
        #expect(edit.save() == nil)
        #expect(machine.name == "Mini")
    }

    // MARK: Groups

    @Test func newGroupIsCreatedAndValidated() throws {
        let model = editor()
        fill(model)
        model.groupChoice = .new
        model.newGroupName = "  Servers "
        let saved = try #require(model.save())
        #expect(saved.group?.name == "Servers")

        let other = editor()
        fill(other, host: "other.local")
        #expect(other.groups.map(\.name) == ["Servers"])
        other.groupChoice = .new
        other.newGroupName = "SERVERS"
        #expect(other.save() == nil)
        #expect(other.issue(for: .groupName) == .duplicate)

        other.groupChoice = .existing(try #require(saved.group).id)
        let joined = try #require(other.save())
        #expect(joined.group?.id == saved.group?.id)
        #expect(try context.fetch(FetchDescriptor<MachineGroup>()).count == 1)
    }

    // MARK: Test connection

    @Test func testConnectionSucceedsWithTypedCredentialsAndFiveSecondTimeout() async throws {
        let model = editor()
        fill(model, host: " mini.local ", port: "5901")

        model.testConnection()
        #expect(model.testState == .testing)
        #expect(await waitUntil { model.testState == .succeeded })

        let call = try #require(await tester.calls.first)
        #expect(call.host == "mini.local")
        #expect(call.port == 5901)
        #expect(call.timeout == .seconds(5))
        #expect(call.credentials.username == "vincent")
        #expect(call.credentials.password == "s3cret")
        #expect(try machines().isEmpty)  // a test never saves
    }

    @Test func anthropicVMTestSendsNoUsernameAndEmptyPasswordIsNil() async throws {
        let model = editor()
        fill(model, username: "ignored", password: "")
        model.kind = .anthropicVM
        model.testConnection()
        #expect(await waitUntil { model.testState == .succeeded })
        let call = try #require(await tester.calls.first)
        #expect(call.credentials.username == nil)
        #expect(call.credentials.password == nil)
    }

    @Test func invalidFieldsBlockTheTest() async throws {
        let model = editor()
        fill(model, host: "bad host")
        model.testConnection()
        #expect(model.testState == .idle)
        #expect(model.issue(for: .host) == .invalidHost)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await tester.calls.isEmpty)
    }

    @Test(arguments: [
        (RFBError.authFailed(reason: nil), TestConnectionFailure.authFailed(reason: nil)),
        (.network("POSIXErrorCode(rawValue: 61): Connection refused"), .unreachable),
        (.timeout, .timedOut),
        (.unsupportedSecurityTypes([16]), .unsupportedSecurityType(offered: [16], apple: false)),
        (.credentialsRequired(securityType: 30), .credentialsRequired(username: true)),
    ])
    func testConnectionFailureIsShown(_ error: RFBError, _ expected: TestConnectionFailure) async {
        let tester = FakeConnectionTester(result: .failure(error))
        let model = editor(tester: tester)
        fill(model)
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(expected) })
    }

    @Test func closingTheSheetCancelsTheTestAndIgnoresLateResults() async throws {
        let tester = FakeConnectionTester(hangs: true)
        let model = editor(tester: tester)
        fill(model)
        model.testConnection()
        #expect(await waitUntil { model.testState == .testing })
        // Wait until the fake is inside `test`, then close.
        var polls = 0
        while await tester.calls.isEmpty, polls < 200 { try await Task.sleep(for: .milliseconds(5)); polls += 1 }

        model.cancelTest()
        #expect(model.testState == .idle)
        // The cancelled attempt ends with `.cancelled` → stays idle, never an error.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.testState == .idle)
    }

    @Test func aResultArrivingAfterCloseIsIgnored() async throws {
        let tester = FakeConnectionTester(result: .failure(.authFailed(reason: nil)), lateBy: .milliseconds(100))
        let model = editor(tester: tester)
        fill(model)
        model.testConnection()
        var polls = 0
        while await tester.calls.isEmpty, polls < 200 { try await Task.sleep(for: .milliseconds(5)); polls += 1 }

        model.cancelTest()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.testState == .idle)
    }

    @Test(arguments: ["host", "port", "username", "password", "kind"])
    func editingAFieldTheTestUsedResetsItsResult(_ field: String) async throws {
        let model = editor()
        fill(model)
        model.testConnection()
        #expect(await waitUntil { model.testState == .succeeded })
        model.name = "Renamed"  // not used by the test
        #expect(model.testState == .succeeded)

        switch field {
        case "host": model.host = "other.local"
        case "port": model.portText = "5901"
        case "username": model.username = "root"
        case "password": model.password = "other"
        default: model.kind = .vnc
        }
        #expect(model.testState == .idle)
    }

    @Test func aNewerTestWinsOverAnOlderOne() async throws {
        let tester = FakeConnectionTester(hangs: true)
        let model = editor(tester: tester)
        fill(model)
        model.testConnection()
        var polls = 0
        while await tester.calls.isEmpty, polls < 200 { try await Task.sleep(for: .milliseconds(5)); polls += 1 }

        await tester.set(result: .failure(.authFailed(reason: nil)))
        model.testConnection()  // cancels the first one
        #expect(await waitUntil { model.testState == .failed(.authFailed(reason: nil)) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.testState == .failed(.authFailed(reason: nil)))
        #expect(await tester.calls.count == 2)
    }
}
