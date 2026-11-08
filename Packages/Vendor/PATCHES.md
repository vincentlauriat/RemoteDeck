# Vendored packages

SSHKit's SSH library, kept in the repository as local packages because it needs patches no
release carries. The choice of the library is in
`docs/superpowers/specs/2026-11-08-ssh-terminal-spike.md`. Nothing else in the app imports
these packages: they are reached only through `Packages/SSHKit`.

Every remote package that these two bring in is pinned with `exact:` in `Packages/SSHKit/Package.swift`,
at the versions the spike resolved. The vendored manifests keep their upstream ranges.

| Package | Upstream | Version | Revision | Licence |
|---|---|---|---|---|
| `swift-nio-ssh/` | https://github.com/Joannis/swift-nio-ssh | 0.3.5 | `791437a67f5394b13060314c778c0f63124803b1` | Apache-2.0 (`LICENSE.txt`) |
| `Citadel/` | https://github.com/orlandos-nl/Citadel | 0.12.0 | `a054a77eff9f2ef03051022a096377794dc16140` | MIT (`LICENSE`); `CCitadelBcrypt` is OpenBSD's bcrypt_pbkdf and Blowfish (ISC/BSD, notices kept in each source file) |

Neither upstream ships a NOTICE file at these revisions.

## Why both are vendored

Citadel's manifest depends on `https://github.com/Joannis/swift-nio-ssh.git` by URL. We tested
whether a path dependency on the vendored swift-nio-ssh overrides that transitive URL dependency,
since both have the package identity `swift-nio-ssh`. Citadel was then still taken by URL
(`exact: "0.12.0"`).

- **`swift package resolve` in `Packages/SSHKit` (Swift 6.4):** the override takes effect, and
  `show-dependencies` lists Citadel → the vendored path. SwiftPM warns:

  > Conflicting identity for swift-nio-ssh: dependency 'github.com/joannis/swift-nio-ssh' and
  > dependency '…/packages/vendor/swift-nio-ssh' both point to the same package identity
  > 'swift-nio-ssh'. […] This will be escalated to an error in future versions of SwiftPM.

- **The app through XcodeGen (`xcodebuild -resolvePackageDependencies`, Xcode 27.1):** the same
  happens, with the same warning. The output shows
  `swift-nio-ssh: …/Packages/Vendor/swift-nio-ssh @ local`.

The override works today, but only as behaviour that SwiftPM has announced it will turn into an
error. Citadel is therefore vendored too, with its manifest pointing at `../swift-nio-ssh`. Two
more things favour that:

- Citadel's OpenSSH key decryption is internal, and SSHKit needs it for encrypted RSA and ECDSA
  keys (see the Citadel changes below).
- With both vendored, both resolutions run without that warning. They also pin the same
  revisions: no `Joannis/swift-nio-ssh` URL left in the graph, and every remote package at the
  spike's version.

## Files kept

- **swift-nio-ssh:** `Sources/`, `Tests/`, `Package.swift`, `LICENSE.txt` and `README.md`, from
  `git archive 791437a6`. Dropped: CI, docker, scripts, the Swift 5.4 and 5.5 manifests and
  dotfiles.
- **Citadel:** `Sources/Citadel/`, `Sources/CCitadelBcrypt/`, `Package.swift`, `LICENSE` and
  `README.md`, from `git archive a054a77e`. Dropped: `Sources/CitadelServerExample/`, `Tests/`,
  `Examples/`, the Dockerfile, CI and the upstream `Package.resolved`.

## Local changes

### swift-nio-ssh

1. **RFC 8332 RSA host keys**, in `Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`
   (the client's KEX reply guard).
   - **Change:** accept a host-key blob typed `ssh-rsa` when the negotiated host-key algorithm is
     `rsa-sha2-256` or `rsa-sha2-512` (RFC 8332 §3). This is the spike's 3-line patch
     (`nio-ssh-rfc8332.patch`), with its comment reworded.
   - **Why:** swift-nio-ssh requires the blob type to equal the negotiated algorithm, so an
     RSA-only server cannot be reached. No public API reaches this guard.
   - **Signatures:** SSHKit's `SSHRSAHostKey` (`Sources/SSHKit/RSASHA2.swift`) verifies SHA-2
     signatures only, so SHA-1 is never accepted.

2. **No window adjust after a locally-initiated close**, in
   `Sources/NIOSSH/Child Channels/ChildChannelStateMachine.swift`,
   `Sources/NIOSSH/Child Channels/SSHChildChannel.swift` and
   `Tests/NIOSSHTests/ChildChannelMultiplexerTests.swift`.
   - **Source:** cherry-picked from https://github.com/Wellz26/swift-nio-ssh commit
     `a937613283d3cf55169e45fff8862ddb056ea141`.
   - **Change:** adds `canSendWindowAdjust` and gates the window update in `deliverSingleRead` on
     it, plus a regression test.
   - **Why:** a read delivered between our close and the peer's acknowledgement otherwise traps
     in `sendChannelWindowAdjust`. That is what tearing down a stream mid-transfer does (SFTP,
     port forwards).
   - **Our edit:** the upstream commit placed its doc comment under the existing
     "Whether `Channel.isActive` should be true." line. That line is moved back onto
     `isActiveOnChannel`.
   - **Check:** `swift test --filter testWeDontResizeTheWindow` passes, running both the new
     test and its sibling.

3. **Modification notices (Apache-2.0 §4(b)):** every swift-nio-ssh file changed above starts
   with `// Modified for RemoteDeck (see Packages/Vendor/PATCHES.md).`:
   `SSHKeyExchangeStateMachine.swift`, `ChildChannelStateMachine.swift`, `SSHChildChannel.swift`
   and `ChildChannelMultiplexerTests.swift`. `Package.swift` says so in its own comment.

4. **Manifest:** the `swift-docc-plugin` dependency is removed. It is a documentation-only
   plugin, and it would be one more unpinned remote package for Xcode to fetch.

### Citadel

1. **Manifest** (`Package.swift`):
   - **Change:** `swift-nio-ssh` comes from `.package(path: "../swift-nio-ssh")` instead of the
     Joannis URL. The `CitadelServerExample` target and its `ColorizeSwift` dependency are
     removed, and so is the test target, whose sources are not vendored.
   - **Why:** to use the patched swift-nio-ssh above, without the identity conflict, and to keep
     example-only packages out of the graph.

2. **`Sources/Citadel/RemoteDeckKeyDecryption.swift`** (new file):
   - **Change:** adds the public `OpenSSHPrivateSectionDecryption`. It runs Citadel's existing
     internal `OpenSSH.KDF` (bcrypt_pbkdf) and `OpenSSH.Cipher` (AES-128/256-CTR) on the private
     section of an `openssh-key-v1` file, unchanged. Citadel's own parsing covers only ed25519
     and SHA-1 RSA.
   - **Why:** this exposes that step to SSHKit, so `SSHPrivateKey` reads encrypted ed25519, RSA
     and ECDSA P-256 keys without a second crypto implementation. No existing file is edited.
   - **KDF options are read by the wrapper, not by `OpenSSH.KDF(consuming:)`.** Citadel's reader
     refuses bcrypt with 32 rounds or more, so keys made with `ssh-keygen -a 64` or `-a 100`
     failed (reported as an unsupported KDF). The wrapper reads the options itself (string salt,
     uint32 rounds, nothing after) and builds `OpenSSH.KDF.bcrypt` directly. It accepts
     `bcryptRounds` = 1…1024; more is `malformed`, so a hostile file cannot stall the KDF (its
     time grows linearly with the rounds). Tested by SSHKit's `parsesAKeyHardenedWith100BcryptRounds`
     and `bcryptRoundsAboveTheCapThrowMalformed`.

## Updating

1. Re-archive the new upstream revision into a scratch folder.
2. Re-apply the changes above, then diff against this folder.
3. Update the table, the `exact:` pins in `Packages/SSHKit/Package.swift`, and this file.
4. Run `cd Packages/SSHKit && swift test`, and the swift-nio-ssh filter above.
