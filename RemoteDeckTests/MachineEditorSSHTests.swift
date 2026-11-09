import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import SSHKit
@testable import RemoteDeck

/// The Machine Editor for SSH machines (plan Task 10, AppFlow › Machine Editor › SSH machines): kind
/// defaults, authentication methods, imported keys (Keychain only), `~/.ssh/config` import, port
/// forwards, the SSH Test connection with the Host Key Sheet, and trusted keys on edit. Never a
/// panel, the network, the Keychain or the real `~/.ssh`.
@MainActor
final class MachineEditorSSHTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let folder: FakeSSHFolderAccess
    let trust: InMemoryTrustedHostKeys
    let secrets = FakeSSHSecrets()
    /// Where the key files the "Import Key…" panel returns are written; removed after each test
    /// (the unsigned test host is not sandboxed: this is the real temporary folder).
    let keyFolder = FileManager.default.temporaryDirectory.appending(path: "remotedeck-test-keys-\(UUID().uuidString)")

    static let raspcorseConfig = """
    Host raspcorse
        HostName raspcorse
        User vincent
        IdentityFile ~/.ssh/id_ed25519
        IdentitiesOnly yes
    Host *
        ServerAliveInterval 30
    Host nas
        HostName nas.local
        User admin
        Port 2222
    """

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
        folder = FakeSSHFolderAccess()
        trust = InMemoryTrustedHostKeys(folder: folder)
        try FileManager.default.createDirectory(at: keyFolder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: keyFolder)
    }

    private var ssh: SSHServices { SSHServices(folder: folder, trustedHostKeys: trust, secrets: secrets) }

    private func editor(_ machine: Machine? = nil, tester: FakeSSHTester = FakeSSHTester(),
                        picker: FakeKeyFilePicker = FakeKeyFilePicker()) -> MachineEditorModel {
        MachineEditorModel(machine: machine, context: context, passwords: passwords,
                           tester: FakeConnectionTester(), defaultSharedClipboard: true,
                           ssh: ssh, sshTester: tester, keyPicker: picker)
    }

    /// A new SSH machine with valid fields.
    private func sshEditor(tester: FakeSSHTester = FakeSSHTester(), auth: SSHAuthMethod = .password) -> MachineEditorModel {
        let model = editor(tester: tester)
        model.kind = .ssh
        model.name = "Pi"
        model.host = "pi.local"
        model.username = "vincent"
        model.password = "s3cret"
        model.sshAuth = auth
        return model
    }

    private func savedSSHMachine(host: String = "pi.local", port: Int = 22, auth: SSHAuthMethod = .password,
                                 keyFile: String? = nil) throws -> Machine {
        let machine = Machine(name: "Pi", kind: .ssh, host: host, port: port, username: "vincent",
                              sshAuthMethod: auth, sshKeyFileName: keyFile)
        context.insert(machine)
        try context.save()
        return machine
    }

    private func machines() throws -> [Machine] {
        try context.fetch(FetchDescriptor<Machine>())
    }

    /// A key file the "Import Key…" panel returns (in the test host's temporary folder).
    private func keyFile(_ text: String) throws -> URL {
        let url = keyFolder.appending(path: UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static let hostKey = SSHTestKeys.hostKey(SSHTestKeys.ed25519Public)
    private static let otherHostKey = SSHTestKeys.hostKey(SSHTestKeys.ed25519EncryptedPublic)

    // MARK: Kind

    @Test func testSwitchingToSSHSetsPort22OnlyIfPortUntouched() {
        let model = editor()
        #expect(model.portText == "5900")
        model.kind = .ssh
        #expect(model.portText == "22")
        model.kind = .vnc
        #expect(model.portText == "5900")

        let touched = editor()
        touched.portText = "5901"
        touched.kind = .ssh
        #expect(touched.portText == "5901")
        // Typed back to a default, it is still the user's port.
        touched.portText = "5900"
        touched.kind = .vnc
        touched.kind = .ssh
        #expect(touched.portText == "5900")
    }

    @Test func testSSHHidesScalingAndClipboard() {
        let model = editor()
        #expect(model.showsScreenSettings)
        model.kind = .ssh
        #expect(!model.showsScreenSettings)
        #expect(model.showsUsername && model.requiresUsername)
        #expect(!model.passwordIsOptional)
        // SSH is encrypted: no public-address note.
        model.host = "203.0.113.10"
        #expect(!model.hostIsPublicAddress)
        // The password field is the password method's only.
        #expect(model.showsPasswordField)
        model.sshAuth = .keyInSSHFolder
        #expect(!model.showsPasswordField)
    }

    /// A screen machine's save leaves the SSH fields unset (no synced change for them).
    @Test func screenMachineStoresNoSSHFields() throws {
        let model = editor()
        model.name = "Mini"
        model.host = "mini.local"
        model.username = "vincent"
        model.password = "s3cret"
        let machine = try #require(model.save())
        #expect(machine.sshAuthMethod == nil && machine.sshKeyFileName == nil && machine.portForwardsData == nil)
    }

    @Test func editorOffersSSH() {
        #expect(MachineKind.editorKinds.contains(.ssh))
    }

    @Test func sshRequiresUserNameWithKindNeutralMessage() throws {
        let model = sshEditor()
        model.username = ""
        #expect(model.save() == nil)
        #expect(model.issue(for: .username) == .empty)
        let en = Strings.table["en"]?["err_username_empty"] ?? ""
        #expect(!en.contains("Mac"))
    }

    // MARK: Import from ~/.ssh/config

    @Test func testImportFromConfigFillsFields() async throws {
        folder.granted = true
        folder.files = ["config": Self.raspcorseConfig, "id_ed25519": SSHTestKeys.ed25519]
        let model = editor()
        await model.openConfigImport()
        #expect(model.sheet == .configImport)
        let hosts = try #require(model.configImport?.hosts)
        #expect(hosts.map(\.alias) == ["raspcorse", "nas"])

        model.chooseConfigHost(hosts[0])
        #expect(model.sheet == nil)
        #expect(model.kind == .ssh)
        #expect(model.name == "raspcorse")
        #expect(model.host == "raspcorse")
        #expect(model.username == "vincent")
        #expect(model.portText == "22")
        #expect(model.sshAuth == .keyInSSHFolder)
        #expect(model.sshKeyFileName == "id_ed25519")
        let saved = try #require(model.save())
        #expect(saved.sshAuth == .keyInSSHFolder && saved.sshKeyFileName == "id_ed25519")

        // No IdentityFile: password; Port is kept.
        let other = editor()
        other.applyConfigHost(hosts[1])
        #expect(other.host == "nas.local" && other.portText == "2222" && other.username == "admin")
        #expect(other.sshAuth == .password)
    }

    @Test func configImportAsksForTheFolderFirst() async throws {
        folder.files = ["config": Self.raspcorseConfig]
        folder.grantsOnRequest = true
        let model = editor()
        await model.openConfigImport()
        #expect(folder.calls.contains("requestAccess"))
        #expect(model.sheet == .configImport)
        #expect(model.configImport?.hosts?.count == 2)
    }

    @Test func configImportWithoutGrantOpensNothingAndSaysWhy() async {
        folder.files = ["config": Self.raspcorseConfig]
        folder.lastRequestProblem = .notSSHFolder("Documents")
        let model = editor()
        await model.openConfigImport()
        #expect(model.sheet == nil)
        #expect(model.sshFolderProblem == .notSSHFolder("Documents"))
        #expect(!folder.calls.contains("readFile(config)"))
    }

    @Test func configWithoutUsableHostSaysSoInTheSheet() async {
        folder.granted = true
        folder.files = ["config": "Host *\n  User root\n"]
        let model = editor()
        await model.openConfigImport()
        #expect(model.sheet == .configImport)
        #expect(model.configImport == .empty)

        folder.files = [:]
        await model.openConfigImport()
        #expect(model.configImport == .noFile)
    }

    // MARK: Key in ~/.ssh

    @Test func sshFolderKeyListOffersOnlyKeyNames() {
        folder.granted = true
        folder.files = ["id_ed25519": "x", "id_ed25519.pub": "x", "known_hosts": "x", "known_hosts.old": "x",
                        "config": "x", "authorized_keys": "x", ".DS_Store": "x", "id_rsa": "x", "azure/vm": "x"]
        let model = sshEditor(auth: .keyInSSHFolder)
        #expect(model.sshKeyChoices == ["id_ed25519", "id_rsa"])
        // The usual key is picked when none was chosen.
        #expect(model.sshKeyFileName == "id_ed25519")
        // Names only: no key is read to list them.
        #expect(!folder.calls.contains { $0.hasPrefix("readFile") })
    }

    @Test func aFileNameNotInTheListStaysAChoice() throws {
        folder.granted = true
        folder.files = ["id_ed25519": "x"]
        let model = editor(try savedSSHMachine(auth: .keyInSSHFolder, keyFile: "azure/vm_key"))
        #expect(model.sshKeyChoices == ["azure/vm_key", "id_ed25519"])
        #expect(model.sshKeyFileName == "azure/vm_key")
    }

    @Test func keyInFolderWithoutGrantOffersTheGrant() async {
        folder.files = ["id_ed25519": "x"]
        let model = sshEditor(auth: .keyInSSHFolder)
        #expect(!model.sshFolderGranted)
        #expect(model.sshKeyChoices.isEmpty)

        folder.lastRequestProblem = .notSSHFolder("Desktop")
        await model.grantSSHFolder()
        #expect(model.sshFolderProblem == .notSSHFolder("Desktop"))
        #expect(!model.sshFolderGranted)

        folder.lastRequestProblem = nil
        folder.grantsOnRequest = true
        await model.grantSSHFolder()
        #expect(model.sshFolderGranted && model.sshFolderProblem == nil)
        #expect(model.sshKeyChoices == ["id_ed25519"])
    }

    // MARK: Imported key

    @Test func testImportedKeySavedToKeychainNotStore() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        #expect(model.importedKey?.algorithm == "ssh-ed25519")
        #expect(model.importedKey?.isEncrypted == false)

        let machine = try #require(model.save())
        #expect(secrets.items[.sshPrivateKey(machine.id)] == SSHTestKeys.ed25519)
        #expect(secrets.items[.sshKeyPassphrase(machine.id)] == nil)
        let stored = try #require(try machines().first)
        #expect(stored.sshAuth == .importedKey)
        let storedText = [stored.name, stored.host, stored.username ?? "", stored.sshKeyFileName ?? "",
                          stored.sshAuthMethod ?? "", String(decoding: stored.portForwardsData ?? Data(), as: UTF8.self)]
        #expect(!storedText.contains { $0.contains("OPENSSH") || $0.contains("b3BlbnNzaC1rZXktdjE") })
        // Re-saving does not ask or write the key again.
        let again = editor(machine)
        #expect(again.importedKey == nil && again.sshAuth == .importedKey)
        secrets.items[.sshPrivateKey(machine.id)] = "kept"
        #expect(again.save() != nil)
        #expect(secrets.items[.sshPrivateKey(machine.id)] == "kept")
    }

    @Test func importedKeyIsRequiredForThatMethod() {
        let model = sshEditor(auth: .importedKey)
        #expect(model.save() == nil)
        #expect(model.keyProblem == .noKey)
    }

    @Test(arguments: [("hello", KeyImportProblem.notAKey),
                      ("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n",
                       .unsupported("RSA PRIVATE KEY"))])
    func badKeyFilesAreRefused(_ text: String, _ expected: KeyImportProblem) async throws {
        let model = sshEditor(auth: .importedKey)
        await #expect(throws: expected) { try await model.importKey(from: try keyFile(text)) }
        #expect(model.importedKey == nil)
    }

    @Test func chooseKeyToImportUsesThePanel() async throws {
        let picker = FakeKeyFilePicker(url: try keyFile(SSHTestKeys.ed25519))
        let model = editor(picker: picker)
        model.kind = .ssh
        model.sshAuth = .importedKey
        await model.chooseKeyToImport()
        #expect(model.importedKey?.algorithm == "ssh-ed25519")
    }

    @Test func testEncryptedImportedKeyAsksPassphraseOnSave() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519Encrypted))
        #expect(model.importedKey?.isEncrypted == true)

        #expect(model.save() == nil)
        #expect(model.sheet == .savePassphrase(rejected: false))
        #expect(secrets.items.isEmpty)
        #expect(try machines().isEmpty)

        #expect(await model.submitSavePassphrase("not-it", remember: true) == nil)
        #expect(model.sheet == .savePassphrase(rejected: true))
        #expect(secrets.items.isEmpty)

        let machine = try #require(await model.submitSavePassphrase(SSHTestKeys.passphrase, remember: true))
        #expect(model.sheet == nil)
        #expect(secrets.items[.sshPrivateKey(machine.id)] == SSHTestKeys.ed25519Encrypted)
        #expect(secrets.items[.sshKeyPassphrase(machine.id)] == SSHTestKeys.passphrase)
    }

    @Test func notRememberedPassphraseIsNotStoredAndAStaleOneGoes() async throws {
        let machine = try savedSSHMachine(auth: .importedKey)
        secrets.items[.sshPrivateKey(machine.id)] = "old key"
        secrets.items[.sshKeyPassphrase(machine.id)] = "old passphrase"
        let model = editor(machine)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519Encrypted))
        #expect(model.save() == nil)
        _ = try #require(await model.submitSavePassphrase(SSHTestKeys.passphrase, remember: false))
        #expect(secrets.items[.sshPrivateKey(machine.id)] == SSHTestKeys.ed25519Encrypted)
        #expect(secrets.items[.sshKeyPassphrase(machine.id)] == nil)
    }

    @Test func cancellingTheSavePassphraseSavesNothing() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519Encrypted))
        #expect(model.save() == nil)
        model.cancelSavePassphrase()
        #expect(model.sheet == nil)
        #expect(try machines().isEmpty && secrets.items.isEmpty)
    }

    @Test func keychainRefusalSavesNoMachine() async throws {
        secrets.saveError = KeychainError(status: -25293)
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        #expect(model.save() == nil)
        #expect(model.keyFailure == KeychainError(status: -25293))
        #expect(try machines().isEmpty)
    }

    @Test func storeFailureRemovesTheNewKey() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        struct Refused: Error {}
        model.persist = { _ in throw Refused() }
        #expect(model.save() == nil)
        #expect(secrets.items.isEmpty)
    }

    // MARK: Port forwards

    @Test func testForwardValidationErrorsShown() throws {
        let model = sshEditor()
        model.addForward()
        model.addForward()
        model.addForward()
        #expect(model.portForwards.count == 3)
        #expect(model.portForwards.allSatisfy { $0.remoteHost == "localhost" })
        model.portForwards[0].localPort = 8080
        model.portForwards[0].remotePort = 80
        model.portForwards[1].localPort = 80        // below 1024
        model.portForwards[1].remotePort = 80
        model.portForwards[2].localPort = 8080      // repeats row 1
        model.portForwards[2].remotePort = 8080
        let ids = model.portForwards.map(\.id)

        #expect(model.save() == nil)
        #expect(model.forwardIssue(for: ids[0]) == nil)
        #expect(model.forwardIssue(for: ids[1]) == .invalidForwardPort)
        #expect(model.forwardIssue(for: ids[2]) == .duplicateLocalPort)

        model.removeForward(ids[1])
        model.portForwards[1].localPort = 8443
        let machine = try #require(model.save())
        #expect(machine.portForwards.map(\.localPort) == [8080, 8443])
    }

    @Test func emptyRemoteHostIsSavedAsLocalhost() throws {
        let model = sshEditor()
        model.addForward()
        model.portForwards[0].localPort = 8080
        model.portForwards[0].remotePort = 80
        model.portForwards[0].remoteHost = "  "
        model.portForwards[0].label = " "
        let machine = try #require(model.save())
        #expect(machine.portForwards.first?.remoteHost == "localhost")
        #expect(machine.portForwards.first?.label == nil)
    }

    // MARK: Test connection

    @Test func testConnectionUsesTheTypedFieldsAndNeverSaves() async throws {
        let tester = FakeSSHTester()
        let model = sshEditor(tester: tester)
        model.testConnection()
        #expect(await waitUntil { model.testState == .succeeded })
        let call = try #require(await tester.calls.first)
        #expect(call.host == "pi.local" && call.port == 22)
        #expect(call.credentials == .password(user: "vincent", password: "s3cret"))
        #expect(try machines().isEmpty)
    }

    @Test func testTestConnectionUnknownHostKeyAsksThenTrusts() async throws {
        let model = sshEditor(tester: FakeSSHTester(hostKey: Self.hostKey))
        model.testConnection()
        #expect(await waitUntil { model.sheet != nil })
        guard case .hostKey(let prompt) = model.sheet else {
            Issue.record("expected the Host Key Sheet, got \(String(describing: model.sheet))")
            return
        }
        #expect(prompt.host == "pi.local" && prompt.port == 22 && prompt.key == Self.hostKey)
        #expect(model.testState == .testing)
        #expect(trust.decision(for: Self.hostKey, host: "pi.local", port: 22) == .unknown)

        model.trustHostKey()
        #expect(model.sheet == nil)
        #expect(await waitUntil { model.testState == .succeeded })
        #expect(trust.decision(for: Self.hostKey, host: "pi.local", port: 22) == .trusted)

        // Cancel: not trusted, the fingerprint in the failure.
        let other = sshEditor(tester: FakeSSHTester(hostKey: Self.otherHostKey))
        other.host = "nas.local"
        other.testConnection()
        #expect(await waitUntil { other.sheet != nil })
        other.rejectHostKey()
        #expect(await waitUntil { other.testState == .failed(.hostKeyUnknown(Self.otherHostKey.fingerprintSHA256)) })
        #expect(trust.decision(for: Self.otherHostKey, host: "nas.local", port: 22) == .unknown)
    }

    @Test func changedHostKeyFailsWithoutAsking() async {
        trust.trust(Self.otherHostKey, host: "pi.local", port: 22)
        let model = sshEditor(tester: FakeSSHTester(hostKey: Self.hostKey))
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.hostKeyChanged) })
        #expect(model.sheet == nil)
        #expect(trust.decision(for: Self.hostKey, host: "pi.local", port: 22) != .trusted)
    }

    /// A conflict in `~/.ssh/known_hosts` (checked first) is not RemoteDeck's to remove: its own
    /// failure, which points at that file.
    @Test func knownHostsConflictPointsAtKnownHosts() async {
        folder.granted = true
        folder.files = ["known_hosts": "pi.local " + SSHTestKeys.ed25519EncryptedPublic]
        let model = sshEditor(tester: FakeSSHTester(hostKey: Self.hostKey))
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.hostKeyChangedInKnownHosts) })
        #expect(model.sheet == nil)
    }

    @Test func cancellingTheTestDismissesTheHostKeySheet() async {
        let model = sshEditor(tester: FakeSSHTester(hostKey: Self.hostKey))
        model.testConnection()
        #expect(await waitUntil { model.sheet != nil })
        model.cancelTest()
        #expect(model.sheet == nil && model.testState == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.testState == .idle)
        #expect(trust.decision(for: Self.hostKey, host: "pi.local", port: 22) == .unknown)
    }

    @Test func testTestConnectionTimeout5s() async throws {
        let tester = FakeSSHTester(result: .failure(.timedOut))
        let model = sshEditor(tester: tester)
        #expect(model.testBudget == .seconds(5))
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.timedOut) })
        #expect(try #require(await tester.calls.first).timeout == .seconds(5))
    }

    /// The 5 s budget covers the whole Test (SSHKit's own timeout is per phase): a server that never
    /// answers gets "no answer" when the budget runs out.
    @Test func aServerThatNeverAnswersTimesOutOnTheWholeTestBudget() async {
        let model = sshEditor(tester: FakeSSHTester(hangs: true))
        model.testBudget = .milliseconds(200)
        let start = ContinuousClock.now
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.timedOut) })
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// The Host Key Sheet's time does not count.
    @Test func theBudgetPausesWhileTheHostKeySheetIsUp() async throws {
        let model = sshEditor(tester: FakeSSHTester(hostKey: Self.hostKey))
        model.testBudget = .milliseconds(200)
        model.testConnection()
        #expect(await waitUntil { model.sheet != nil })
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.testState == .testing)
        model.trustHostKey()
        #expect(await waitUntil { model.testState == .succeeded })
    }

    /// One source of truth: an empty password fails the Test as it fails a session's connect.
    @Test func emptyPasswordFailsTheTestAsTheSessionDoes() async throws {
        let tester = FakeSSHTester()
        let model = sshEditor(tester: tester)
        model.password = ""
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.sshCredential(.passwordMissing)) })
        #expect(await tester.calls.isEmpty)
        // The session's resolver, on the saved machine without a password, says the same.
        let machine = try savedSSHMachine()
        let resolution = ssh.resolver(passwords: passwords).resolve(machine: SessionTarget(machine), passphrase: nil,
                                                                    allowsInteraction: true)
        guard case .failed(.passwordMissing) = resolution else {
            Issue.record("expected passwordMissing, got \(resolution)")
            return
        }
    }

    @Test func saveDuringATestTakesTheSheetSlot() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519Encrypted))
        model.testConnection()
        #expect(await waitUntil { model.sheet == .testPassphrase(rejected: false) })
        #expect(model.save() == nil)
        #expect(model.sheet == .savePassphrase(rejected: false))
        #expect(model.testState == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.sheet == .savePassphrase(rejected: false))
        // The Test cannot start over the save's sheet.
        model.testConnection()
        #expect(model.sheet == .savePassphrase(rejected: false) && model.testState == .idle)
    }

    @Test func configImportDuringATestCancelsIt() async throws {
        folder.granted = true
        folder.files = ["config": Self.raspcorseConfig]
        let tester = FakeSSHTester(hangs: true)
        let model = sshEditor(tester: tester)
        model.testConnection()
        #expect(await waitUntil { model.testState == .testing })
        await model.openConfigImport()
        #expect(model.sheet == .configImport && model.testState == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sheet == .configImport && model.testState == .idle)
    }

    @Test func cancellingTheSavePassphraseDuringItsCheckSavesNothing() async throws {
        let model = sshEditor(auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519Encrypted))
        #expect(model.save() == nil)
        let submit = Task { @MainActor in
            await model.submitSavePassphrase(SSHTestKeys.passphrase, remember: true) == nil
        }
        await Task.yield()
        model.cancelSavePassphrase()
        #expect(await submit.value)
        #expect(model.sheet == nil)
        #expect(try machines().isEmpty && secrets.items.isEmpty)
    }

    @Test func cancellingTheTestWhileItsPassphraseSheetIsUp() async throws {
        folder.granted = true
        folder.files = ["id_ed25519": SSHTestKeys.ed25519Encrypted]
        let tester = FakeSSHTester()
        let model = sshEditor(tester: tester, auth: .keyInSSHFolder)
        model.testConnection()
        #expect(await waitUntil { model.sheet == .testPassphrase(rejected: false) })
        model.cancelTest()
        #expect(model.sheet == nil && model.testState == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.testState == .idle)
        #expect(await tester.calls.isEmpty)
    }

    @Test(arguments: [(SSHError.unreachable, TestConnectionFailure.unreachable),
                      (.authFailed, .authFailed(reason: nil)),
                      (.connectionClosed, .connectionClosed),
                      (.channelFailed("no"), .ssh(.channelFailed("no")))])
    func sshTestFailuresAreShown(_ error: SSHError, _ expected: TestConnectionFailure) async {
        let model = sshEditor(tester: FakeSSHTester(result: .failure(error)))
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(expected) })
    }

    @Test func testWithAKeyInTheFolderReadsItAndAsksAnUnrememberedPassphrase() async throws {
        folder.granted = true
        folder.files = ["id_ed25519": SSHTestKeys.ed25519Encrypted]
        let tester = FakeSSHTester()
        let model = sshEditor(tester: tester, auth: .keyInSSHFolder)
        model.testConnection()
        #expect(await waitUntil { model.sheet == .testPassphrase(rejected: false) })
        model.provideTestPassphrase("wrong")
        #expect(await waitUntil { model.sheet == .testPassphrase(rejected: true) })
        model.provideTestPassphrase(SSHTestKeys.passphrase)
        #expect(await waitUntil { model.testState == .succeeded })
        #expect(try #require(await tester.calls.first).credentials == .key(user: "vincent", algorithm: "ssh-ed25519"))
        // The test never remembers a passphrase.
        #expect(secrets.items.isEmpty)
    }

    @Test func testWithAKeyInTheFolderNeedsTheGrant() async {
        let model = sshEditor(auth: .keyInSSHFolder)
        model.sshKeyFileName = "id_ed25519"
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.sshFolderAccessNeeded) })
    }

    @Test func testWithAnImportedKeyNotSavedYet() async throws {
        let tester = FakeSSHTester()
        let model = sshEditor(tester: tester, auth: .importedKey)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        model.testConnection()
        #expect(await waitUntil { model.testState == .succeeded })
        #expect(try #require(await tester.calls.first).credentials == .key(user: "vincent", algorithm: "ssh-ed25519"))
        #expect(secrets.items.isEmpty)
    }

    // MARK: Trusted keys

    @Test func testEditedHostOrPortForgetsOldTrust() throws {
        let machine = try savedSSHMachine()
        trust.trust(Self.hostKey, host: "pi.local", port: 22)
        trust.trust(Self.otherHostKey, host: "nas.local", port: 22)

        // A case-only edit is the same `host:port`: kept.
        let same = editor(machine)
        same.host = "PI.local"
        _ = try #require(same.save())
        #expect(trust.hasTrustedKeys(host: "pi.local", port: 22))

        let moved = editor(machine)
        moved.host = "pi.tailnet.ts.net"
        _ = try #require(moved.save())
        #expect(!trust.hasTrustedKeys(host: "pi.local", port: 22))
        #expect(trust.hasTrustedKeys(host: "nas.local", port: 22))

        trust.trust(Self.hostKey, host: "pi.tailnet.ts.net", port: 22)
        let port = editor(machine)
        port.portText = "2222"
        _ = try #require(port.save())
        #expect(!trust.hasTrustedKeys(host: "pi.tailnet.ts.net", port: 22))
    }

    @Test func editKeepsTrustStillUsedByAnotherMachine() throws {
        let machine = try savedSSHMachine()
        // A synced duplicate not merged yet has the same address.
        context.insert(Machine(name: "Pi copy", kind: .ssh, host: "pi.local", port: 22, username: "vincent"))
        try context.save()
        trust.trust(Self.hostKey, host: "pi.local", port: 22)
        let model = editor(machine)
        model.host = "pi.tailnet.ts.net"
        _ = try #require(model.save())
        #expect(trust.hasTrustedKeys(host: "pi.local", port: 22))
    }

    @Test func failedSaveKeepsTheOldTrust() throws {
        let machine = try savedSSHMachine()
        trust.trust(Self.hostKey, host: "pi.local", port: 22)
        let model = editor(machine)
        model.host = "elsewhere.local"
        struct Refused: Error {}
        model.persist = { _ in throw Refused() }
        #expect(model.save() == nil)
        #expect(trust.hasTrustedKeys(host: "pi.local", port: 22))
    }

    @Test func removeTrustedKeysForgetsTheMachinesHostPort() throws {
        let machine = try savedSSHMachine()
        let fresh = editor(machine)
        #expect(!fresh.hasTrustedHostKey)

        trust.trust(Self.hostKey, host: "pi.local", port: 22)
        let model = editor(machine)
        #expect(model.hasTrustedHostKey)
        model.removeTrustedKeys()
        #expect(!model.hasTrustedHostKey)
        #expect(!trust.hasTrustedKeys(host: "pi.local", port: 22))
        // A changed key no longer blocks: the next decision asks.
        #expect(trust.decision(for: Self.otherHostKey, host: "pi.local", port: 22) == .unknown)
    }

    @Test func switchingFromPasswordToAKeyRemovesThePassword() async throws {
        let machine = try savedSSHMachine()
        passwords.items[machine.id] = "s3cret"
        let model = editor(machine)
        model.sshAuth = .importedKey
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        _ = try #require(model.save())
        #expect(passwords.items[machine.id] == nil)
    }

    @Test func switchingFromSSHToAMacRemovesTheSSHSecrets() throws {
        let machine = try savedSSHMachine(auth: .importedKey)
        secrets.items[.sshPrivateKey(machine.id)] = "key"
        secrets.items[.sshKeyPassphrase(machine.id)] = "pass"
        let model = editor(machine)
        model.kind = .macARD
        model.password = "s3cret"
        _ = try #require(model.save())
        #expect(secrets.items.isEmpty)
        #expect(passwords.items[machine.id] == "s3cret")
    }

    /// A failed read of the previous key (not "none") aborts before the new key is written, so a
    /// rollback can never delete a key it could not read back.
    @Test func unreadablePreviousKeyAbortsTheSave() async throws {
        let machine = try savedSSHMachine(auth: .importedKey)
        secrets.items[.sshPrivateKey(machine.id)] = "old key"
        secrets.readError = KeychainError(status: -25308)
        let model = editor(machine)
        try await model.importKey(from: keyFile(SSHTestKeys.ed25519))
        #expect(model.save() == nil)
        #expect(model.keyFailure == KeychainError(status: -25308))
        #expect(secrets.items[.sshPrivateKey(machine.id)] == "old key")
    }

    @Test func switchingAwayFromAnImportedKeyRemovesItsSecrets() throws {
        let machine = try savedSSHMachine(auth: .importedKey)
        secrets.items[.sshPrivateKey(machine.id)] = "key"
        secrets.items[.sshKeyPassphrase(machine.id)] = "pass"
        let model = editor(machine)
        model.sshAuth = .password
        model.password = "s3cret"
        _ = try #require(model.save())
        #expect(secrets.items[.sshPrivateKey(machine.id)] == nil)
        #expect(secrets.items[.sshKeyPassphrase(machine.id)] == nil)
    }
}
