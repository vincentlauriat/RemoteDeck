import Foundation
import RemoteDeckCore
import SSHKit

/// What an SSH connect attempt can authenticate with (TRD › Security › Secrets).
enum CredentialResolution: Sendable {
    case ready(SSHCredentials)
    /// The key is encrypted and no passphrase opened it: ask (Passphrase Sheet). Never returned when
    /// `allowsInteraction` is false (an automatic attempt gets `.failed(.passphraseUnavailable)`).
    case needsPassphrase
    /// The remembered passphrase no longer opens the key (it was re-encrypted): ask, saying the
    /// passphrase was wrong; the stale item can go once a new one works. Interactive only, as
    /// `needsPassphrase`; an automatic attempt gets `.failed(.passphraseUnavailable)`.
    case rememberedPassphraseRejected
    /// A key in `~/.ssh` and no folder grant on this Mac: ask for the folder at Connect.
    case needsFolderAccess
    case failed(SSHCredentialFailure)
}

enum SSHCredentialFailure: Equatable, Sendable {
    /// The key file (path relative to `~/.ssh`) is not in the granted folder; also an empty or
    /// invalid file name.
    case keyFileMissing(String)
    /// The key cannot be read: damaged or not a key, an imported key not (yet) on this Mac or whose
    /// Keychain read failed.
    case keyUnreadable
    /// A key type SSHKit does not use (`ssh-dss`, `sk-…`), named.
    case unsupportedKey(String)
    /// A password machine without a password on this Mac, or whose Keychain read failed (an
    /// automatic attempt never shows the Keychain dialog).
    case passwordMissing
    /// An automatic attempt (`allowsInteraction` false) on an encrypted key with no remembered
    /// passphrase, whose remembered passphrase cannot be read without a dialog, or whose remembered
    /// passphrase no longer opens it: nobody can be asked, so the caller ends in "Connection lost"
    /// (design › Passphrases).
    case passphraseUnavailable
}

/// Turns a machine's SSH authentication method into `SSHCredentials`, reading the Keychain and the
/// `~/.ssh` folder. Never logs key material or passphrases, and keeps neither: the parsed key goes
/// out in the result only.
///
/// Cost: parsing an encrypted key runs bcrypt_pbkdf (OpenSSH's default 16 rounds), once per connect
/// attempt (twice when a remembered passphrase is wrong and another is given): sessions use
/// `resolveOffMain`, which runs it off the main actor. An unencrypted key, or an encrypted one
/// without any passphrase, never reaches bcrypt.
@MainActor
struct SSHCredentialResolver {
    let passwords: any MachinePasswordStore
    let secrets: any SSHSecretStore
    let folder: any SSHFolderAccessing

    /// `passphrase`: typed in the Passphrase Sheet for this attempt (nil or empty: none; then the
    /// remembered one, if any, is tried). `allowsInteraction` false for automatic attempts: no
    /// Keychain dialog, and a wrong passphrase is `passphraseUnavailable` instead of asking.
    func resolve(machine: SessionTarget, passphrase: String?, allowsInteraction: Bool) -> CredentialResolution {
        switch prepare(machine: machine, passphrase: passphrase, allowsInteraction: allowsInteraction) {
        case .done(let resolution): resolution
        case .decrypt(let step): step.run()
        }
    }

    /// `resolve`, with the one expensive step (bcrypt_pbkdf of an encrypted key, ~165 ms in Debug)
    /// run off the main actor. The Keychain and `~/.ssh` reads, and the cheap check that a key is
    /// encrypted, stay on the main actor: an unencrypted key still never touches the Keychain.
    func resolveOffMain(machine: SessionTarget, passphrase: String?, allowsInteraction: Bool) async
        -> CredentialResolution {
        switch prepare(machine: machine, passphrase: passphrase, allowsInteraction: allowsInteraction) {
        case .done(let resolution): resolution
        case .decrypt(let step): await Task.detached(priority: .userInitiated) { step.run() }.value
        }
    }

    /// An encrypted key and the passphrase to open it with: the bcrypt step, pure and Sendable.
    struct DecryptStep: Sendable {
        let text: String
        let user: String
        let passphrase: String
        let allowsInteraction: Bool
        /// The passphrase is the remembered one, not one typed for this attempt.
        let isRemembered: Bool

        nonisolated func run() -> CredentialResolution {
            switch SSHCredentialResolver.parse(text, passphrase: passphrase) {
            case .success(let key): .ready(.key(user: user, key: key))
            case .failure(.wrongPassphrase) where isRemembered && allowsInteraction: .rememberedPassphraseRejected
            case .failure(let error): SSHCredentialResolver.failure(error, allowsInteraction: allowsInteraction)
            }
        }
    }

    private enum Preparation {
        case done(CredentialResolution)
        case decrypt(DecryptStep)
    }

    private func prepare(machine: SessionTarget, passphrase: String?, allowsInteraction: Bool) -> Preparation {
        let user = machine.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch machine.sshAuth {
        case .password:
            guard let password = try? passwords.storedPassword(for: machine.machineID,
                                                               allowsInteraction: allowsInteraction)?.password,
                  !password.isEmpty
            else { return .done(.failed(.passwordMissing)) }
            return .done(.ready(.password(user: user, password: password)))

        case .keyInSSHFolder:
            guard folder.isGranted else { return .done(.needsFolderAccess) }
            let name = machine.sshKeyFileName ?? ""
            let text: String
            do {
                text = try folder.readFile(name)
            } catch SSHFolderError.notGranted {
                return .done(.needsFolderAccess)
            } catch SSHFolderError.fileMissing, SSHFolderError.invalidPath {
                return .done(.failed(.keyFileMissing(name)))
            } catch {
                return .done(.failed(.keyUnreadable))
            }
            return key(text, user: user, passphrase: passphrase,
                       remembered: .sshLocalKeyPassphrase(machine.machineID), allowsInteraction: allowsInteraction)

        case .importedKey:
            guard let text = try? secrets.secret(.sshPrivateKey(machine.machineID), allowsInteraction: allowsInteraction)
            else { return .done(.failed(.keyUnreadable)) }
            return key(text, user: user, passphrase: passphrase,
                       remembered: .sshKeyPassphrase(machine.machineID), allowsInteraction: allowsInteraction)
        }
    }

    /// The key without passphrase first (cheap: an encrypted key refuses before bcrypt), then with the
    /// given passphrase, else the remembered one (`remembered`, read only when needed).
    private func key(_ text: String, user: String, passphrase given: String?, remembered: KeychainAccount,
                     allowsInteraction: Bool) -> Preparation {
        var passphrase = given?.isEmpty == false ? given : nil
        let isRemembered = passphrase == nil
        if passphrase == nil {
            switch Self.parse(text, passphrase: nil) {
            case .success(let key): return .done(.ready(.key(user: user, key: key)))
            case .failure(.passphraseRequired): break
            case .failure(let error): return .done(Self.failure(error, allowsInteraction: allowsInteraction))
            }
            // A read that fails (no item, needs a dialog) is no remembered passphrase.
            passphrase = try? secrets.secret(remembered, allowsInteraction: allowsInteraction)
        }
        guard let passphrase, !passphrase.isEmpty else {
            return .done(allowsInteraction ? .needsPassphrase : .failed(.passphraseUnavailable))
        }
        return .decrypt(DecryptStep(text: text, user: user, passphrase: passphrase, allowsInteraction: allowsInteraction,
                                    isRemembered: isRemembered))
    }

    private nonisolated static func parse(_ text: String, passphrase: String?) -> Result<SSHPrivateKey, SSHKeyError> {
        Result { () throws(SSHKeyError) in try SSHPrivateKey.parse(openSSH: text, passphrase: passphrase) }
    }

    private nonisolated static func failure(_ error: SSHKeyError, allowsInteraction: Bool) -> CredentialResolution {
        switch error {
        case .passphraseRequired: allowsInteraction ? .needsPassphrase : .failed(.passphraseUnavailable)
        // Nobody can type another one during an automatic attempt: "Connection lost", then Reconnect asks.
        case .wrongPassphrase: allowsInteraction ? .needsPassphrase : .failed(.passphraseUnavailable)
        case .unsupportedKeyType(let type): .failed(.unsupportedKey(type))
        case .malformed: .failed(.keyUnreadable)
        }
    }
}

/// The app's SSH services, one set per launch, built like the password store and the public-address
/// consents: in memory under the hosted tests, in the demo modes and for an in-memory library.
@MainActor
struct SSHServices {
    let folder: any SSHFolderAccessing
    let trustedHostKeys: any TrustedHostKeys
    let secrets: any SSHSecretStore

    func resolver(passwords: any MachinePasswordStore) -> SSHCredentialResolver {
        SSHCredentialResolver(passwords: passwords, secrets: secrets, folder: folder)
    }

    static func inMemory() -> SSHServices {
        let folder = InMemorySSHFolderAccess()
        return SSHServices(folder: folder, trustedHostKeys: InMemoryTrustedHostKeys(folder: folder),
                           secrets: InMemorySSHSecretStore())
    }

    /// `usesUserState` false (hosted tests, demo modes): no panel, no `~/.ssh`, no write to the user's
    /// defaults. `isInMemory` (also true when the on-disk store failed): secrets follow the library,
    /// so no Keychain item outlives the machines it belongs to.
    static func app(usesUserState: Bool, isInMemory: Bool) -> SSHServices {
        let folder: any SSHFolderAccessing = usesUserState ? SSHFolderAccess() : InMemorySSHFolderAccess()
        let trust: any TrustedHostKeys = usesUserState
            ? UserDefaultsTrustedHostKeys(folder: folder) : InMemoryTrustedHostKeys(folder: folder)
        let secrets: any SSHSecretStore = isInMemory
            ? InMemorySSHSecretStore() : KeychainSSHSecretStore(keychain: KeychainStore.app)
        return SSHServices(folder: folder, trustedHostKeys: trust, secrets: secrets)
    }
}
