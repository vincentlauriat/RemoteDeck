import Foundation
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit

/// Machine Editor state (AppFlow › Machine Editor): fields, validation, Keychain password,
/// Save and Test connection.
@Observable
@MainActor
final class MachineEditorModel {
    /// Group picker choice.
    enum GroupChoice: Hashable {
        case none
        case existing(UUID)
        /// "New Group…": the name comes from `newGroupName`.
        case new
    }

    /// AppFlow › Test connection: "Testing…" spinner, timeout 5 s.
    static let testTimeout: Duration = .seconds(5)

    // MARK: Fields (BackendSchema › Machine)

    // Changing anything a Test connection used resets its result (it no longer applies).
    var kind: MachineKind { didSet { resetTest() } }
    var name: String
    var host: String { didSet { resetTest() } }
    /// Text, so a non-numeric entry is reported as an out-of-range port rather than lost.
    var portText: String { didSet { resetTest() } }
    var username: String { didSet { resetTest() } }
    var password: String { didSet { resetTest() } }
    var groupChoice: GroupChoice
    var newGroupName = ""
    var isFavorite: Bool
    var isWatched: Bool
    var scalingMode: ScalingMode
    var sharedClipboard: Bool

    // MARK: State

    /// Field errors from the last Save / Test (cleared as the user edits the field).
    private(set) var issues: [MachineValidator.Issue] = []
    /// Keychain read failed when the editor opened: the stored password is unknown and an empty
    /// field means "unchanged" (never "delete").
    private(set) var passwordReadError: KeychainError?
    /// Keychain write (or delete of a cleared password) failed on Save: nothing was saved,
    /// the sheet stays open.
    private(set) var passwordFailure: PasswordFailure?
    /// Where the stored password lives; `.local` → "stored on this Mac only" note.
    private(set) var passwordScope: PasswordScope?
    /// SwiftData failed on Save.
    private(set) var saveError: String?
    private(set) var testState: TestConnectionState = .idle

    let groups: [MachineGroup]
    let isNew: Bool

    @ObservationIgnored private let editing: Machine?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let passwords: any MachinePasswordStore
    @ObservationIgnored private let tester: any ConnectionTester
    @ObservationIgnored private let validator = MachineValidator()
    /// Password as loaded from the Keychain; `nil` when none is stored or the read failed.
    @ObservationIgnored private let storedPassword: String?
    @ObservationIgnored private let storedScope: PasswordScope?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    /// Bumped by every test start and cancel, so a late result never lands on a newer attempt.
    @ObservationIgnored private var testGeneration = 0
    /// SwiftData save, injectable so tests can make it fail.
    @ObservationIgnored var persist: (ModelContext) throws -> Void = { try $0.save() }

    struct PasswordFailure: Equatable {
        let error: KeychainError
        /// The user cleared the password and deleting it failed.
        let deleting: Bool
    }

    /// `discovered` pre-fills a new machine from a Discovery Panel row (kind, name, host, port;
    /// user name empty). Ignored when editing an existing machine.
    init(machine: Machine?, context: ModelContext, passwords: any MachinePasswordStore,
         tester: any ConnectionTester, defaultSharedClipboard: Bool, discovered: DiscoveredMachine? = nil) {
        self.editing = machine
        self.context = context
        self.passwords = passwords
        self.tester = tester
        isNew = machine == nil
        groups = ((try? context.fetch(FetchDescriptor<MachineGroup>())) ?? []).sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }

        kind = machine?.kindValue ?? .macARD
        name = machine?.name ?? ""
        host = machine?.host ?? ""
        portText = String(machine?.port ?? 5900)
        username = machine?.username ?? ""
        groupChoice = machine?.group.map { .existing($0.id) } ?? .none
        isFavorite = machine?.isFavorite ?? false
        isWatched = machine?.isWatched ?? false
        scalingMode = machine?.scalingModeValue ?? .fit
        sharedClipboard = machine?.sharedClipboard ?? defaultSharedClipboard
        if machine == nil, let discovered {
            kind = discovered.kind
            name = String(discovered.name.prefix(MachineValidator.maxNameLength))
            host = discovered.host
            portText = String(discovered.port)
        }

        var loaded: (password: String, scope: PasswordScope)?
        if let machine {
            do {
                loaded = try passwords.storedPassword(for: machine.id)
            } catch {
                passwordReadError = error
            }
        }
        storedPassword = loaded?.password
        storedScope = loaded?.scope
        passwordScope = loaded?.scope
        password = loaded?.password ?? ""
    }

    /// Anthropic VM has no user field (DesignBrief › Machine Editor); Mac ARD requires it.
    var showsUsername: Bool { kind != .anthropicVM }
    var requiresUsername: Bool { kind == .macARD }
    /// VNC and Anthropic VM servers may have no password: empty means none, so the server must offer
    /// security type 1 (TRD › Security). Mac ARD shows no "Optional" placeholder: its server asks
    /// for the password at connect time, which then fails as credentials required.
    var passwordIsOptional: Bool { kind != .macARD }

    func issue(for field: MachineValidator.Field) -> MachineValidator.Reason? {
        issues.first { $0.field == field }?.reason
    }

    /// Clears a field's error once the user edits it.
    func clearIssue(for field: MachineValidator.Field) {
        issues.removeAll { $0.field == field }
    }

    func clearPasswordError() {
        passwordFailure = nil
    }

    // MARK: Validation

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: Int { Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    private var effectiveUsername: String? {
        guard showsUsername else { return nil }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var draft: MachineDraft {
        MachineDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                     host: trimmedHost, port: port, username: effectiveUsername)
    }

    /// Runs MachineValidator (name, host, port, username, duplicate `host:port`) and the group
    /// name rule when "New Group…" is chosen. Returns true when everything passes.
    @discardableResult
    func validate() -> Bool {
        let machines = (try? context.fetch(FetchDescriptor<Machine>())) ?? []
        let existingKeys = Dictionary(machines.map { ($0.id, $0.normalizedKey) }, uniquingKeysWith: { first, _ in first })
        var found = validator.validate(draft, existingKeys: existingKeys, editingID: editing?.id)
        if groupChoice == .new {
            let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            found += validator.validateGroupName(newGroupName, existingNames: names)
        }
        issues = found
        return found.isEmpty
    }

    // MARK: Save

    /// Validates, writes the password to the Keychain, then saves the machine. Returns the saved
    /// machine, or `nil` with the errors set (the sheet stays open). The Keychain goes first so a
    /// machine is never saved without the password the user typed: if the Keychain refuses it,
    /// nothing is written. (-34018 is not a refusal: the password then goes to a local item.)
    func save() -> Machine? {
        saveError = nil
        passwordFailure = nil
        guard validate() else { return nil }

        let machine = editing ?? Machine()
        let passwordChanged = password != (storedPassword ?? "")
        do {
            try applyPasswordChange(for: machine.id)
        } catch {
            passwordFailure = PasswordFailure(error: error, deleting: password.isEmpty)
            return nil
        }

        let draft = self.draft
        machine.name = draft.name
        machine.kindValue = draft.kind
        machine.host = draft.host
        machine.port = draft.port
        machine.username = draft.username
        machine.isFavorite = isFavorite
        machine.isWatched = isWatched
        machine.scalingModeValue = scalingMode
        machine.sharedClipboard = sharedClipboard
        switch groupChoice {
        case .none:
            machine.group = nil
        case .existing(let id):
            machine.group = groups.first { $0.id == id }
        case .new:
            let group = MachineGroup(name: newGroupName.trimmingCharacters(in: .whitespacesAndNewlines),
                                     sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(group)
            machine.group = group
        }
        if editing == nil { context.insert(machine) }

        do {
            try persist(context)
        } catch {
            context.rollback()
            if passwordChanged { restorePassword(for: machine.id) }
            saveError = error.localizedDescription
            return nil
        }
        cancelTest()
        return machine
    }

    /// Unchanged password → no Keychain call. Empty → delete. Otherwise → save (synced, or local
    /// on -34018). When the read failed, `storedPassword` is nil, so an empty field counts as
    /// unchanged and never deletes.
    private func applyPasswordChange(for id: UUID) throws(KeychainError) {
        if password == (storedPassword ?? "") { return }
        if password.isEmpty {
            try passwords.deletePassword(for: id)
            passwordScope = nil
        } else {
            passwordScope = try passwords.storePassword(password, for: id)
        }
    }

    /// SwiftData refused the save after the Keychain changed: put the password back as it was
    /// (a new machine has no password to keep).
    private func restorePassword(for id: UUID) {
        passwordScope = storedScope
        if let storedPassword, let scope = storedScope {
            try? passwords.setPassword(storedPassword, for: id, scope: scope)
        } else {
            try? passwords.deletePassword(for: id)
        }
    }

    // MARK: Test connection

    /// Credentials as typed. With an unreadable stored password and an empty field, the test runs
    /// without a password (the server then reports what it needs).
    var testCredentials: RFBCredentials {
        RFBCredentials(kind: kind, username: username, password: password)   // the session's rule too
    }

    /// Same validation as Save, then one RFB open/close with a 5 s timeout.
    func testConnection() {
        cancelTest()
        guard validate(), let port = UInt16(exactly: port) else { return }
        testGeneration += 1
        let generation = testGeneration
        testState = .testing
        let tester = self.tester
        let host = trimmedHost
        let credentials = testCredentials
        testTask = Task { [weak self] in
            // Untyped closure: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
            let outcome: TestConnectionState
            do {
                try await tester.test(host: host, port: port, credentials: credentials, timeout: Self.testTimeout)
                outcome = .succeeded
            } catch {
                let failure = (error as? RFBError).flatMap(TestConnectionFailure.init)
                outcome = failure.map(TestConnectionState.failed) ?? .idle
            }
            self?.finishTest(outcome, generation: generation)
        }
    }

    /// A field the test used changed: drop the result and any running attempt.
    private func resetTest() {
        guard testState != .idle || testTask != nil else { return }
        cancelTest()
        testState = .idle
    }

    private func finishTest(_ outcome: TestConnectionState, generation: Int) {
        guard generation == testGeneration else { return }
        testState = outcome
        testTask = nil
    }

    /// Cancels a running test (sheet closed, Save, new test). The RFB connection is closed by
    /// `RFBConnection.open`'s cancellation handler.
    func cancelTest() {
        testGeneration += 1
        testTask?.cancel()
        testTask = nil
        if testState == .testing { testState = .idle }
    }
}
