import Foundation
import RemoteDeckCore
import RFBKit
import SSHKit
import SwiftData

/// What the Machine Editor shows of a key imported but not saved yet: never its text.
struct ImportedKeySummary: Equatable, Sendable {
    let algorithm: String
    /// SHA256 fingerprint of its public half (as `ssh-keygen -lf`).
    let fingerprint: String
    /// Its passphrase is asked on Save.
    let isEncrypted: Bool
}

/// Why "Import Key…" refused a file, or why the imported-key method cannot be saved.
enum KeyImportProblem: Error, Equatable, Sendable {
    /// The imported-key method and no key imported yet.
    case noKey
    /// The file could not be read.
    case unreadable
    /// Not an OpenSSH private key (or a damaged one, or larger than any key).
    case notAKey
    /// A key type or format SSHKit does not use, named (`ssh-dss`, `RSA PRIVATE KEY`).
    case unsupported(String)
}

/// The SSH Config Import Sheet's content (AppFlow › Import from ~/.ssh/config).
enum ConfigImportState: Equatable {
    /// The importable `Host` blocks, in file order.
    case hosts([SSHConfigHost])
    /// The file has no `Host` block with a single plain alias.
    case empty
    /// No `~/.ssh/config`.
    case noFile
    case unreadable

    var hosts: [SSHConfigHost]? {
        if case .hosts(let hosts) = self { return hosts }
        return nil
    }
}

/// The sheet over the Machine Editor: one at a time (`sheet(item:)`).
enum EditorSheet: Equatable, Identifiable {
    /// Test connection reached a server whose key RemoteDeck does not know (the session's sheet).
    case hostKey(TerminalSessionModel.HostKeyPrompt)
    /// Test connection needs the key's passphrase (never remembered by a test).
    case testPassphrase(rejected: Bool)
    /// Save of a newly imported encrypted key: its passphrase, with "Remember in Keychain".
    case savePassphrase(rejected: Bool)
    case configImport

    var id: String {
        switch self {
        case .hostKey(let prompt): "hostKey.\(prompt.host):\(prompt.port).\(prompt.key.fingerprintSHA256)"
        case .testPassphrase(let rejected): "testPassphrase.\(rejected)"
        case .savePassphrase(let rejected): "savePassphrase.\(rejected)"
        case .configImport: "configImport"
        }
    }
}

/// The Keychain items an imported key's Save replaced, put back if SwiftData then refuses the save.
struct SSHKeyRollback {
    let machineID: UUID
    let previousKey: String?
    let previousPassphrase: String?

    @MainActor
    func undo(_ secrets: any SSHSecretStore) {
        restore(previousKey, .sshPrivateKey(machineID), secrets)
        restore(previousPassphrase, .sshKeyPassphrase(machineID), secrets)
    }

    @MainActor
    private func restore(_ value: String?, _ account: KeychainAccount, _ secrets: any SSHSecretStore) {
        if let value { try? secrets.setSecret(value, for: account) } else { try? secrets.deleteSecret(account) }
    }
}

/// The SSH part of the Machine Editor (AppFlow › Machine Editor › SSH machines).
extension MachineEditorModel {
    /// "Import Key…" reads at most this much: a private key is a few KiB.
    nonisolated static let maxKeyFileSize = 64 * 1024
    /// The keys picked by default in `~/.ssh`, in OpenSSH's order of preference.
    nonisolated static let usualKeyNames = ["id_ed25519", "id_ecdsa", "id_rsa"]

    // MARK: Fields

    /// The forwards as saved: label and remote host trimmed, no empty label, `localhost` for an
    /// empty remote host.
    var cleanedForwards: [PortForward] {
        portForwards.map { forward in
            var forward = forward
            let label = forward.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            forward.label = label.isEmpty ? nil : label
            let remote = forward.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            forward.remoteHost = remote.isEmpty ? "localhost" : remote
            return forward
        }
    }

    /// The `~/.ssh` grant and the key choices, when the SSH fields appear or the folder changes.
    func sshFieldsShown() {
        sshFolderGranted = ssh.folder.isGranted
        guard kind == .ssh, sshAuth == .keyInSSHFolder else { return }
        let current = sshKeyFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Names only: no key is read to be listed.
        let files = sshFolderGranted ? ((try? ssh.folder.listFiles()) ?? []).filter(SSHFolderPath.isKeyCandidate) : []
        var choices = Set(files)
        if !current.isEmpty { choices.insert(current) }
        sshKeyChoices = choices.sorted()
        if current.isEmpty, let usual = Self.usualKeyNames.first(where: files.contains) ?? files.first {
            sshKeyFileName = usual
        }
    }

    /// "Grant access to ~/.ssh…": the open panel; a folder that is not `.ssh` says why.
    func grantSSHFolder() async {
        _ = await ssh.folder.requestAccess()
        sshFolderProblem = ssh.folder.lastRequestProblem
        sshFieldsShown()
    }

    func addForward() {
        let used = Set(portForwards.map(\.localPort))
        let local = (8080...65535).first { !used.contains($0) } ?? 8080
        portForwards.append(PortForward(localPort: local, remotePort: 80))
    }

    func removeForward(_ id: PortForward.ID) {
        portForwards.removeAll { $0.id == id }
        clearForwardIssue(for: id)
    }

    // MARK: Validation and Save

    /// The imported-key method needs a key: imported now, or already saved for this machine.
    func validateSSHKey() -> Bool {
        guard kind == .ssh, sshAuth == .importedKey else {
            if keyProblem == .noKey { keyProblem = nil }
            return true
        }
        guard pendingKeyText != nil || hasStoredImportedKey else {
            keyProblem = .noKey
            return false
        }
        if keyProblem == .noKey { keyProblem = nil }
        return true
    }

    /// A newly imported encrypted key whose passphrase was not given yet.
    var needsSavePassphrase: Bool {
        kind == .ssh && sshAuth == .importedKey && pendingKeyText != nil && importedKey?.isEncrypted == true
            && pendingKeyPassphrase == nil
    }

    /// Before SwiftData (the Keychain first, as a password): the imported key, and its passphrase if
    /// remembered (a stale remembered one goes, it belonged to the previous key). Returns what to put
    /// back if the store then refuses; nil when no key was imported.
    func writeImportedKey(for id: UUID) throws(KeychainError) -> SSHKeyRollback? {
        guard kind == .ssh, sshAuth == .importedKey, let text = pendingKeyText else { return nil }
        let secrets = ssh.secrets
        let rollback = SSHKeyRollback(
            machineID: id,
            previousKey: editing == nil ? nil : (try? secrets.secret(.sshPrivateKey(id), allowsInteraction: true)) ?? nil,
            previousPassphrase: editing == nil ? nil
                : (try? secrets.secret(.sshKeyPassphrase(id), allowsInteraction: true)) ?? nil)
        try secrets.setSecret(text, for: .sshPrivateKey(id))
        if let given = pendingKeyPassphrase, given.remember {
            do throws(KeychainError) {
                try secrets.setSecret(given.passphrase, for: .sshKeyPassphrase(id))
            } catch {
                rollback.undo(secrets)
                throw error
            }
        } else {
            try? secrets.deleteSecret(.sshKeyPassphrase(id))
        }
        return rollback
    }

    /// After a successful save: the key text leaves memory; secrets of a method no longer used go
    /// (best effort: an item left behind is never read); a changed `host:port` forgets the old
    /// address's trusted keys unless another machine still has it.
    func sshSaved(_ machine: Machine, previousAddress: (host: String, port: Int)?,
                  previousSSH: (auth: SSHAuthMethod?, keyFile: String?)?) {
        pendingKeyText = nil
        pendingKeyPassphrase = nil
        importedKey = nil
        let secrets = ssh.secrets
        let auth: SSHAuthMethod? = machine.kindValue == .ssh ? machine.sshAuth : nil
        if let previousSSH {
            if previousSSH.auth == .importedKey, auth != .importedKey {
                try? secrets.deleteSecret(.sshPrivateKey(machine.id))
                try? secrets.deleteSecret(.sshKeyPassphrase(machine.id))
            }
            if previousSSH.auth == .keyInSSHFolder, auth != .keyInSSHFolder || previousSSH.keyFile != machine.sshKeyFileName {
                try? secrets.deleteSecret(.sshLocalKeyPassphrase(machine.id))
            }
        }
        if let previousAddress,
           HostKeyTrust.entryKey(host: previousAddress.host, port: previousAddress.port)
            != HostKeyTrust.entryKey(host: machine.host, port: machine.port) {
            let others = ((try? context.fetch(FetchDescriptor<Machine>())) ?? []).filter { $0.id != machine.id }
            ssh.trustedHostKeys.forget(host: previousAddress.host, port: previousAddress.port, unlessUsedBy: others)
        }
        refreshTrustState()
    }

    /// Save's passphrase sheet › Save: checked against the key (bcrypt, off the main actor), then the
    /// save goes on. A wrong one brings the sheet back.
    func submitSavePassphrase(_ passphrase: String, remember: Bool) async -> Machine? {
        guard let text = pendingKeyText, !passphrase.isEmpty else { return nil }
        switch await Self.parseOffMain(text, passphrase: passphrase) {
        case .success:
            guard pendingKeyText == text else { return nil }   // another key was imported meanwhile
            pendingKeyPassphrase = (passphrase, remember)
            sheet = nil
            return save()
        case .failure(.wrongPassphrase), .failure(.passphraseRequired):
            sheet = .savePassphrase(rejected: true)
            return nil
        case .failure(let error):
            sheet = nil
            keyProblem = Self.importProblem(error)
            return nil
        }
    }

    func cancelSavePassphrase() {
        if case .savePassphrase = sheet { sheet = nil }
    }

    // MARK: Imported key

    /// "Import Key…": the open panel, then `importKey(from:)`.
    func chooseKeyToImport() async {
        guard let url = await keyPicker.chooseKeyFile() else { return }
        do {
            try await importKey(from: url)
        } catch {
            // `keyProblem` says why under the method picker.
        }
    }

    /// Reads and checks the file the user picked (off the main actor; an encrypted key is not
    /// decrypted here, so no bcrypt), then keeps its text in memory until Save.
    func importKey(from url: URL) async throws(KeyImportProblem) {
        let result = await Task.detached(priority: .userInitiated) { Self.readKey(at: url) }.value
        switch result {
        case .failure(let problem):
            keyProblem = problem
            throw problem
        case .success(let (text, info)):
            pendingKeyText = text
            pendingKeyPassphrase = nil
            importedKey = ImportedKeySummary(algorithm: info.algorithm, fingerprint: info.publicKey.fingerprintSHA256,
                                             isEncrypted: info.isEncrypted)
            keyProblem = nil
            resetTest()
        }
    }

    nonisolated static func readKey(at url: URL) -> Result<(String, SSHPrivateKey.FileInfo), KeyImportProblem> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxKeyFileSize else { return .failure(.notAKey) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notAKey) }
        let info: SSHPrivateKey.FileInfo
        do throws(SSHKeyError) {
            info = try SSHPrivateKey.inspect(openSSH: text)
            // An unencrypted key is read whole now (cheap): a damaged one is refused at import.
            if !info.isEncrypted { _ = try SSHPrivateKey.parse(openSSH: text, passphrase: nil) }
        } catch {
            return .failure(importProblem(error))
        }
        return .success((text, info))
    }

    nonisolated static func importProblem(_ error: SSHKeyError) -> KeyImportProblem {
        switch error {
        case .unsupportedKeyType(let type): .unsupported(type)
        case .malformed, .passphraseRequired, .wrongPassphrase: .notAKey
        }
    }

    /// `SSHPrivateKey.parse` in a detached task: bcrypt_pbkdf of an encrypted key (~165 ms in Debug)
    /// never runs on the main actor.
    nonisolated static func parseOffMain(_ text: String, passphrase: String?) async -> Result<SSHPrivateKey, SSHKeyError> {
        await Task.detached(priority: .userInitiated) {
            Result { () throws(SSHKeyError) in try SSHPrivateKey.parse(openSSH: text, passphrase: passphrase) }
        }.value
    }

    // MARK: Import from ~/.ssh/config

    /// "Import from ~/.ssh/config…": grants the folder first if needed, then lists the importable
    /// hosts in the SSH Config Import Sheet.
    func openConfigImport() async {
        if !ssh.folder.isGranted {
            await grantSSHFolder()
            guard sshFolderGranted else { return }
        }
        do {
            let hosts = SSHConfigFile.parse(try ssh.folder.readFile("config"))
            configImport = hosts.isEmpty ? .empty : .hosts(hosts)
        } catch SSHFolderError.fileMissing {
            configImport = .noFile
        } catch SSHFolderError.notGranted {
            sshFolderGranted = false
            return
        } catch {
            configImport = .unreadable
        }
        sheet = .configImport
    }

    func chooseConfigHost(_ host: SSHConfigHost) {
        applyConfigHost(host)
        dismissConfigImport()
    }

    func dismissConfigImport() {
        if sheet == .configImport { sheet = nil }
        configImport = nil
    }

    /// Pre-fills the editor from a `Host` block: name = alias, host = `HostName` (else the alias),
    /// user, port (22 by default), and the key in `~/.ssh` when `IdentityFile` names one in it
    /// (else the password method).
    func applyConfigHost(_ config: SSHConfigHost) {
        kind = .ssh
        name = String(config.alias.prefix(MachineValidator.maxNameLength))
        host = config.hostName ?? config.alias
        if let user = config.user { username = user }
        portText = String(config.port ?? MachineKind.ssh.defaultPort)
        if let file = config.identityFile, SSHFolderPath.isValid(file) {
            sshKeyFileName = file
            sshAuth = .keyInSSHFolder
        } else {
            sshAuth = .password
        }
        sshFieldsShown()
    }

    // MARK: Trusted keys

    func refreshTrustState() {
        hasTrustedHostKey = editing.map { ssh.trustedHostKeys.hasTrustedKeys(host: $0.host, port: $0.port) } ?? false
    }

    /// "Remove from RemoteDeck's trusted keys…" (after its confirmation): the saved `host:port`'s
    /// entry goes, so the next connection asks again; the only way out of a changed-key block.
    func removeTrustedKeys() {
        guard let editing else { return }
        ssh.trustedHostKeys.forget(host: editing.host, port: editing.port)
        refreshTrustState()
    }

    // MARK: Test connection

    private enum TestCredentials {
        case ready(SSHCredentials)
        case failed(TestConnectionFailure)
        /// The test was cancelled meanwhile.
        case cancelled
    }

    /// One SSH open/close with the editor's current (unsaved) fields. The 5 s timeout goes to
    /// `SSHConnection.open`, which leaves the host key validator out of it: the Host Key Sheet
    /// pauses it.
    func runSSHTest(port: UInt16, generation: Int) async -> TestConnectionState {
        let host = trimmedHost
        let credentials: SSHCredentials
        switch await testCredentials(user: effectiveUsername ?? "", generation: generation) {
        case .ready(let ready): credentials = ready
        case .failed(let failure): return .failed(failure)
        case .cancelled: return .idle
        }
        guard generation == testGeneration else { return .idle }
        let tester = sshTester
        let portNumber = Int(port)
        do throws(SSHError) {
            try await tester.test(host: host, port: port, credentials: credentials, timeout: Self.testTimeout) {
                [weak self] key in
                await self?.checkTestHostKey(key, host: host, port: portNumber, generation: generation) ?? false
            }
            return .succeeded
        } catch {
            if case .hostKeyRejected = error, let refusal = hostKeyRefusal, refusal.generation == generation {
                return .failed(refusal.failure)
            }
            return .failed(TestConnectionFailure(error))
        }
    }

    /// The test's credentials from the fields as typed, by the session's rules (TRD › Secrets):
    /// the password field, the key file read now from `~/.ssh`, or the imported key (not saved yet,
    /// else the saved one). An encrypted key tries the remembered passphrase of the saved machine,
    /// then asks; a passphrase typed for a test is never remembered.
    private func testCredentials(user: String, generation: Int) async -> TestCredentials {
        let text: String
        let remembered: KeychainAccount?
        switch sshAuth {
        case .password:
            return .ready(.password(user: user, password: password))
        case .keyInSSHFolder:
            guard ssh.folder.isGranted else { return .failed(.sshFolderAccessNeeded) }
            let name = sshKeyFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                text = try ssh.folder.readFile(name)
            } catch SSHFolderError.notGranted {
                return .failed(.sshFolderAccessNeeded)
            } catch SSHFolderError.fileMissing, SSHFolderError.invalidPath {
                return .failed(.sshCredential(.keyFileMissing(name)))
            } catch {
                return .failed(.sshCredential(.keyUnreadable))
            }
            let sameFile = editing.map { $0.sshAuth == .keyInSSHFolder && $0.sshKeyFileName == name } ?? false
            remembered = sameFile ? editing.map { KeychainAccount.sshLocalKeyPassphrase($0.id) } : nil
        case .importedKey:
            if let pendingKeyText {
                text = pendingKeyText
                remembered = nil
            } else if let editing, editing.sshAuth == .importedKey,
                      let stored = (try? ssh.secrets.secret(.sshPrivateKey(editing.id), allowsInteraction: true)) ?? nil {
                text = stored
                remembered = .sshKeyPassphrase(editing.id)
            } else {
                return .failed(.sshCredential(.keyUnreadable))
            }
        }
        return await keyCredentials(text, user: user, remembered: remembered, generation: generation)
    }

    private func keyCredentials(_ text: String, user: String, remembered: KeychainAccount?,
                                generation: Int) async -> TestCredentials {
        // Without a passphrase first: an encrypted key refuses before bcrypt.
        var result = await Self.parseOffMain(text, passphrase: nil)
        var rejected = false
        if case .failure(.passphraseRequired) = result, let remembered,
           let stored = (try? ssh.secrets.secret(remembered, allowsInteraction: true)) ?? nil, !stored.isEmpty {
            result = await Self.parseOffMain(text, passphrase: stored)
            if case .failure(.wrongPassphrase) = result { rejected = true }
        }
        while true {
            guard generation == testGeneration else { return .cancelled }
            switch result {
            case .success(let key):
                return .ready(.key(user: user, key: key))
            case .failure(.passphraseRequired), .failure(.wrongPassphrase):
                guard let typed = await askTestPassphrase(rejected: rejected), !typed.isEmpty else {
                    return generation == testGeneration ? .failed(.passphraseRequired) : .cancelled
                }
                result = await Self.parseOffMain(text, passphrase: typed)
                rejected = true   // shown only if this one fails too
            case .failure(.unsupportedKeyType(let type)):
                return .failed(.sshCredential(.unsupportedKey(type)))
            case .failure(.malformed):
                return .failed(.sshCredential(.keyUnreadable))
            }
        }
    }

    /// The validator of test `generation`: trusted → go on; changed → refuse, no trust path; unknown
    /// → the Host Key Sheet (Trust remembers the key at once, as a session does).
    private func checkTestHostKey(_ key: SSHHostKey, host: String, port: Int, generation: Int) async -> Bool {
        guard generation == testGeneration else { return false }
        switch ssh.trustedHostKeys.decision(for: key, host: host, port: port) {
        case .trusted:
            return true
        case .changed(let previous):
            hostKeyRefusal = (generation, previous == HostKeyDecision.knownHostsConflict
                ? .hostKeyChangedInKnownHosts : .hostKeyChanged)
            return false
        case .unknown:
            let accepted = await askHostKey(TerminalSessionModel.HostKeyPrompt(host: host, port: port, key: key))
            guard generation == testGeneration else { return false }
            if !accepted { hostKeyRefusal = (generation, .hostKeyUnknown(key.fingerprintSHA256)) }
            return accepted
        }
    }

    /// Parks the validator until Trust, Cancel, or the end of the test (its task cancelled: the
    /// connection died, or the test was cancelled).
    private func askHostKey(_ prompt: TerminalSessionModel.HostKeyPrompt) async -> Bool {
        nextPromptID += 1
        let id = nextPromptID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                hostKeyWaiter = (id, continuation)
                sheet = .hostKey(prompt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismissHostKeyPrompt(id: id) }
        }
    }

    /// Host Key Sheet › Trust: remembered for this `host:port` on this Mac, then the test goes on.
    func trustHostKey() {
        guard case .hostKey(let prompt) = sheet, let waiter = hostKeyWaiter else { return }
        ssh.trustedHostKeys.trust(prompt.key, host: prompt.host, port: prompt.port)
        hostKeyWaiter = nil
        sheet = nil
        refreshTrustState()
        waiter.continuation.resume(returning: true)
    }

    /// Host Key Sheet › Cancel: nothing remembered; the test fails "Host key not trusted".
    func rejectHostKey() {
        dismissHostKeyPrompt()
    }

    private func dismissHostKeyPrompt(id: Int? = nil) {
        guard let waiter = hostKeyWaiter, id == nil || waiter.id == id else { return }
        hostKeyWaiter = nil
        if case .hostKey = sheet { sheet = nil }
        waiter.continuation.resume(returning: false)
    }

    private func askTestPassphrase(rejected: Bool) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                passphraseWaiter = continuation
                sheet = .testPassphrase(rejected: rejected)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelTestPassphrase() }
        }
    }

    /// Test passphrase sheet › Test: used for this test only.
    func provideTestPassphrase(_ passphrase: String) {
        guard let waiter = passphraseWaiter else { return }
        passphraseWaiter = nil
        if case .testPassphrase = sheet { sheet = nil }
        waiter.resume(returning: passphrase)
    }

    func cancelTestPassphrase() {
        guard let waiter = passphraseWaiter else { return }
        passphraseWaiter = nil
        if case .testPassphrase = sheet { sheet = nil }
        waiter.resume(returning: nil)
    }

    /// A test ends or is cancelled: its sheets go, their waiters answer "no".
    func dismissTestPrompts() {
        dismissHostKeyPrompt()
        cancelTestPassphrase()
    }
}

extension MachineEditorModel {
    /// The sheet went away without one of its buttons (it is never dismissed that way, as every
    /// sheet disables interactive dismissal; kept so a binding set to nil always answers its waiter).
    func dismissSheet() {
        switch sheet {
        case .hostKey: rejectHostKey()
        case .testPassphrase: cancelTestPassphrase()
        case .savePassphrase: cancelSavePassphrase()
        case .configImport: dismissConfigImport()
        case nil: break
        }
    }
}

extension MachineEditorModel {
    /// The saved machine's address (the trusted keys' `host:port`); nil for a new machine.
    var savedHost: String? { editing?.host }
    var savedPort: Int? { editing?.port }
    /// The saved machine already has an imported key in the Keychain (the editor never reads it).
    var hasStoredImportedKey: Bool { editing.map { $0.kindValue == .ssh && $0.sshAuth == .importedKey } ?? false }
}

extension KeyImportProblem {
    func message(_ t: (String) -> String) -> String {
        switch self {
        case .noKey: t("key_problem_no_key")
        case .unreadable: t("key_problem_unreadable")
        case .notAKey: t("key_problem_not_a_key")
        case .unsupported(let type):
            t("key_problem_unsupported").replacingOccurrences(of: "%@", with: DisplayText.serverString(type))
        }
    }
}
