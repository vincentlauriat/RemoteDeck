import Foundation
import RemoteDeckCore
import SSHKit

/// What an SSH connect attempt can authenticate with (TRD › Security › Secrets).
enum CredentialResolution: Sendable {
    case ready(SSHCredentials)
    /// The key is encrypted and no passphrase opened it: ask (Passphrase Sheet). Never returned when
    /// `allowsInteraction` is false (an automatic attempt gets `.failed(.passphraseUnavailable)`).
    case needsPassphrase
    /// A key in `~/.ssh` and no folder grant on this Mac: ask for the folder at Connect.
    case needsFolderAccess
    case failed(SSHCredentialFailure)
}

enum SSHCredentialFailure: Equatable, Sendable {
    /// The key file (path relative to `~/.ssh`) is not in the granted folder; also an empty or
    /// invalid file name.
    case keyFileMissing(String)
    /// The key cannot be read: damaged or not a key, an imported key not (yet) on this Mac or whose
    /// Keychain read failed, or a wrong passphrase during an automatic attempt.
    case keyUnreadable
    /// A key type SSHKit does not use (`ssh-dss`, `sk-…`), named.
    case unsupportedKey(String)
    /// A password machine without a password on this Mac, or whose Keychain read failed (an
    /// automatic attempt never shows the Keychain dialog).
    case passwordMissing
    /// An automatic attempt (`allowsInteraction` false) on an encrypted key with no remembered
    /// passphrase, or whose remembered passphrase cannot be read without a dialog: nobody can be
    /// asked, so the caller ends in "Connection lost" (design › Passphrases).
    case passphraseUnavailable
}

/// Turns a machine's SSH authentication method into `SSHCredentials`, reading the Keychain and the
/// `~/.ssh` folder. Never logs key material or passphrases, and keeps neither: the parsed key goes
/// out in the result only.
///
/// Cost: parsing an encrypted key runs bcrypt_pbkdf (OpenSSH's default 16 rounds), on the main
/// actor, once per connect attempt (twice when a remembered passphrase is wrong and another is
/// given). An unencrypted key, or an encrypted one without any passphrase, never reaches bcrypt.
@MainActor
struct SSHCredentialResolver {
    let passwords: any MachinePasswordStore
    let secrets: any SSHSecretStore
    let folder: any SSHFolderAccessing

    /// `passphrase`: typed in the Passphrase Sheet for this attempt (nil or empty: none; then the
    /// remembered one, if any, is tried). `allowsInteraction` false for automatic attempts: no
    /// Keychain dialog, and a wrong passphrase fails instead of asking.
    func resolve(machine: SessionTarget, passphrase: String?, allowsInteraction: Bool) -> CredentialResolution {
        let user = machine.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch machine.sshAuth {
        case .password:
            guard let password = try? passwords.storedPassword(for: machine.machineID,
                                                               allowsInteraction: allowsInteraction)?.password,
                  !password.isEmpty
            else { return .failed(.passwordMissing) }
            return .ready(.password(user: user, password: password))

        case .keyInSSHFolder:
            guard folder.isGranted else { return .needsFolderAccess }
            let name = machine.sshKeyFileName ?? ""
            let text: String
            do {
                text = try folder.readFile(name)
            } catch SSHFolderError.notGranted {
                return .needsFolderAccess
            } catch SSHFolderError.fileMissing, SSHFolderError.invalidPath {
                return .failed(.keyFileMissing(name))
            } catch {
                return .failed(.keyUnreadable)
            }
            return key(text, user: user, passphrase: passphrase,
                       remembered: .sshLocalKeyPassphrase(machine.machineID), allowsInteraction: allowsInteraction)

        case .importedKey:
            guard let text = try? secrets.secret(.sshPrivateKey(machine.machineID), allowsInteraction: allowsInteraction)
            else { return .failed(.keyUnreadable) }
            return key(text, user: user, passphrase: passphrase,
                       remembered: .sshKeyPassphrase(machine.machineID), allowsInteraction: allowsInteraction)
        }
    }

    /// The key without passphrase first (cheap: an encrypted key refuses before bcrypt), then with the
    /// given passphrase, else the remembered one (`remembered`, read only when needed).
    private func key(_ text: String, user: String, passphrase given: String?, remembered: KeychainAccount,
                     allowsInteraction: Bool) -> CredentialResolution {
        var passphrase = given?.isEmpty == false ? given : nil
        if passphrase == nil {
            switch parse(text, passphrase: nil) {
            case .success(let key): return .ready(.key(user: user, key: key))
            case .failure(.passphraseRequired): break
            case .failure(let error): return failure(error, allowsInteraction: allowsInteraction)
            }
            // A read that fails (no item, needs a dialog) is no remembered passphrase.
            passphrase = try? secrets.secret(remembered, allowsInteraction: allowsInteraction)
            guard passphrase?.isEmpty == false else {
                return allowsInteraction ? .needsPassphrase : .failed(.passphraseUnavailable)
            }
        }
        switch parse(text, passphrase: passphrase) {
        case .success(let key): return .ready(.key(user: user, key: key))
        case .failure(let error): return failure(error, allowsInteraction: allowsInteraction)
        }
    }

    private func parse(_ text: String, passphrase: String?) -> Result<SSHPrivateKey, SSHKeyError> {
        Result { () throws(SSHKeyError) in try SSHPrivateKey.parse(openSSH: text, passphrase: passphrase) }
    }

    private func failure(_ error: SSHKeyError, allowsInteraction: Bool) -> CredentialResolution {
        switch error {
        case .passphraseRequired: allowsInteraction ? .needsPassphrase : .failed(.passphraseUnavailable)
        case .wrongPassphrase: allowsInteraction ? .needsPassphrase : .failed(.keyUnreadable)
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
