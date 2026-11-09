import Foundation
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit
import SSHKit

/// Machine Editor state (AppFlow › Machine Editor): fields, validation, Keychain password,
/// Save and Test connection. SSH machines (AppFlow › Machine Editor › SSH machines) add the
/// authentication method, imported keys, port forwards, the `~/.ssh/config` import and the host key
/// check of their Test: `MachineEditorSSH.swift`.
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
    var kind: MachineKind {
        didSet {
            resetTest()
            // AppFlow: switching kind sets its default port only if the user never touched the port.
            if !portTouched, portText == String(oldValue.defaultPort) {
                applyingPortDefault = true
                portText = String(kind.defaultPort)
                applyingPortDefault = false
            }
            if kind == .ssh { sshFieldsShown() }
            // A new machine's Shared Clipboard follows the kind until the user sets it (T5.3 M1).
            if isNew, !sharedClipboardTouched {
                applyingKindDefault = true
                sharedClipboard = Self.defaultSharedClipboard(for: kind, appDefault: appDefaultSharedClipboard)
                applyingKindDefault = false
            }
        }
    }
    var name: String
    var host: String { didSet { resetTest() } }
    /// Text, so a non-numeric entry is reported as an out-of-range port rather than lost.
    var portText: String {
        didSet {
            resetTest()
            if !applyingPortDefault { portTouched = true }
        }
    }
    var username: String { didSet { resetTest() } }
    var password: String { didSet { resetTest() } }
    var groupChoice: GroupChoice
    var newGroupName = ""
    var isFavorite: Bool
    var isWatched: Bool
    var scalingMode: ScalingMode
    var sharedClipboard: Bool {
        didSet { if !applyingKindDefault { sharedClipboardTouched = true } }
    }

    // MARK: SSH fields (BackendSchema › Machine, post-1.0)

    var sshAuth: SSHAuthMethod {
        didSet {
            resetTest()
            keyProblem = nil
            if sshAuth == .keyInSSHFolder { sshFieldsShown() }
        }
    }
    /// The key file of `keyInSSHFolder`, relative to `~/.ssh` (picked from `sshKeyChoices`).
    var sshKeyFileName: String { didSet { resetTest() } }
    /// Rows of the Port forwards list (`addForward` / `removeForward`).
    var portForwards: [PortForward]

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

    // Set by the SSH part (`MachineEditorSSH.swift`), hence internal setters.

    /// The key of an "Import Key…" not saved yet: what the editor shows (its text is kept apart, in
    /// memory only, until Save).
    var importedKey: ImportedKeySummary?
    /// "Import Key…" refused the file, or the imported-key method has no key yet.
    var keyProblem: KeyImportProblem?
    /// The Keychain refused the imported key (or its passphrase) on Save: nothing was saved.
    var keyFailure: KeychainError?
    /// File names of the granted `~/.ssh` that may be keys, plus the current name if not among them.
    var sshKeyChoices: [String] = []
    var sshFolderGranted = false
    /// Why the last "Grant access to ~/.ssh…" granted nothing.
    var sshFolderProblem: SSHFolderRequestProblem?
    /// RemoteDeck trusts a key for the saved machine's `host:port`: "Remove from RemoteDeck's
    /// trusted keys…" is offered.
    var hasTrustedHostKey = false
    /// The SSH Config Import Sheet's content.
    var configImport: ConfigImportState?
    /// The sheet over the editor: the Host Key Sheet or a passphrase during a Test, the passphrase of
    /// a newly imported key on Save, or the SSH Config Import Sheet.
    var sheet: EditorSheet?

    let groups: [MachineGroup]
    let isNew: Bool

    @ObservationIgnored let ssh: SSHServices
    @ObservationIgnored let sshTester: any SSHTester
    @ObservationIgnored let keyPicker: any KeyFilePicking
    /// The imported key's text, from "Import Key…" until Save; never in the store nor logged.
    @ObservationIgnored var pendingKeyText: String?
    /// The passphrase given for `pendingKeyText` on Save, and whether to remember it.
    @ObservationIgnored var pendingKeyPassphrase: (passphrase: String, remember: Bool)?
    /// Resumes the Host Key Sheet's or the test passphrase sheet's waiter.
    @ObservationIgnored var hostKeyWaiter: (id: Int, continuation: CheckedContinuation<Bool, Never>)?
    @ObservationIgnored var passphraseWaiter: CheckedContinuation<String?, Never>?
    @ObservationIgnored var nextPromptID = 0
    /// Why the validator of test `generation` refused the key.
    @ObservationIgnored var hostKeyRefusal: (generation: Int, failure: TestConnectionFailure)?
    @ObservationIgnored private var portTouched = false
    @ObservationIgnored private var applyingPortDefault = false
    @ObservationIgnored private let appDefaultSharedClipboard: Bool
    @ObservationIgnored private var sharedClipboardTouched = false
    @ObservationIgnored private var applyingKindDefault = false
    @ObservationIgnored let editing: Machine?
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let passwords: any MachinePasswordStore
    @ObservationIgnored private let tester: any ConnectionTester
    /// "Connect anyway" confirmations: a Test reaches a public address only for this machine at the
    /// host it was confirmed for (T5.3).
    @ObservationIgnored private let publicConsents: any PublicAddressConsents
    @ObservationIgnored private let validator = MachineValidator()
    /// Password as loaded from the Keychain; `nil` when none is stored or the read failed.
    @ObservationIgnored private let storedPassword: String?
    @ObservationIgnored private let storedScope: PasswordScope?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    /// Bumped by every test start and cancel, so a late result never lands on a newer attempt.
    @ObservationIgnored private(set) var testGeneration = 0
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
         tester: any ConnectionTester, defaultSharedClipboard: Bool, discovered: DiscoveredMachine? = nil,
         publicConsents: any PublicAddressConsents = InMemoryPublicAddressConsents(),
         ssh: SSHServices = .inMemory(), sshTester: any SSHTester = DisabledSSHTester(),
         keyPicker: any KeyFilePicking = NoKeyFilePicker()) {
        self.publicConsents = publicConsents
        self.ssh = ssh
        self.sshTester = sshTester
        self.keyPicker = keyPicker
        self.editing = machine
        self.context = context
        self.passwords = passwords
        self.tester = tester
        appDefaultSharedClipboard = defaultSharedClipboard
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
        sharedClipboard = machine?.sharedClipboard
            ?? Self.defaultSharedClipboard(for: machine?.kindValue ?? .macARD, appDefault: defaultSharedClipboard)
        sshAuth = machine?.sshAuth ?? .password
        sshKeyFileName = machine?.sshKeyFileName ?? ""
        portForwards = machine?.portForwards ?? []
        if machine == nil, let discovered {
            kind = discovered.kind
            name = String(discovered.name.prefix(MachineValidator.maxNameLength))
            host = discovered.host
            portText = String(discovered.port)
            sharedClipboard = Self.defaultSharedClipboard(for: discovered.kind, appDefault: defaultSharedClipboard)
        }
        sharedClipboardTouched = false   // the assignments above are defaults, not the user's choice

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
        refreshTrustState()
        if kind == .ssh { sshFieldsShown() }
    }

    /// Shared Clipboard of a new machine (T5.3 M1): off for an Anthropic VM (a sandbox Claude drives
    /// should not read this Mac's pasteboard by default), Settings' default for the other kinds.
    static func defaultSharedClipboard(for kind: MachineKind, appDefault: Bool) -> Bool {
        kind == .anthropicVM ? false : appDefault
    }

    /// The host field holds an IP literal on the public Internet (T5.3 H1): an orange note under it.
    /// A host name is classified when a connection resolves it.
    /// SSH is encrypted: no note (AppFlow › SSH machines).
    var hostIsPublicAddress: Bool {
        kind != .ssh && AddressScope(literal: trimmedHost)?.isPublicInternet == true
    }

    /// Anthropic VM has no user field (DesignBrief › Machine Editor); Mac ARD and SSH require it.
    var showsUsername: Bool { kind != .anthropicVM }
    var requiresUsername: Bool { kind == .macARD || kind == .ssh }
    /// VNC and Anthropic VM servers may have no password: empty means none, so the server must offer
    /// security type 1 (TRD › Security). Mac ARD shows no "Optional" placeholder: its server asks
    /// for the password at connect time, which then fails as credentials required. SSH's password
    /// method needs one too.
    var passwordIsOptional: Bool { kind != .macARD && kind != .ssh }
    /// Scaling and Shared Clipboard only make sense for a screen (hidden for SSH).
    var showsScreenSettings: Bool { kind != .ssh }
    /// SSH shows the password only for its password method.
    var showsPasswordField: Bool { kind != .ssh || sshAuth == .password }

    func issue(for field: MachineValidator.Field) -> MachineValidator.Reason? {
        issues.first { $0.field == field && $0.forwardID == nil }?.reason
    }

    /// The error under one row of the Port forwards list.
    func forwardIssue(for id: PortForward.ID) -> MachineValidator.Reason? {
        issues.first { $0.field == .portForwards && $0.forwardID == id }?.reason
    }

    /// Clears a forward row's error once the user edits it.
    func clearForwardIssue(for id: PortForward.ID) {
        issues.removeAll { $0.field == .portForwards && $0.forwardID == id }
    }

    /// Clears a field's error once the user edits it.
    func clearIssue(for field: MachineValidator.Field) {
        issues.removeAll { $0.field == field }
    }

    func clearPasswordError() {
        passwordFailure = nil
    }

    // MARK: Validation

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var port: Int { Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    var effectiveUsername: String? {
        guard showsUsername else { return nil }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var draft: MachineDraft {
        let fileName = sshKeyFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MachineDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                            host: trimmedHost, port: port, username: effectiveUsername,
                            sshAuth: sshAuth, sshKeyFileName: fileName.isEmpty ? nil : fileName,
                            portForwards: cleanedForwards)
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
        let sshReady = validateSSHKey()
        return found.isEmpty && sshReady
    }

    // MARK: Save

    /// Validates, writes the password to the Keychain, then saves the machine. Returns the saved
    /// machine, or `nil` with the errors set (the sheet stays open). The Keychain goes first so a
    /// machine is never saved without the password the user typed: if the Keychain refuses it,
    /// nothing is written. (-34018 is not a refusal: the password then goes to a local item.)
    func save() -> Machine? {
        saveError = nil
        passwordFailure = nil
        keyFailure = nil
        guard validate() else { return nil }
        // A newly imported encrypted key: its passphrase first (`submitSavePassphrase` saves again).
        if needsSavePassphrase {
            sheet = .savePassphrase(rejected: false)
            return nil
        }

        let machine = editing ?? Machine()
        let previousAddress = editing.map { (host: $0.host, port: $0.port) }
        let previousSSH = editing.map { (auth: $0.kindValue == .ssh ? $0.sshAuth : nil, keyFile: $0.sshKeyFileName) }
        // The password is the password method's only: an SSH key method leaves it as it is.
        let usesPassword = showsPasswordField
        let passwordChanged = usesPassword && password != (storedPassword ?? "")
        if usesPassword {
            do {
                try applyPasswordChange(for: machine.id)
            } catch {
                passwordFailure = PasswordFailure(error: error, deleting: password.isEmpty)
                return nil
            }
        }
        let keyRollback: SSHKeyRollback?
        do {
            keyRollback = try writeImportedKey(for: machine.id)
        } catch {
            keyFailure = error
            if passwordChanged { restorePassword(for: machine.id) }
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
        // Only an SSH machine writes its SSH fields: a screen machine keeps them unset (no synced
        // change on each save), and one switched away from SSH keeps what it had.
        if draft.kind == .ssh {
            machine.sshAuth = draft.sshAuth
            machine.sshKeyFileName = draft.sshKeyFileName
            machine.portForwards = draft.portForwards
        }
        // Orders duplicates when iCloud Sync merges them (T4.3): the last edit, on any Mac, wins.
        machine.modifiedAt = .now
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
            keyRollback?.undo(ssh.secrets)
            saveError = error.localizedDescription
            return nil
        }
        sshSaved(machine, previousAddress: previousAddress, previousSSH: previousSSH)
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
        if kind == .ssh {
            testTask = Task { [weak self] in
                guard let outcome = await self?.runSSHTest(port: port, generation: generation) else { return }
                self?.finishTest(outcome, generation: generation)
            }
            return
        }
        let tester = self.tester
        let host = trimmedHost
        let credentials = testCredentials
        // A new machine, or one whose host changed, was never confirmed at this host.
        let allowsPublicInternet = editing.map { publicConsents.hasConfirmed($0.id, host: host) } ?? false
        testTask = Task { [weak self] in
            // Untyped closure: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
            let outcome: TestConnectionState
            do {
                try await tester.test(host: host, port: port, credentials: credentials, timeout: Self.testTimeout,
                                      allowsPublicInternet: allowsPublicInternet)
                outcome = .succeeded
            } catch {
                let failure = (error as? RFBError).flatMap(TestConnectionFailure.init)
                outcome = failure.map(TestConnectionState.failed) ?? .idle
            }
            self?.finishTest(outcome, generation: generation)
        }
    }

    /// A field the test used changed: drop the result and any running attempt.
    func resetTest() {
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
        dismissTestPrompts()
        if testState == .testing { testState = .idle }
    }
}
