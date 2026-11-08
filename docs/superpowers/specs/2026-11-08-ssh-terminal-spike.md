# SSH Terminal — spike report (Task 1)

Date: 2026-11-08. Spec: `2026-11-08-ssh-terminal-design.md`. The scratch package (`Spikes/SSHTerminalSpike/`, git-ignored) is deleted after this report is read.

**For Vincent: the terminal part (Task 9) waits on your go for answer (b).** Answer (a) is the builder's call. It is recorded here because it involves a patched dependency.

## Answers

| | Answer |
|---|---|
| **(a) SSH library** | **Citadel 0.12.0** on **Joannis/swift-nio-ssh 0.3.5**, plus two additions. First, a small SSHKit-side adapter for RFC 8332 `rsa-sha2-256/512` and for parsing OpenSSH ECDSA keys. Second, a **3-line patch to swift-nio-ssh** so it accepts an `ssh-rsa` host-key blob under a negotiated `rsa-sha2-*` algorithm. Keyboard-interactive auth is **not** available (see Gaps). |
| **(b) Terminal engine** | **Option 2**: libghostty-vt **1.0.0** through its C API, drawn by our own renderer. Use the official prebuilt XCFramework `https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip`. Its SHA-256 is `2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2`, which equals the `swift package compute-checksum` value. The minisign signature was verified with Ghostty's release key. Alternatively, build it from the signed source tarball with **Zig 0.17.1**. Tag `vt-1.0.0`, commit `0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec`. |
| **(c) Bytes in and out, no process** | **Yes.** `ghostty_terminal_vt_write` takes the SSH channel's bytes. The `GHOSTTY_TERMINAL_OPT_WRITE_PTY` callback returns the terminal's replies, such as DA and DSR. The key encoder (`ghostty_key_encoder_encode`, mode-aware through `ghostty_key_encoder_set_from_terminal`) returns the bytes to write to the channel. No pty or child process is involved anywhere. |

## Method and safety

- **Tools installed with Homebrew:** Zig 0.17.1 (authorised), and **minisign 0.12**, which was not authorised. It was used only to verify the libghostty signatures. Revert with `brew uninstall minisign`.

- **Servers.** The checks ran against local unprivileged `/usr/sbin/sshd` (OpenSSH 10.5p1) on 127.0.0.1, one instance per host key: `:2222` ed25519, `:2223` **RSA only**, `:2225` **ECDSA P-256 only**. Configs, host keys and `authorized_keys` were all generated in the scratch folder.
- **Client keys.** Throwaway keys from `ssh-keygen`: ed25519, ed25519 with a passphrase, RSA 3072 and ECDSA P-256.
- **Nothing real was touched.** `~/.ssh` was not read or written, and raspcorse and Azure were not contacted. Their live checks move to Vincent's live checklist.
- **Password auth.** An unprivileged sshd cannot check macOS passwords, so password auth was proven against Citadel's in-process `SSHServer`.
- **Toolchain.** Xcode 27.1 (27A9275), stable (`xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`), Swift 6.4. Swift 6 language mode.
- **Build artefacts.** Everything was built with `swift build` inside the scratch folder. Nothing was written under `~/Library/Developer/Xcode/DerivedData`.

## (a) SSH library: evidence

Matrix (`ssh-check`, Swift 6 mode):

| Requirement | Citadel 0.12.0 as shipped | With the adapter and NIOSSH patch |
|---|---|---|
| ed25519 user key | PASS | PASS |
| Encrypted ed25519 key (bcrypt, passphrase); wrong passphrase rejected | PASS | PASS |
| RSA 3072 user key | **FAIL**: sshd logs `signature algorithm ssh-rsa not in PubkeyAcceptedAlgorithms`, because Citadel signs with SHA-1 only | **PASS** as `rsa-sha2-512` and as `rsa-sha2-256` (sshd: `Accepted publickey … RSA SHA256:e6T0…`) |
| ECDSA P-256 user key (OpenSSH file) | **FAIL**: no parser (upstream PR #136, still open) | **PASS** (sshd: `Accepted publickey … ECDSA`) |
| ed25519 host key, with the callback receiving the blob | PASS. The fingerprint `SHA256:aTXP+Xc/…` matches `ssh-keygen -lf` | PASS |
| ECDSA P-256 host key | PASS (`SHA256:SN+RpYqt…` matches) | PASS |
| RSA-only host key | **FAIL**: sshd logs `no matching host key type found. Their offer: ssh-ed25519,ecdsa-…` | Adapter alone: **FAIL** with `invalidHostKeyForKeyExchange: Expected rsa-sha2-512, got ssh-rsa`. With the NIOSSH patch: **PASS** (`SHA256:FIoTE+Od…` matches) |
| Password auth; wrong password rejected | PASS (in-process server) | PASS |
| Keyboard-interactive | **Absent** | **Absent** |
| PTY shell, `TERM=xterm-256color` | PASS | PASS |
| `window-change` from 80×24 to 132×43 (`stty size`) | PASS | PASS |
| Local forward 127.0.0.1:18081 → `localhost:18080` (direct-tcpip) | PASS (curl body correct) | PASS |
| SFTP upload and download of 300 kB, byte-identical; remote home through `realpath(.)` | PASS | PASS |

**Why the patch is needed.** swift-nio-ssh conflates a key's blob type with its signature algorithm (`publicKeyPrefix`).

- RFC 8332 user auth tolerates this, because OpenSSH resolves `rsa-sha2-*` to an RSA key.
- RSA host keys do not. `SSHKeyExchangeStateMachine.swift:254` requires the host-key blob type to equal the negotiated algorithm.
- The patch accepts a blob typed `ssh-rsa` when the negotiated algorithm is `rsa-sha2-*`. This is RFC 8332 §3. The adapter's `ssh-rsa` host-key type verifies **only** SHA-2 signatures, so SHA-1 is never accepted.
- No public API reaches this guard, so no option or adapter can fix it.

```diff
-                guard message.hostKey.keyPrefix.elementsEqual(negotiated.negotiatedHostKeyAlgorithm.utf8) else {
+                let rfc8332 = negotiated.negotiatedHostKeyAlgorithm.hasPrefix("rsa-sha2-") && message.hostKey.keyPrefix.elementsEqual("ssh-rsa".utf8)
+                guard rfc8332 || message.hostKey.keyPrefix.elementsEqual(negotiated.negotiatedHostKeyAlgorithm.utf8) else {
```

**Adapter (to live in SSHKit, about 150 lines).** It is built only on public APIs: NIOSSH `NIOSSHPublicKeyProtocol`, `NIOSSHPrivateKeyProtocol`, `NIOSSHSignatureProtocol` and `NIOSSHAlgorithms.register`, plus swift-crypto `_RSA.Signing` with PKCS#1 v1.5 over SHA-256 or SHA-512.

- **Types:** `RSASHA2PrivateKey<V>`, `RSASHA2PublicKey<V>` and `RSASHA2Signature<V>`, plus an `ssh-rsa` host-key type that accepts SHA-2 signatures only.
- **Key parsing:** the OpenSSH key container is parsed for RSA (n, e, d, p, q) and for `ecdsa-sha2-nistp256` (d).
- **Spike limitation:** the spike adapter parses unencrypted RSA and ECDSA files only. Encrypted RSA and ECDSA keys need `bcrypt_pbkdf` plus AES. Citadel has both internally, but they are not public, so SSHKit must bring its own or reuse them through the fork.
- **Upstream PR #135** follows the same RFC 8332 approach for user auth, using Citadel internals. It is still open and does not cover host keys.

**How to pin it (builder's decision; affects Task 2).**

- Citadel's manifest names `Joannis/swift-nio-ssh` by URL, and a root package cannot override a transitive URL without per-user SwiftPM mirrors.
- The patch therefore needs **a pinned fork of both** packages: `swift-nio-ssh` 0.3.5 plus the patch, and Citadel 0.12.0 with its manifest pointing at that fork.
- They can be GitHub forks pinned by `revision`, or local packages vendored under `Packages/`. Vendoring keeps the "no third-party network fetch at release" property and makes the patch reviewable in-repo.
- Also cherry-pick from the Wellz26 fork: "Don't send a window adjust after a locally-initiated close" (`a9376132`).

**Why Citadel 0.12.0 and not 0.12.1.** 0.12.1 (2026-04-04) switched its swift-nio-ssh dependency to `Wellz26/swift-nio-ssh`, a personal fork with zero stars, for Mac Catalyst. 0.12.0 uses `Joannis/swift-nio-ssh`, the fork of Citadel's own author.

**Why no other candidate was tried.** The brief says to try the next candidate when an item fails. Every failing item except keyboard-interactive was fixed with the adapter plus a 3-line patch, proven on the same sshds, so this path converged. libssh2, the obvious alternative, would bring a C library plus a crypto backend (OpenSSL or mbedTLS) to vendor and build for the sandboxed, notarized app. It was not attempted.

**Transitive pins (resolved for Citadel 0.12.0):**

| Package | Version | Revision |
|---|---|---|
| Citadel | 0.12.0 | `a054a77e` |
| Joannis/swift-nio-ssh | 0.3.5 | `791437a6` |
| swift-nio | 2.105.0 | `2f58d8ef` |
| swift-crypto | 3.15.1 | `95ba0316` |
| swift-asn1 | 1.7.4 | `917b472d` |
| swift-atomics | 1.3.1 | `0442cb5a` |
| swift-collections | 1.7.5 | `f96b909e` |
| swift-log | 1.17.0 | `e3da0407` |
| swift-system | 1.8.1 | `869129b7` |
| BigInt | 5.7.0 | `e07e00fa` |

ColorizeSwift is only used by Citadel's example target and is not linked.

**Swift 6 notes for SSHKit:**

- Citadel is not Sendable-clean. It needs `@preconcurrency import Citadel`, and `SSHClient` is non-Sendable.
- `withPTY` from a `@MainActor` context needs a `@Sendable @MainActor` closure.
- Keep Citadel behind an SSHKit actor, and never expose its types to the app.
- `withPTY` throws `ChannelError.alreadyClosed` when the remote shell exits first. Treat that as a normal end.
- A local forward must open the direct-tcpip channel on the local socket's `channelActive`, with autoRead off, then start reading. Reads issued from the bootstrap initializer are dropped before registration.

## (b) Terminal engine: evidence

- **Option 1 is not available.** No libghostty Swift package exists: the ghostty-org repos are ghostty, ghostling, website, discord-bot and zig-gobject.
  - libghostty-vt shipped **1.0.0** on 2026-11-06, as tag `vt-1.0.0` with "prepare for 1.0.0 (#15126)". It ships as a C library with a semver and ABI policy (`PACKAGING-LIBGHOSTTY.md`).
  - Release artifacts are a signed source tarball, a deps tarball, a prebuilt **XCFramework** (static `libghostty-vt.a`, macOS arm64+x86_64 plus iOS, module `GhosttyVt`), WASM builds and docs.
  - The only Swift artefact upstream is `example/swift-vt-xcframework`, which uses a local-path `binaryTarget` and has no renderer.
  - No Swift renderer or Swift bindings announcement could be confirmed. Mitchell Hashimoto's own GitHub repos include only `go-libghostty` among those matching "ghostty" or "swift". His tangled.org page shows `tack` and `go-libghostty`; 2 of its 4 repos were not visible.
- **Option 2 works with the stable Xcode.** A SwiftPM `binaryTarget` on the XCFramework links under Swift 6 with no C++ runtime or extra flags.
  - The source build also succeeded: `zig build --system <deps> -Doptimize=ReleaseFast -Dcpu=baseline -Demit-xcframework=true` with Homebrew **Zig 0.17.1**, offline from the deps tarball, in **79.8 s** (exit 0).
  - Recommendation: the prebuilt XCFramework as `binaryTarget(url:checksum:)`, so there is no Zig in `release.sh` or CI. That exact form (the URL and checksum above) was proven: it resolves, links and `ghostty_version()` prints `1.0.0`. Keep the Zig build as the reproducibility fallback.
- **Render check.** A minimal spike renderer did the drawing: an NSView that walks the render-state API (rows, cells, graphemes, style, resolved fg/bg, cursor, wide flag) and draws each cell with AppKit text drawing.
  - The terminal was fed only from the Citadel PTY channel of the local sshd. The shell was `bash`, because htop and tmux are not installed on this Mac.
  - The images are `cacheDisplay` renders of the view, so they use the same `draw(_:)` path as the window. `screencapture` failed here ("could not create image from display": no Screen Recording permission for the shell). I read every PNG.
  - **Truecolour:** a 64-step background gradient, and `printf '\e[38;2;255;100;0m'` drawn orange. Correct.
  - **256 colours:** cube 16–231 correct. The 16 named colours are correct.
  - **Bold, italic, underline and inverse:** correct.
  - **Wide characters:** `你好世界` takes 2 cells per glyph, and the following columns stay aligned.
  - **Emoji:** 🎉, 👍🏽 and 🇫🇷 each render as one 2-cell cluster **once DEC mode 2027 (grapheme clustering) is on**. That matches Ghostty's default `grapheme-width-method = unicode`; set it with `GHOSTTY_TERMINAL_OPT_MODE_DEFAULT`. With mode 2027 off, the skin-tone modifier and the regional indicators split into separate cells. With it on, bash readline redraws its own input line imperfectly, as in any terminal whose width tables differ from the remote libc.
  - **vim:** the alternate screen with `syntax on` and line numbers renders correctly. After `Esc :q! Enter`, where Esc and Enter are encoded by libghostty (`1b`, `0d`), the main screen is restored intact.
  - **Full-screen curses app:** `top` in alternate screen, with reverse-video column header, renders correctly. htop and tmux are left for the live checklist on raspcorse.
  - **Resize:** after `ghostty_terminal_resize(120, 36)` and the SSH `window-change`, `stty size` reports `36 120` and `tput cols` reports `120`.
  - **Key encoder:** ArrowUp → `1b 5b 41` and Ctrl+C → `03`.
- **Not exercised in the spike** (work for Task 9):
  - mouse reporting, bracketed paste, scrollback and selection, ⌘C/⌘V;
  - AZERTY ⌥ composition;
  - a Metal renderer and font shaping or ligatures;
  - the JetBrains Mono font itself. It is not installed on this Mac, so the spike drew with Menlo 13.

## Sandbox check (ad-hoc signed)

The spike was bundled as `TermSpike.app` with bundle id `local.spike.sshterminal`, signed with `codesign --sign - --options runtime`. Entitlements: `app-sandbox`, `network.client`, `network.server` and `files.bookmarks.app-scope`. No team, no provisioning profile and no App ID.

- With `network.server`, the app connects to 127.0.0.1:2222 and listens on **127.0.0.1:18082** only. `lsof` shows `TCP 127.0.0.1:18082 (LISTEN)`. `curl http://127.0.0.1:18082/forward-target.txt` from outside the app returns `forwarded-ok` through the SSH direct-tcpip channel.
- The same app re-signed **without** `network.server` gets `bind(…): Operation not permitted (errno: 1)`. So the entitlement is required, as the spec says.
- libghostty-vt needs **no** entitlement. It does no I/O and is purely in-process.
- `files.bookmarks.app-scope` was present in the signature but not exercised. There was no `~/.ssh` grant flow in the spike, and `~/.ssh` was off-limits.

## Build time and binary size added

Both were measured with release builds and stripped binaries (`strip -x`) against a minimal Swift executable.

| Component | Build time added | Binary size added |
|---|---|---|
| libghostty-vt 1.0.0 (prebuilt XCFramework, terminal, render state and key encoder used) | ≈ 0 (link only). From source with Zig: +80 s, once per version. | **+1.2 MB** (51 KB → 1.21 MB). This is a floor: dead-stripping removed the unused API. Upper bound ≈ 2.1 MB, the size of the full dylib. |
| Citadel 0.12.0 stack (NIO, swift-nio-ssh, swift-crypto/BoringSSL, BigInt, …) | Clean release build of the spike app with Citadel and libghostty: **38 s**. The SizeProbe package with all three probes: 43 s. | **+8.4 MB** (51 KB → 8.49 MB). RemoteDeck uses neither NIO nor swift-crypto today, so all of it is new. |

## Licences

All licences found allow a public repo and binary distribution.

- **libghostty-vt:** MIT. Linked third-party code: highway (Apache-2.0 OR BSD-3-Clause), simdutf (Apache-2.0 OR MIT), uucode (MIT AND Unicode-3.0), wuffs (Apache-2.0 OR MIT) and translate_c (MIT). Ship their notices.
- **SSH stack:** Citadel (MIT), swift-nio-ssh, swift-nio, swift-crypto, swift-log, swift-atomics, swift-collections, swift-system and swift-asn1 (Apache-2.0), and BigInt (MIT). swift-crypto embeds BoringSSL (OpenSSL/ISC-style licence).
- **JetBrains Mono:** SIL OFL 1.1. It is Ghostty's default font and is not shipped with macOS, so RemoteDeck must bundle it. OFL allows bundling.
- **Ghostty themes:** from iTerm2-Color-Schemes (MIT).

## Ghostty defaults (read from the v1.4.0 source)

- **Font:** `font-family` is empty by default. Ghostty uses its embedded **JetBrains Mono** variable font (`src/font/embedded.zig`), with Symbols Nerd Font and Noto Emoji as fallbacks. `font-size` is **13** on macOS and 12 elsewhere (`src/config/Config.zig:271-275`). → `terminalFontSize` default = **13**.
- **Colours:** background `#282C34`, foreground `#FFFFFF`. The default 16-colour palette is the Tomorrow Night hues (`#1D1F21 #CC6666 #B5BD68 #F0C674 #81A2BE #B294BB #8ABEB7 #C5C8C6`, brights `#666666 #D54E53 #B9CA4A #E7C547 #7AA6DA #C397D8 #70C0B1 #EAEAEA`), plus the standard 6×6×6 cube and grey ramp (`src/terminal/color.zig`).
- **Other defaults:** cursor is a block, and grapheme-width-method is `unicode` (mode 2027 on).
- **Closest bundled light theme: "Tomorrow".** Its palette is the light sibling of the Tomorrow Night hues that Ghostty's default palette uses: background `#FFFFFF`, foreground `#4D4D4C`, palette `#000000 #C82829 #718C00 #EAB700 #4271AE #8959A8 #3E999F #BFBFBF`.
  - "Atom One Light" matches the default background's One Dark lineage, but not the palette. It is the alternative if Vincent prefers it.
  - Palette source: `ghostty-themes-release-20261019-151001-86a776d.tgz` (`themes/ghostty/Tomorrow`), pinned in v1.4.0 `build.zig.zon` (`iterm2_themes`, hash `N-V-__8AAJ3vBQAq1fLMh5J8uWLkeDLS6WAdR2x5KcrmEyz6`), from iTerm2-Color-Schemes.

## Gaps and decisions for Vincent

1. **Keyboard-interactive auth is not supported.** It is missing from both Citadel and the swift-nio-ssh fork: message 60 is decoded only as `USERAUTH_PK_OK`, and there is no `INFO_REQUEST` or `INFO_RESPONSE`.
   - **Consequence:** a server that accepts passwords only through keyboard-interactive (`PasswordAuthentication no`, `KbdInteractiveAuthentication yes`, which is typical of PAM-only setups) cannot be reached with a password. Key auth is unaffected.
   - Debian and Raspberry Pi OS ship `KbdInteractiveAuthentication no` with the `password` method allowed, so raspcorse should accept a password. **This is unverified in the spike** and is on the live checklist.
   - **Options:** (i) v1 without it; (ii) add it to the same swift-nio-ssh fork, a moderate state-machine change.
   - Recommendation: (i), and record it as a spec deviation, unless the Azure VM turns out to need it during the live check.
2. **A patched dependency.** SSHKit will depend on a pinned fork of swift-nio-ssh and Citadel (3-line patch plus manifest URL). See "How to pin it".
3. **Live checklist additions (Vincent):**
   - raspcorse and the Azure VM, both directly and over Tailscale: ed25519 key in place, host-key fingerprint prompt, `htop`, `tmux`, `vim`;
   - a password login on a real OpenSSH server;
   - an RSA-SHA2 host if any of the 2 `ssh-rsa` hosts in `known_hosts` offers only RSA;
   - JetBrains Mono rendering.
