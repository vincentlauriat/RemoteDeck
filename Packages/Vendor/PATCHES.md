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

3. **Keepalive global request**, in `Sources/NIOSSH/NIOSSHHandler.swift`.
   - **Change:** adds the public `NIOSSHHandler.sendKeepalive(promise:)`. It sends the
     `keepalive@openssh.com` global request with want-reply through the existing internal
     `sendGlobalRequestMessage`, and succeeds the promise on either reply: servers answer it with
     `SSH_MSG_REQUEST_FAILURE`, which still proves the peer is alive.
   - **Why:** SSHKit's `SSHConnection` sends it every `SSHKeepalive.interval` and closes after
     `maxMissed` unanswered requests, as `ssh`'s `ServerAliveInterval` / `ServerAliveCountMax` do.
     swift-nio-ssh sends only TCP forwarding global requests publicly; the generic sender and the
     message type are internal.

4. **Connection-layer messages wait during a key re-exchange**, in
   `Sources/NIOSSH/NIOSSHHandler.swift` and
   `Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift`, tested by
   `Tests/NIOSSHTests/RekeyChannelMessageQueueTests.swift` (new file).
   - **Bug:** while a re-key was in progress, the state machine refused every outbound channel
     message with `protocolViolation("key exchange", "Sent unexpected message type: …")`. Data,
     window adjusts, EOF, close, requests and opens written then were lost: a shell write failed,
     and a port forward could stall for good (a lost window adjust leaves the peer without window).
   - **RFC 4253 §7.1:** after sending KEXINIT for a re-exchange, a party sends only transport and
     key exchange messages until it has sent NEWKEYS. The others must wait, not fail.
   - **Change:** the state machine stays pure and only says when to wait
     (`mustDeferConnectionMessages`: `receivedKexInitWhenActive`, `sentKexInitWhenActive`,
     `rekeying`, `rekeyingReceivedNewKeysState`). `NIOSSHHandler` keeps the messages written from
     child channels, and its own global request replies, in one queue in write order. A message
     also waits while earlier ones do, so the order across channels is kept. The queue is written
     right after our NEWKEYS, from the inbound path or the host key validation callback, then
     flushed. Transport and key exchange messages never wait.
   - **Promises:** each queued promise completes once. It completes with its write after the
     re-key. It fails alone if the state machine refuses that message, for example after a
     disconnect. It fails with `ioOnClosedChannel` when the connection goes inactive, and with
     `eof` when the handler is removed. Nothing is queued once the parent channel is inactive.
   - **Tests:** the internal `_deferredConnectionMessageCount` exists for the tests only, like
     `_rekey()`. SSHKit's loopback tests use it to hold a real client mid re-key.
   - **Check:** `swift test --filter RekeyChannelMessageQueueTests` checks the re-key at three
     points: our KEXINIT, the peer's KEXINIT, and our NEWKEYS waiting for host key validation.
     It checks the order across two channels (data, stderr, exec, EOF, close and a channel open),
     a real window adjust, and failure on close.

5. **EOF after the peer's EOF**, in `Sources/NIOSSH/Child Channels/ChildChannelStateMachine.swift`
   (`sendChannelEOF`).
   - **Bug:** upstream let `.halfClosedLocal` (our EOF already sent) send another EOF and moved to
     `.quiescent`. It refused `.halfClosedRemote` (the peer's EOF received) with "Sent EOF out of
     sequence". That is the reverse of `receiveChannelEOF`.
   - **RFC 4254 §5.3:** each side sends its EOF independently.
   - **Change:** the two cases are swapped. An EOF after the peer's moves to `.quiescent`, and a
     second EOF of ours is refused.
   - **Check:** `testEOFCanBeSentAfterThePeersEOF` in `RekeyChannelMessageQueueTests`.

6. **Modification notices (Apache-2.0 §4(b)):** every swift-nio-ssh file changed above starts
   with `// Modified for RemoteDeck (see Packages/Vendor/PATCHES.md).`:
   `SSHKeyExchangeStateMachine.swift`, `ChildChannelStateMachine.swift`, `SSHChildChannel.swift`,
   `NIOSSHHandler.swift`, `SSHConnectionStateMachine.swift` and `ChildChannelMultiplexerTests.swift`.
   The added `RekeyChannelMessageQueueTests.swift` starts with
   `// Added for RemoteDeck (see Packages/Vendor/PATCHES.md).`. `Package.swift` says so in its
   own comment.

7. **Manifest:** the `swift-docc-plugin` dependency is removed. It is a documentation-only
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

3. **SFTP over a channel SSHKit opened** (Task 6): Citadel reaches its SFTP client only through
   `SSHClient.openSFTP()` and its SFTP server only through `SSHServer`, and SSHKit uses neither.
   - **`Sources/Citadel/RemoteDeckSFTP.swift`** (new file): `RemoteDeckSFTP.attachClient(to:)`
     puts Citadel's SFTP client handlers on a session channel whose `sftp` subsystem the server
     already accepted, sends `SSH_FXP_INIT` and completes on `SSH_FXP_VERSION` 3, with a no-op
     logger (Citadel logs paths at `info`). `RemoteDeckSFTP.installServer(on:delegate:username:)`
     puts Citadel's SFTP server on a channel (SSHKit's test server only). `SFTPClient` gains
     handle-level requests (`remoteDeckOpen`, `remoteDeckRead`, `remoteDeckWrite`,
     `remoteDeckClose`) so several reads or writes can be in flight (`SFTPFile` sends one at a time
     and is not `Sendable`), and `remoteDeckCloseChannel()`, which fails every pending request at
     once (cancellation). `SFTPStatusCode` conforms to `Error` so a server delegate can throw a
     status. No protocol code is new: it calls Citadel's existing handlers, parser and serializer.
   - **`Sources/Citadel/SFTP/Client/SFTPClient.swift`:** `SFTPClient.channel`, `responses`,
     `init` and `setupChannelHanders` go from `fileprivate` to `internal`, so the new file can
     build a client. Nothing else changes.
   - **Why not `openSFTP()`:** it needs an `SSHClient`, and the promise it waits on for the
     subsystem request completes when the request is written, not when the server answers, so a
     refusal waits for its 15 s timer. SSHKit asks for the subsystem itself and waits for
     CHANNEL_SUCCESS / CHANNEL_FAILURE.

4. **The SFTP server answers a failed request** (`Sources/Citadel/SFTP/Server/SFTPServerInboundHandler.swift`):
   - **Bug:** when the delegate threw, `stat`, `lstat`, `realpath`, `opendir`, `remove`,
     `setstat`, `symlink` and `rename` sent no reply (`flatMapErrorThrowing { _ in }`), and `open`
     had no error branch at all. A client then waits forever: a missing file could not even be
     reported, since `SFTPDelegate.fileAttributes` can only return attributes or throw.
   - **Change:** those requests are answered with `SSH_FXP_STATUS`, carrying the thrown
     `SFTPStatusCode` (or `SFTPMessage.Status`'s code), else `SSH_FX_FAILURE`
     (`remoteDeckReplyStatus` in the new file).
   - **Who uses it:** SSHKit's `TestSSHServer` only; the app never runs an SFTP server.

5. **SFTP v3 RENAME has no flags field** (`Sources/Citadel/SFTP/SFTPSerializer.swift`,
   `SFTPMessageParser.swift`):
   - **Bug:** Citadel wrote, and required, a `uint32 flags` after the two paths of
     `SSH_FXP_RENAME`. That field exists from SFTP v5 only; a v3 server reads 4 stray bytes.
     OpenSSH's sftp-server discards trailing bytes, a stricter server may refuse the request.
   - **Change:** the serializer no longer writes it; the parser reads it only if present (0 otherwise).

6. **Modification notices:** `SFTPClient.swift`, `SFTPServerInboundHandler.swift`,
   `SFTPSerializer.swift` and `SFTPMessageParser.swift` start with
   `// Modified for RemoteDeck (see Packages/Vendor/PATCHES.md).`; `RemoteDeckSFTP.swift` starts
   with `// Added for RemoteDeck (see Packages/Vendor/PATCHES.md).`.

## Updating

1. Re-archive the new upstream revision into a scratch folder.
2. Re-apply the changes above, then diff against this folder.
3. Update the table, the `exact:` pins in `Packages/SSHKit/Package.swift`, and this file.
4. Run `cd Packages/SSHKit && swift test`, and `swift test` in `swift-nio-ssh` (the filters
   above are a quick subset).
