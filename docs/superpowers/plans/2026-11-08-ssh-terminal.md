# SSH Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH machines in the Library whose Connect opens an integrated, Ghostty-like terminal tab, with key/password auth, host-key checks, local port forwards and file upload/download.

**Architecture:** A new UI-free local package `SSHKit` wraps a pinned SSH library (connection, auth, shell channel, local forwards, SFTP) plus pure parsers (`known_hosts`, `ssh_config`, fingerprints). RemoteDeckCore gains `MachineKind.ssh` and schema V3. The app adds a sibling of `SessionModel`, `TerminalSessionModel`, managed by `SessionManager` next to the screen sessions and shown as a tab of the Session Window through a `TerminalSurface` backed by the engine chosen in Task 1.

**Tech Stack:** Swift 6 (strict concurrency), macOS 15+, SwiftUI + AppKit, SwiftData/CloudKit, Keychain, SwiftPM local packages; SSH library and terminal engine chosen and pinned in Task 1.

**Spec:** `docs/superpowers/specs/2026-11-08-ssh-terminal-design.md` (approved by Vincent, 2026-11-08). Read it before any task; it holds the why and every decision quoted below.

## Global Constraints

- Swift 6 language mode; concurrency errors are fixed with isolation, never by lowering the mode.
- macOS 15+, sandboxed, Developer ID + notarized + Sparkle; no new App ID, no new CloudKit container.
- Dependencies pinned with `exactVersion` (plus checksum for any binary target); licences compatible with a public MIT repo and binary distribution.
- Terminal engine preference: (1) official libghostty-vt Swift package, (2) libghostty-vt C API + own rendering, (3) full libghostty fed from an SSH channel, (4) SwiftTerm. Zig in the toolchain or a pinned prebuilt xcframework is accepted (Vincent, 2026-11-08).
- Theme follows the system: Ghostty's default dark palette in dark mode, the closest bundled Ghostty light theme in light mode; Ghostty's default font; `TERM=xterm-256color`; ⌥ is not Meta unless the "Use ⌥ as Meta" setting is on.
- Host keys: ed25519, ECDSA, RSA-SHA2 accepted; unknown key → ask; changed key → block, never an override button; `~/.ssh` is never written.
- Port forwards listen on `127.0.0.1` and `::1` only.
- SSH keepalive 30 s, 4 missed → dropped (Vincent's `ServerAliveInterval 30` / `ServerAliveCountMax 4`).
- No "Unencrypted connection over the Internet" sheet for `.ssh` machines.
- Synced model changes stay CloudKit-compatible: every new property optional or defaulted, additive only; V1 and V2 stay frozen.
- Every UI string in both `fr` and `en` (`Localization/Strings.swift`); models expose enums, views call `settings.t`.
- Hosted tests never touch the network, the real Keychain, `~/.ssh` or a save/open panel; network tests live in `SSHKit` (loopback).
- Unknown `kind` still decodes as `.macARD` (old-client behaviour unchanged); release notes tell Vincent to update every Mac before adding SSH machines.

## Review Focus

1. **A host present in `known_hosts` under another key type** (server now offers ed25519, file has only RSA) → treated as *unknown* (ask), not *changed* (block). Test in Task 3.
2. **A flood of output** (`yes`, `cat` of a 50 MB log) → the UI stays responsive and the stream is not dropped; output is coalesced before reaching the main actor. Test in Task 9.
3. **A local forward port already taken** (another app, or two machines both on 8080) → that forward shows `portInUse`, the shell session stays up, other forwards still start. Tests in Tasks 5 and 11.
4. **Upload onto an existing remote file, a file name with spaces/accents, a missing destination folder** → overwrite asks first; names arrive byte-exact; missing folder is a clear error, nothing partial left behind. Tests in Tasks 6 and 12.
5. **Automatic reconnect needing a passphrase that was not remembered, or a host key that changed meanwhile** → no prompt loop and no silent trust: the session ends in "Connection lost" / the changed-key block. Tests in Task 9.

---

### Task 1: Spike — SSH library and terminal engine (throwaway, reported to Vincent)

**Files:**
- Create: `Spikes/SSHTerminalSpike/` (git-ignored scratch package, deleted after the report)
- Create: `docs/superpowers/specs/2026-11-08-ssh-terminal-spike.md` (the report, committed)

**Interfaces:**
- Produces: the report naming (a) the SSH library + exact version (+ its transitive pins), (b) the terminal engine option number (1–4) + exact version/commit + how it is built (Zig version, or binary URL + SHA-256), (c) whether the engine can be fed bytes and returns input bytes without spawning a process.

- [ ] **Step 1: SSH library check.** Candidate first: Citadel (on swift-nio-ssh). In the scratch package, with Swift 6 mode, prove against `raspcorse` (key `~/.ssh/id_ed25519`, user `vincent`) and against a local `sshd` with an RSA-only host key: password auth, ed25519 key auth, RSA key auth, host key callback receiving the key blob, pty shell with `xterm-256color`, window-change, a local forward, SFTP upload/download. If any item fails, try the next candidate and record why.
- [ ] **Step 2: Engine check.** Look up whether the official libghostty-vt Swift package has shipped (ghostty-org GitHub, Mitchell Hashimoto's announcement of July 2026). Then, in preference order, build the first option that works with the stable Xcode (`xcode-select -p` must not be a beta) and render `htop`, `vim`, 256-colour and truecolour test output (`printf '\e[38;2;255;100;0mX'`), wide characters (`你好`, emoji) fed from the Step 1 shell. Option 3 only if it accepts bytes from the host app instead of a pty child.
- [ ] **Step 3: Sandbox check.** Run the spike as a sandboxed app with `network.client` + `network.server` + `files.bookmarks.app-scope`: confirm the forward listens on 127.0.0.1 and the engine needs no extra entitlement.
- [ ] **Step 4: Write the report** with the three answers above, measured build time added to a clean build, binary size added, and any licence notes.
- [ ] **Step 5: Commit the report; stop and ask Vincent to read it.** Tasks 2–8 and 10–12 may proceed meanwhile; Task 9's terminal view waits for his go.

```bash
git add docs/superpowers/specs/2026-11-08-ssh-terminal-spike.md
git commit -m "docs: report the SSH library and terminal engine spike"
```

---

### Task 2: SSHKit package and pure SSH formats

**Files:**
- Create: `Packages/SSHKit/Package.swift` (macOS 15, Swift 6, depends on the library from Task 1 pinned `exactVersion`)
- Create: `Packages/SSHKit/Sources/SSHKit/HostKey.swift`, `SSHConfigFile.swift`, `PrivateKey.swift`
- Test: `Packages/SSHKit/Tests/SSHKitTests/HostKeyTests.swift`, `SSHConfigFileTests.swift`, `PrivateKeyTests.swift`, fixtures in `Tests/SSHKitTests/Fixtures/` (keys generated with `ssh-keygen` for the tests only: ed25519 plain and with passphrase `test-pass`, RSA 3072, ECDSA P-256)
- Modify: `project.yml` (add the package, link `SSHKit` to the app), `.github/workflows/ci.yml` if it lists package test runs, `CLAUDE.md` › Commands (`cd Packages/SSHKit && swift test`)

**Interfaces:**
- Produces:
  - `public struct SSHHostKey: Hashable, Sendable { public let algorithm: String; public let blob: Data; public var fingerprintSHA256: String }` — `"SHA256:" + base64(sha256(blob))` without `=` padding (OpenSSH format).
  - `public enum SSHConfigFile { public static func parse(_ text: String) -> [SSHConfigHost] }` and `public struct SSHConfigHost: Equatable, Sendable { alias: String; hostName: String?; user: String?; port: Int?; identityFile: String? }` — `Host` blocks with a single non-wildcard alias only; keywords case-insensitive; `#` comments; `~/.ssh/` prefix stripped from `identityFile` (kept relative to `~/.ssh`).
  - `public struct SSHPrivateKey: Sendable` with `public static func parse(openSSH text: String, passphrase: String?) throws(SSHKeyError) -> SSHPrivateKey`, `public var algorithm: String`, and `public enum SSHKeyError: Error, Equatable, Sendable { case passphraseRequired, wrongPassphrase, unsupportedKeyType(String), malformed }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func fingerprintMatchesSSHKeygen() {   // value from `ssh-keygen -lf Fixtures/host_ed25519.pub`
    #expect(try SSHHostKey(openSSHPublicKey: fixture("host_ed25519.pub")).fingerprintSHA256 == "<paste ssh-keygen output>")
}
@Test func parsesVincentsRaspcorseBlock() {
    let text = "Host raspcorse\n    HostName raspcorse\n    User vincent\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n    ServerAliveInterval 30\n"
    #expect(SSHConfigFile.parse(text) == [SSHConfigHost(alias: "raspcorse", hostName: "raspcorse", user: "vincent", port: nil, identityFile: "id_ed25519")])
}
@Test func skipsWildcardAndMultiAliasHosts()      // "Host *", "Host a b" → []
@Test func parsesPortAndIsCaseInsensitive()       // "host x\n  PORT 2222" → port 2222
@Test func parsesUnencryptedEd25519RSAAndECDSA()  // algorithm == "ssh-ed25519" / "rsa-sha2-512"-capable RSA / "ecdsa-sha2-nistp256"
@Test func encryptedKeyWithoutPassphraseThrowsPassphraseRequired()
@Test func encryptedKeyWithWrongPassphraseThrowsWrongPassphrase()
@Test func garbageThrowsMalformed()
```

- [ ] **Step 2: Run** `cd Packages/SSHKit && swift test` — expected: FAIL (types not defined).
- [ ] **Step 3: Implement** the three files; `SSHHostKey(openSSHPublicKey:)` reads `"<alg> <base64> [comment]"`. Private key parsing delegates to the library where it can; only error mapping is ours.
- [ ] **Step 4: Run** `swift test` — expected: PASS. Then `xcodegen generate` and the app build command from CLAUDE.md — expected: `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `feat(sshkit): add the SSHKit package with host keys, ssh_config and private keys`

---

### Task 3: known_hosts matching

**Files:**
- Create: `Packages/SSHKit/Sources/SSHKit/KnownHosts.swift`
- Test: `Packages/SSHKit/Tests/SSHKitTests/KnownHostsTests.swift`

**Interfaces:**
- Consumes: `SSHHostKey` (Task 2).
- Produces: `public struct KnownHosts: Sendable { public init(parsing text: String); public func lookup(host: String, port: Int, key: SSHHostKey) -> KnownHostsMatch }` and `public enum KnownHostsMatch: Equatable, Sendable { case match, mismatch, notFound }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func plainHostMatches()                 // "raspcorse ssh-ed25519 AAAA…" + same key, port 22 → .match
@Test func bracketedPortEntry()               // "[host]:2222 …" matches only port 2222
@Test func hashedEntryMatches()               // "|1|salt|hash …" made with `ssh-keygen -H` on a fixture → .match
@Test func commaSeparatedHostsAndIPs()        // "raspcorse,192.168.1.20 …" matches both names
@Test func sameAlgorithmDifferentKeyIsMismatch()
@Test func otherAlgorithmOnlyIsNotFound()     // Review Focus 1: file has ssh-rsa only, server shows ssh-ed25519 → .notFound
@Test func markersAndCommentsIgnored()        // "@revoked", "@cert-authority", "#…" lines never match
```

- [ ] **Step 2: Run** `swift test --filter KnownHostsTests` — expected: FAIL.
- [ ] **Step 3: Implement** `KnownHosts` (HMAC-SHA1 for hashed entries via CryptoKit `HMAC<Insecure.SHA1>`).
- [ ] **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Commit** `feat(sshkit): match host keys against known_hosts`

---

### Task 4: SSHConnection — connect, authenticate, shell

**Files:**
- Create: `Packages/SSHKit/Sources/SSHKit/SSHConnection.swift`, `SSHShell.swift`, `SSHError.swift`
- Create: `Packages/SSHKit/Tests/SSHKitTests/Support/TestSSHServer.swift` (in-process server on 127.0.0.1, random port, built on the library's server side; echo shell that also reports window-change as `"\u{1b}[size cols rows]"`)
- Test: `Packages/SSHKit/Tests/SSHKitTests/SSHConnectionLoopbackTests.swift` (`.timeLimit(.minutes(1))`)

**Interfaces:**
- Consumes: `SSHHostKey`, `SSHPrivateKey` (Task 2).
- Produces:
  - `public enum SSHCredentials: Sendable { case password(user: String, password: String); case key(user: String, key: SSHPrivateKey) }`
  - `public struct SSHKeepalive: Sendable { public var interval: Duration = .seconds(30); public var maxMissed = 4 }`
  - `public enum SSHError: Error, Equatable, Sendable { case unreachable, timedOut, connectionClosed, hostKeyRejected(SSHHostKey), authFailed, channelFailed(String), sftpUnavailable, portInUse(UInt16), remote(String) }`
  - `public actor SSHConnection { public init(host: String, port: UInt16, keepalive: SSHKeepalive = .init()); public func open(credentials: SSHCredentials, timeout: Duration, validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError); public func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> SSHShell; public func close() async; public var closed: AsyncStream<SSHError?> { get } }`
  - `public final class SSHShell: Sendable { public let output: AsyncThrowingStream<Data, any Error>; public func write(_ data: Data) async throws(SSHError); public func resize(columns: Int, rows: Int) async }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func passwordAuthOpensEchoShell()          // write "hi\n" → output contains "hi"
@Test func ed25519KeyAuth()
@Test func rsaKeyAuthUsesSHA2()                  // server configured to refuse ssh-rsa (SHA-1) signatures
@Test func wrongPasswordIsAuthFailed()
@Test func rejectedHostKeyStopsBeforeAuth()      // validator returns false → .hostKeyRejected(key); server saw no userauth request
@Test func validatorReceivesServerKey()          // key.fingerprintSHA256 == server key fingerprint
@Test func resizeSendsWindowChange()             // resize(120, 40) → output contains "[size 120 40]"
@Test func closedPortIsUnreachable()
@Test func silentServerTimesOut()                // listener that accepts and never speaks, timeout .milliseconds(500) → .timedOut
@Test func keepaliveMissesEndConnection()        // keepalive(interval: .milliseconds(100), maxMissed: 2), server stops answering → closed yields .connectionClosed
@Test func termIsSentAsGiven()                   // server records pty TERM == "xterm-256color"
```

- [ ] **Step 2: Run** `swift test --filter SSHConnectionLoopbackTests` — expected: FAIL.
- [ ] **Step 3: Implement** on the library; map every library error into `SSHError` at the boundary (no library type in the public API).
- [ ] **Step 4: Run** — expected: PASS; then the whole SSHKit suite.
- [ ] **Step 5: Commit** `feat(sshkit): connect, authenticate and open a pty shell`

**As built (Task 4 report, `.superpowers/sdd/2026-11-08-ssh-terminal/task-4-report.md`):**
- `SSHConnection` owns a swift-nio-ssh pipeline. It holds no Citadel `SSHClient`, for two reasons: `SSHClient.connect(on:)` must run on the event loop, and every Citadel connect path has a fixed 10 s login timer that would cut off the host-key prompt.
- Keepalive uses the vendored swift-nio-ssh patch `sendKeepalive(promise:)`.
- `TestSSHServer` is built on swift-nio-ssh's server side.
- **Task 5** can open `direct-tcpip` channels on the `NIOSSHHandler` that the actor holds.
- **Task 6:** Citadel's SFTP client and server are reachable only through `SSHClient` and `SSHServer`. Getting to them needs a new file in vendored Citadel, recorded in PATCHES.md, that wraps an authenticated channel into an `SSHClient` and installs the SFTP subsystem on a test server channel.

---

### Task 5: Local port forwarding

**Files:**
- Create: `Packages/SSHKit/Sources/SSHKit/LocalForward.swift`
- Test: `Packages/SSHKit/Tests/SSHKitTests/LocalForwardLoopbackTests.swift`

**Interfaces:**
- Consumes: `SSHConnection` (Task 4).
- Produces: `extension SSHConnection { public func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError) -> LocalForwardHandle }`, `public final class LocalForwardHandle: Sendable { public let localPort: UInt16; public func stop() async }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func forwardsHTTPToRemotePort()            // TestSSHServer allows direct-tcpip to a tiny HTTP listener; GET via 127.0.0.1:<local> returns its body
@Test func listensOnLoopbackOnly()               // connect to the Mac's en0 address on localPort → refused
@Test func listensOnIPv6Loopback()               // [::1]:<local> works
@Test func portInUseThrows()                     // Review Focus 3: pre-bind the port → .portInUse(port); connection still open (openShell succeeds)
@Test func stopFreesThePort()                    // after stop(), binding the port again succeeds
@Test func closeStopsAllForwards()
```

- [ ] **Step 2: Run** — expected: FAIL.  **Step 3: Implement.**  **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Commit** `feat(sshkit): add local port forwarding on loopback`

---

### Task 6: SFTP upload and download

**Files:**
- Create: `Packages/SSHKit/Sources/SSHKit/SSHFileTransfer.swift`
- Test: `Packages/SSHKit/Tests/SSHKitTests/FileTransferLoopbackTests.swift` (TestSSHServer gains an SFTP subsystem rooted in a temp directory)

**Interfaces:**
- Consumes: `SSHConnection`.
- Produces: `extension SSHConnection { public func fileTransfer() async throws(SSHError) -> SSHFileTransfer }`; `public actor SSHFileTransfer { public func homeDirectory() async throws(SSHError) -> String; public func exists(_ remotePath: String) async throws(SSHError) -> Bool; public func upload(_ local: URL, toDirectory: String, overwrite: Bool, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError); public func download(_ remotePath: String, to local: URL, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) }`; extra cases on `SSHError`: `fileExists(String)`, `noSuchDirectory(String)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func uploadsBytesExactly()                 // 3 MB random file → same SHA-256 on the server side
@Test func uploadNameWithSpacesAndAccents()      // "config été.toml" arrives with that exact name (Review Focus 4)
@Test func existingFileWithoutOverwriteThrows()  // .fileExists(path); remote file untouched
@Test func missingDirectoryThrowsAndLeavesNothing() // .noSuchDirectory; nothing created
@Test func failedUploadRemovesPartialFile()      // server drops mid-transfer → no partial file remains (temp name + rename)
@Test func downloadsBytesExactly()
@Test func progressReachesTotal()                // last progress call == (size, size)
@Test func noSFTPSubsystemIsSFTPUnavailable()
```

- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement** (upload to `<name>.remotedeck-part`, rename when complete).  **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(sshkit): add SFTP upload and download`

---

### Task 7: RemoteDeckCore — `.ssh` kind, schema V3, Keychain accounts

**Files:**
- Modify: `Packages/RemoteDeckCore/Sources/RemoteDeckCore/ModelEnums.swift` (`MachineKind.ssh`, `SSHAuthMethod`, `SessionOutcome.hostKeyRejected`)
- Create: `Packages/RemoteDeckCore/Sources/RemoteDeckCore/RemoteDeckSchemaV3.swift`, `PortForward.swift`
- Modify: `RemoteDeckSchema.swift` (V3 current, stage V2 → V3 lightweight), `MachineValidator.swift`, `KeychainStore.swift` (`KeychainAccount` cases), `LibraryDeduplication.swift` (copy the new fields)
- Test: `ModelTests.swift`, `SyncSchemaTests.swift`, `MachineValidatorTests.swift`, `KeychainStoreTests.swift`, `LibraryDeduplicationTests.swift`

**Interfaces:**
- Produces:
  - `MachineKind.ssh` (raw `"ssh"`); `MachineKind.defaultPort` → 5900, or 22 for `.ssh`.
  - `public enum SSHAuthMethod: String, CaseIterable, Sendable { case password, keyInSSHFolder, importedKey }`
  - V3 `Machine` adds `sshAuthMethod: String?`, `sshKeyFileName: String?` (relative to `~/.ssh`), `portForwardsData: Data?`, plus computed `sshAuth: SSHAuthMethod` (default `.password`) and `portForwards: [PortForward]` (JSON, invalid data → `[]`).
  - `public struct PortForward: Codable, Equatable, Hashable, Sendable, Identifiable { public var id: UUID; public var label: String?; public var localPort: Int; public var remoteHost: String = "localhost"; public var remotePort: Int }`
  - `KeychainAccount.sshPrivateKey(UUID)` → `"sshKey.<uuid>"`, synchronizable; `.sshKeyPassphrase(UUID)` → `"sshPassphrase.<uuid>"`, synchronizable (imported key); `.sshLocalKeyPassphrase(UUID)` → `"sshLocalPassphrase.<uuid>"`, local (key in `~/.ssh`).
  - Validator: for `.ssh`, user name required; `.keyInSSHFolder` requires a non-empty `sshKeyFileName` without `/..`; each forward: local port in `1024...65535`, remote port in `portRange`, local ports unique within the machine. New `Reason` cases `missingKeyFile`, `invalidForwardPort`, `duplicateLocalPort`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func v2StoreOpensAsV3OnDisk()             // existing V2 store file migrates; machines keep their fields; new ones nil
@Test func syncedV3PropertiesAreOptionalOrDefaulted()   // extend SyncSchemaTests' rule to V3
@Test func unknownKindStillDecodesAsMacARD()    // kind "future" → .macARD (old-client rule kept)
@Test func sshDefaultPortIs22()
@Test func portForwardsRoundTripAndBadDataIsEmpty()
@Test func sshRequiresUserName()
@Test func keyInFolderRequiresFileName()
@Test func forwardLocalPortBelow1024IsInvalid()
@Test func duplicateLocalPortsAreInvalid()
@Test func keychainAccountNamesAndSync()        // "sshKey.<id>" sync true, "sshPassphrase.<id>" true, "sshLocalPassphrase.<id>" false
@Test func dedupCopiesSSHFields()
```

- [ ] **Step 2: Run** `cd Packages/RemoteDeckCore && swift test` — FAIL.  **Step 3: Implement.**  **Step 4: Run** — PASS; app build — `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `feat(core): add the SSH machine kind and schema V3`

---

### Task 8: App services — `~/.ssh` access, trusted host keys, credentials

**Files:**
- Create: `RemoteDeck/SSH/SSHFolderAccess.swift`, `RemoteDeck/SSH/TrustedHostKeys.swift`, `RemoteDeck/SSH/SSHCredentialResolver.swift`
- Modify: `RemoteDeck/RemoteDeck.entitlements` (add `com.apple.security.files.bookmarks.app-scope`), `Scripts/release.sh` (entitlement check list), `RemoteDeck/Library/MachineLibraryModel.swift` (delete also removes `sshPrivateKey`/passphrase items and the machine's trusted keys), `RemoteDeck/Sync/LibrarySync.swift` (`LibraryMerger`) (dropped duplicates' `sshPrivateKey`/`sshKeyPassphrase` items copied to the survivor and read back before delete, as passwords), `RemoteDeck/Session/SessionModel.swift` (`SessionTarget` gains `sshAuth: SSHAuthMethod`, `sshKeyFileName: String?`, `portForwards: [PortForward]`)
- Test: `RemoteDeckTests/SSHServicesTests.swift` (with `FakeSSHFolderAccess`, `InMemoryTrustedHostKeys`, `InMemorySSHSecrets` in `RemoteDeckTests/Fakes/`)

**Interfaces:**
- Consumes: `KnownHosts`, `SSHHostKey`, `SSHPrivateKey`, `SSHCredentials` (SSHKit); `KeychainAccount` cases, `SSHAuthMethod` (Task 7).
- Produces:
  - `@MainActor protocol SSHFolderAccessing: AnyObject { var isGranted: Bool { get }; func requestAccess() async -> Bool; func readFile(_ relativePath: String) throws -> String }` — real `SSHFolderAccess`: `NSOpenPanel` on `~/.ssh` (directory only), app-scoped bookmark in UserDefaults key `sshFolderBookmark`, stale bookmark → `isGranted == false`; reads with `startAccessingSecurityScopedResource` for the read only.
  - `enum HostKeyDecision: Equatable { case trusted, unknown, changed(previousFingerprint: String) }`
  - `@MainActor protocol TrustedHostKeys: AnyObject { func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision; func trust(_ key: SSHHostKey, host: String, port: Int); func forget(host: String, port: Int) }` — real `UserDefaultsTrustedHostKeys` (key `trustedHostKeys`, `[ "host:port": ["alg": "fingerprint"] ]`), which also consults `KnownHosts` read through `SSHFolderAccessing` when granted: `.match` → trusted, `.mismatch` → changed, `.notFound` → its own list.
  - `@MainActor protocol SSHSecretStore { func secret(_ account: KeychainAccount, allowsInteraction: Bool) throws(KeychainError) -> String?; func setSecret(_ value: String, for account: KeychainAccount) throws(KeychainError); func deleteSecret(_ account: KeychainAccount) throws(KeychainError) }` (Keychain in the app, in memory in tests and demo). Synced items fall back to local items on `-34018` in unentitled builds and are moved to synced by the existing launch migration, exactly like machine passwords.
  - `enum CredentialResolution { case ready(SSHCredentials), needsPassphrase, needsFolderAccess, failed(SSHCredentialFailure) }`, `enum SSHCredentialFailure: Equatable { case keyFileMissing(String), keyUnreadable, unsupportedKey(String), passwordMissing }`
  - `@MainActor struct SSHCredentialResolver { func resolve(machine: SessionTarget, passphrase: String?, allowsInteraction: Bool) -> CredentialResolution }`

- [ ] **Step 1: Write the failing tests**

```swift
func testKnownHostsMatchIsTrustedWithoutAsking()
func testKnownHostsMismatchIsChanged()
func testOwnListTrustAfterAccept()                 // unknown → trust → trusted; another port is unknown
func testOwnListChangedKeyIsChanged()
func testNoFolderGrantUsesOwnListOnly()
func testNeverWritesSSHFolder()                    // FakeSSHFolderAccess records writes: none exist in its API; assert only readFile was called
func testKeyInFolderWithoutGrantNeedsFolderAccess()
func testEncryptedKeyWithoutPassphraseNeedsPassphrase()
func testRememberedLocalPassphraseIsUsedNonInteractively() // allowsInteraction false reads sshLocalPassphrase
func testImportedKeyReadsSyncedItems()
func testDeleteMachineRemovesSSHSecretsAndTrust()
func testMergeCopiesImportedKeyToSurvivor()
```

- [ ] **Step 2: Run** the hosted test command with `-only-testing:RemoteDeckTests/SSHServicesTests` — FAIL.  **Step 3: Implement.**  **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(ssh): add ~/.ssh access, trusted host keys and credential resolution`

---

### Task 9: TerminalSessionModel, SessionManager integration and the terminal view

**Files:**
- Create: `RemoteDeck/SSH/SSHSessionConnection.swift` (protocol + `SSHConnection` conformance), `RemoteDeck/SSH/TerminalSessionModel.swift`, `RemoteDeck/SSH/TerminalSurface.swift` (protocol + the Task 1 engine adapter), `RemoteDeck/SSH/TerminalOutputCoalescer.swift`, `RemoteDeck/Views/TerminalSessionView.swift`, `RemoteDeck/Views/HostKeySheet.swift`, `RemoteDeck/Views/PassphraseSheet.swift`
- Modify: `RemoteDeck/Session/SessionManager.swift` (terminals beside sessions), `RemoteDeck/Views/SessionWindowView.swift` (choose the view by kind), `RemoteDeck/Library/SessionLauncher` call sites (Library, Menu Bar Extra, History Reconnect), `RemoteDeck/Localization/Strings.swift`, `RemoteDeck/Localization/Localization.swift` (`AppSettings.terminalOptionAsMeta`, `terminalFontSize`)
- Test: `RemoteDeckTests/TerminalSessionModelTests.swift`, `RemoteDeckTests/TerminalSessionResilienceTests.swift`, `RemoteDeckTests/Fakes/FakeSSHSessionConnection.swift`, `RemoteDeckTests/Fakes/FakeTerminalSurface.swift`

**Interfaces:**
- Consumes: Tasks 4, 7, 8; `SessionClock`, `SessionResilience`, `ReachabilityClock`, `MachinePasswordStore`, `SessionTarget`, `SessionModel.WaitReason`, `SessionRecord` (existing).
- Produces:
  - `protocol SSHSessionConnection: AnyObject, Sendable { func open(credentials: SSHCredentials, timeout: Duration, validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError); func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> any SSHShellChannel; func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError) -> any LocalForwarding; func fileTransfer() async throws(SSHError) -> any FileTransferring; func close() async; var closed: AsyncStream<SSHError?> { get } }` with `SSHShellChannel`, `LocalForwarding`, `FileTransferring` mirroring `SSHShell`, `LocalForwardHandle`, `SSHFileTransfer`.
  - `@MainActor protocol TerminalSurface: AnyObject { var view: NSView { get }; var onInput: (Data) -> Void { get set }; var onResize: (_ columns: Int, _ rows: Int) -> Void { get set }; func feed(_ data: Data); func showSeparator(_ text: String); func apply(_ appearance: TerminalAppearance) }`, `struct TerminalAppearance: Equatable { var isDark: Bool; var fontSize: CGFloat; var optionAsMeta: Bool }`.
  - `@MainActor @Observable final class TerminalSessionModel { enum Phase: Equatable { case idle, connecting, connected, failed(TerminalFailure), waiting(SessionModel.WaitReason), ended /* remote shell exited: no reconnect (9a) */, closed }; enum TerminalFailure: Equatable { case connect(SSHError), credentials(SSHCredentialFailure), sshFolderAccessNeeded /* 9a */, hostKeyChanged(previousFingerprint: String, newFingerprint: String), connectionLost }; /* 9a also: failure.action/outcome/message(t), passphraseRejected, overlay, separatorText, hasWindow, bringWindowForward, openOrder; SessionManager.watchedState(_:)/hasSession(_:)/openSessionCount; SSHCredentialResolver.resolveOffMain */ struct HostKeyPrompt: Equatable { let host: String; let port: Int; let key: SSHHostKey }; private(set) var phase: Phase; private(set) var hostKeyPrompt: HostKeyPrompt?; private(set) var needsPassphrase: Bool; func connect(); func trustHostKey(); func rejectHostKey(); func providePassphrase(_ passphrase: String, remember: Bool); func cancelPassphrase(); func attach(_ surface: any TerminalSurface); func beginClose() -> SessionRecord?; func completeClose(record: SessionRecord?) async; func networkLost(); func networkRestored(); func suspendForSleep(); func resumeAfterWake() }`
  - `SessionManager`: `private(set) var terminals: [UUID: TerminalSessionModel]`, `func terminal(for machineID: UUID) -> TerminalSessionModel?`; `requestWindow`, `isConnecting`, `close`, `watchedState`, `liveRecordIDs`, the network/sleep fan-out and `stop()` cover both dictionaries. `makeTerminal` is injected like `rfbConnection` (`nonisolated static func sshConnection(_ target: SessionTarget) -> any SSHSessionConnection`).
  - `TerminalOutputCoalescer`: collects shell output off the main actor and delivers at most one `feed` per display frame (≤ 16 ms) with everything received since.

- [ ] **Step 1: Write the failing model tests** (fakes only)

```swift
func testConnectUnknownHostKeyShowsPromptThenTrustConnects()
func testRejectHostKeyEndsFailedWithoutAuth()               // fake saw no open(credentials)
func testChangedHostKeyBlocksWithFingerprints()             // phase == .failed(.hostKeyChanged(prev, new)); no trust API reachable from it
func testPassphrasePromptThenRememberStoresLocalItem()
func testCancelPassphraseIsCancelledOutcome()
func testShellOutputIsFedAndInputIsWritten()
func testResizeForwardsToShell()
func testRecordWrittenWithOutcomeAndDuration()              // connected → close: SessionRecord outcome .connected, end set
func testHostKeyRejectionRecordsHostKeyRejectedOutcome()    // both a declined unknown key and a changed key
func testDeclinedKeyShowsRetryBannerTabStaysOpen()
func testConnectMillisIsClickToShellOpen()                  // SessionRecord.connectMillis; bytesReceived = shell output bytes
func testSecondConnectBringsExistingTabForward()            // SessionManager.requestWindow returns false for an open terminal
func testOutputFloodIsCoalesced()                           // Review Focus 2: 50 MB in 64 KB chunks → feed calls ≤ frames elapsed + 1, bytes total exact, main actor never blocked > 50 ms
```

- [ ] **Step 2: Write the failing resilience tests** (`FakeReachabilityClock`, `FakeNetworkPath`, private `NotificationCenter`, as `SessionResilienceTests`)

```swift
func testDropAfterConnectedReconnectsOnceAfterDelayAndShowsSeparator()
func testSecondDropWithin60sIsConnectionLost()
func testSleepSuspendsAndWakeResumesAfterGrace()
func testAutomaticAttemptNeedingPassphraseEndsConnectionLostWithoutPrompt()   // Review Focus 5
func testAutomaticAttemptWithChangedHostKeyBlocks()                           // Review Focus 5: no prompt, .hostKeyChanged
func testNoPublicInternetSheetForSSH()
```

- [ ] **Step 3: Run** `-only-testing:RemoteDeckTests/TerminalSessionModelTests -only-testing:RemoteDeckTests/TerminalSessionResilienceTests` — FAIL.
- [ ] **Step 4: Implement the model, connection protocol and SessionManager changes.** Follow `SessionModel`'s rules: generation token checked after every await, `suspend` bumps the generation before teardown, automatic attempts read secrets with `allowsInteraction: false`, close order = stop forwards → close shell → `close()`.
- [ ] **Step 5: Run** — PASS.
- [ ] **Step 6: Terminal view (waits for Vincent's go on the Task 1 report).** `TerminalSessionView` hosts `surface.view` via `NSViewRepresentable`, overlays like the screen session (connecting / reconnecting / waiting for network), presents `HostKeySheet` (host, port, algorithm, `fingerprintSHA256`, Trust / Cancel) and `PassphraseSheet` (secure field, "Remember in Keychain", Connect / Cancel). Changed-key banner: both fingerprints, the text that the server's identity changed, a "Remove from RemoteDeck's trusted keys…" action in the Machine Editor only (not in the banner). App shortcuts keep priority (⌘1…⌘9, ⌘W, ⌘Y, ⌘?), everything else goes to the surface; ⌘C/⌘V copy/paste; ⌘+/⌘− font size stored in `terminalFontSize` (default: Ghostty's default size from Task 1's report); dark/light from the effective appearance; `terminalOptionAsMeta` toggle in Settings. OSC 52 ignored.
- [ ] **Step 7: Build and look.** App build; launch `-LibraryDemo ssh` (Task 13 adds it — until then a local `sshd` session) and take a capture of light and dark mode with `screencapture -l <window id>`; Read the PNG.
- [ ] **Step 8: Commit** `feat(ssh): add terminal sessions in the Session Window`

---

### Task 10: Machine Editor for SSH machines

**Files:**
- Modify: `RemoteDeck/Library/MachineEditorModel.swift`, `RemoteDeck/Views/MachineEditorView.swift`, `RemoteDeck/Library/LibraryServices.swift` (`SSHConnectionTester`), `RemoteDeck/Views/MachineRowView.swift` / `MachineDetailView.swift` (kind icon `terminal`), `Strings.swift`
- Create: `RemoteDeck/Views/SSHConfigImportSheet.swift`
- Test: `RemoteDeckTests/MachineEditorSSHTests.swift`

**Interfaces:**
- Consumes: Tasks 7, 8; existing `MachineEditorModel` save path (Keychain first, then store).
- Produces: `MachineEditorModel` gains `sshAuth: SSHAuthMethod`, `sshKeyFileName: String`, `portForwards: [PortForward]`, `func importKey(from url: URL) throws` (reads the file the user picked through `NSOpenPanel`, parses it with `SSHPrivateKey.parse`, keeps text only until save, then `.sshPrivateKey(id)`), `func applyConfigHost(_ host: SSHConfigHost)`; `protocol SSHTester: Sendable { func test(host: String, port: UInt16, credentials: SSHCredentials, timeout: Duration, trusted: @Sendable (SSHHostKey) async -> Bool) async throws(SSHError) }`.

- [ ] **Step 1: Write the failing tests**

```swift
func testSwitchingToSSHSetsPort22OnlyIfPortUntouched()
func testSSHHidesScalingAndClipboard()                 // model exposes `showsScreenSettings == false`
func testImportFromConfigFillsFields()                 // raspcorse block → name, host, user vincent, keyInSSHFolder, id_ed25519
func testImportedKeySavedToKeychainNotStore()          // store has no key text; InMemorySSHSecrets has sshKey.<id>
func testEncryptedImportedKeyAsksPassphraseOnSave()
func testTestConnectionUnknownHostKeyAsksThenTrusts()       // Host Key Sheet in the editor; Trust → test goes on, key trusted; Cancel → .failed(.hostKeyUnknown(fingerprint))
func testEditedHostOrPortForgetsOldTrust()                  // save with a new host:port → TrustedHostKeys.forget(old host, old port)
func testTestConnectionTimeout5s()
func testForwardValidationErrorsShown()
```

- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement** (new `TestConnectionFailure` cases `hostKeyUnknown(String)`, `hostKeyChanged`, `ssh(SSHError)` with fr/en messages).  **Step 4: Run** — PASS; app build.
- [ ] **Step 5: Commit** `feat(ssh): edit SSH machines and import them from ~/.ssh/config`

---

### Task 11: Port forwards at run time

**Files:**
- Modify: `RemoteDeck/SSH/TerminalSessionModel.swift` (forward lifecycle), `RemoteDeck/Views/TerminalSessionView.swift` (toolbar menu), `RemoteDeck/RemoteDeck.entitlements` (`com.apple.security.network.server`), `Scripts/release.sh` (entitlement list), `Strings.swift`
- Test: `RemoteDeckTests/TerminalForwardTests.swift`

**Interfaces:**
- Consumes: `LocalForwarding` (Task 9), `PortForward` (Task 7).
- Produces: `TerminalSessionModel.forwardStates: [PortForward.ID: ForwardState]`, `enum ForwardState: Equatable { case starting, active, failed(SSHError), stopped }`, `func openInBrowser(_ id: PortForward.ID)` → `NSWorkspace.open(URL(string: "http://localhost:<localPort>"))` through an injected `URLOpening`.

- [ ] **Step 1: Write the failing tests**

```swift
func testForwardsStartWhenConnectedAndStopOnClose()
func testPortInUseFailsOnlyThatForward()          // Review Focus 3: shell stays connected, the other forward active
func testForwardsRestartAfterAutomaticReconnect()
func testOpenInBrowserURL()                       // "http://localhost:8080"
```

- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement**; toolbar shows each forward (`label` or `localhost:8080 → localhost:80`), its state and "Open in Browser".  **Step 4: Run** — PASS; app build; `codesign -d --entitlements - <app>` lists `network.server`.
- [ ] **Step 5: Commit** `feat(ssh): run saved local port forwards with the session`

---

### Task 12: File upload and download

**Files:**
- Create: `RemoteDeck/SSH/FileTransferModel.swift`, `RemoteDeck/Views/FileTransferSheet.swift`
- Modify: `TerminalSessionView.swift` (drop target, menu items "Upload File…" ⌘U, "Download File…" ⇧⌘D — **(Claude's call)**, check against existing menus), `Strings.swift`
- Test: `RemoteDeckTests/FileTransferModelTests.swift`

**Interfaces:**
- Consumes: `FileTransferring` (Task 9).
- Produces: `@MainActor @Observable final class FileTransferModel { enum Step: Equatable { case chooseDestination(files: [URL], directory: String), confirmOverwrite([String]), transferring(done: Int64, total: Int64), finished, failed(SSHError) }; func drop(_ urls: [URL]); func setDirectory(_ path: String); func start(); func confirmOverwrite(); func cancel(); func download(remotePath: String, to: URL) }` — folders in a drop are refused with a message; several files allowed.

- [ ] **Step 1: Write the failing tests**

```swift
func testDropPrefillsRemoteHome()
func testDroppedFolderIsRefused()
func testExistingRemoteFileAsksBeforeOverwrite()      // Review Focus 4
func testMissingDirectoryShowsError()
func testMultipleFilesProgressSumsTotals()
func testCancelStopsTransfer()
```

- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement.**  **Step 4: Run** — PASS; app build.
- [ ] **Step 5: Commit** `feat(ssh): upload and download files over SFTP`

---

### Task 13: Demo mode, docs, live checklist

**Files:**
- Modify: `RemoteDeck/Library/LibraryDemo.swift` (mode `ssh`: one "Raspberry" SSH machine with two forwards, fake connection printing a scripted login banner and prompt, fake host-key prompt on first Connect, fake transfer), `CLAUDE.md` (Commands: `-LibraryDemo ssh`, SSHKit test command; Architecture: SSHKit and Terminal sessions bullets), `README.md` (features), `docs/index.html` (EN/FR feature line), `PRD.md`, `TRD.md`, `AppFlow.md`, `DesignBrief.md`, `BackendSchema.md`, `ImplementationPlan.md` (status lines of T7.x)
- Test: `RemoteDeckTests/LibraryDemoTests.swift` (ssh mode never builds a real `SSHConnection`)

- [ ] **Step 1: Write the failing test** `testSSHDemoUsesFakeConnectionOnly`. **Step 2: Run** — FAIL. **Step 3: Implement the mode.** **Step 4: Run** — PASS.
- [ ] **Step 5: Run every suite**: `swift test` in RFBKit, RemoteDeckCore, ClaudeKit, SSHKit; hosted `xcodebuild … test`. Expected: all green; record counts in `ImplementationPlan.md`.
- [ ] **Step 6: Live checklist for Vincent** (in ImplementationPlan T7 status): `raspcorse` with the key in `~/.ssh` (grant once), import from `~/.ssh/config`, the Azure VM direct and over Tailscale (two entries, each trusts once), `htop`/`vim`/`tmux`, AZERTY ⌥ characters and ⌥-as-Meta, a forward to the Pi's web UI opened in the browser, `scp`-equivalent upload of a config file, sleep/wake mid-session, a changed host key (edit the trusted fingerprint to provoke it), the CloudKit schema V3 deployed to Production before release (CloudKit Console), every Mac updated before adding SSH machines.
- [ ] **Step 7: Commit** `docs: document SSH machines and add the ssh demo mode`
