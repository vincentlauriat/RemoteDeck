# SSH Terminal — design

Status: draft for Vincent's approval (2026-11-08); builder-check questions answered by Vincent the same day. Brainstormed with Vincent; every line marked
**(Claude's call)** is a default Claude chose that Vincent has not decided. Anything unmarked is
Vincent's decision or a constraint of the existing app.

## Intent

RemoteDeck becomes the one place for **all** of Vincent's machines. Today it opens screen sessions
(Mac ARD, VNC, Anthropic computer use). Vincent also administers Linux machines without a desktop —
Raspberry Pis (e.g. `raspcorse`, on the LAN) and an Azure VM (reached directly on its public address
and through Tailscale) — and does so from Ghostty with `ssh`/`scp`. He wants those machines in the
same Library, and **Connect opens an integrated SSH terminal inside RemoteDeck**, not an external
terminal app.

Success: Vincent stops opening Ghostty to reach a Pi or the Azure VM; he picks the machine in the
Library, gets a terminal that feels like Ghostty, pushes a config file to it, and opens the Pi's web
UI in his browser through a tunnel.

## Goals

1. **SSH machine** — a new machine kind in the Library, with the Library's existing behaviour:
   search, groups, favourites, iCloud sync, Status Notifications (watch), Session History, Menu Bar
   Extra, ⌘-shortcuts.
2. **Integrated terminal** — as close to Ghostty as possible (Vincent: "reste sur Ghostty dans la
   mesure du possible"). Vincent runs Ghostty 1.4.0 with **no config file**, so "like Ghostty" means
   Ghostty's defaults: its default font, theme, cursor, rendering, scrollback behaviour.
3. **Authentication**, per machine, one of:
   - password (Keychain, synchronizable, like Mac passwords);
   - **key used in place** from `~/.ssh` (the user grants RemoteDeck access to the `~/.ssh` folder
     once);
   - **imported key** stored in RemoteDeck's Keychain, synced through iCloud Keychain like machine
     passwords, so another Mac on the same Apple ID connects too.
4. **Host key verification** — first connection shows the host key fingerprint and asks to trust it
   (like `ssh`); a changed key **blocks** the connection with a clear warning. Host key types
   ed25519, ECDSA and RSA (`rsa-sha2-256/512`) must work: Vincent's `known_hosts` holds all three.
   RemoteDeck keeps its own trusted-host list and **never writes** `~/.ssh/known_hosts`.
5. **Local port forwarding** — saved per machine (e.g. Mac `localhost:8080` → the Pi's port 80),
   active while the machine's SSH session is open, with an "Open in browser" action. Use case: the
   Pi's web UI in Vincent's browser.
6. **File transfer** — the equivalent of `scp config.toml raspcorse:`: upload a local file to the
   machine, and download a remote file.

## Non-goals (v1)

- A local shell / general-purpose terminal (RemoteDeck is not replacing Ghostty for local work).
- A remote file browser (Finder-like tree); transfer is upload by drop and download by path only.
- Jump hosts / `ProxyJump`, agent forwarding, remote (`-R`) and dynamic (`-D`) forwarding, X11.
  Vincent's `~/.ssh/config` uses none of these.
- The Claude Assistant on SSH sessions.
- Bonjour discovery of `_ssh._tcp` services **(Claude's call: out of v1; easy follow-up)**.

## Anti-goals

- Weakening the host-key check to make a connection "just work" (no silent TOFU on a changed key,
  no "accept all").
- Copying a private key anywhere Vincent did not ask for: a key used in place stays in `~/.ssh` and
  is read only for the duration of authentication; only an *imported* key enters the Keychain.
- Modifying anything in `~/.ssh`.
- A terminal that feels like a toy next to Ghostty (laggy rendering, broken full-screen apps such as
  `htop`, `vim`, `tmux`, wrong colours, broken UTF-8 or AZERTY input).

## What Vincent has today (recon, 2026-11-07)

- `~/.ssh/config`: one host, `raspcorse` (`HostName raspcorse`, `User vincent`,
  `IdentityFile ~/.ssh/id_ed25519`, `IdentitiesOnly yes`, `ServerAliveInterval 30`,
  `ServerAliveCountMax 4`). No Azure entry, no ProxyJump.
- One key, `id_ed25519` (ed25519, **no passphrase**). Encrypted keys must still be supported
  (passphrase prompt) **(Claude's call)**.
- launchd ssh-agent running with no identities; no 1Password or third-party agent.
- `known_hosts`: 13 entries — 9 ed25519, 2 ecdsa-sha2-nistp256, 2 ssh-rsa.
- Tailscale on this Mac (`100.x`, already `AddressScope.sharedAddressSpace`, i.e. not public).

## Decided shape

### Library and data

- New `MachineKind` case for SSH machines; default port 22.
- New synced fields (schema V3, additive, every property optional or defaulted — CloudKit rules in
  CLAUDE.md): authentication method (password / key in `~/.ssh` / imported key), the key's file name
  for the in-place method (path relative to `~/.ssh`, e.g. `id_ed25519`), and the saved port
  forwards. Representation is the builder's choice (separate model vs encoded field), within the
  CloudKit rules.
- Secrets: passwords and imported private keys (and an imported key's passphrase, if kept) are
  synchronizable Keychain items, like machine passwords; same `-34018` local fallback and launch
  migration rules.
- The `~/.ssh` folder grant is a per-Mac security-scoped bookmark (needs the
  `com.apple.security.files.bookmarks.app-scope` entitlement), never synced. On a Mac without the
  grant, a machine set to "key in `~/.ssh`" asks for the folder at Connect **(Claude's call)**.
- Machine Editor: for an SSH machine, shows host, port, user, authentication method and the port
  forwards; hides scaling and clipboard settings that only make sense for screens. **(Claude's
  call)** Once the `~/.ssh` folder is granted, "Import from ~/.ssh/config" pre-fills name, host,
  user, port and key from a `Host` block.
- Trusted host keys: RemoteDeck's own list. **(Claude's call)** It is local per Mac (not synced:
  trust is a per-Mac judgement, consistent with `PublicAddressConsents`) and, when the `~/.ssh` grant
  exists, a host already present in `~/.ssh/known_hosts` with the same key is trusted without asking
  (read-only use of that file).
- One address per machine: the Azure VM reached directly and over Tailscale is **two Library
  entries** **(Claude's call: no model change)**. Trusted host keys are keyed by host:port, so each
  entry asks once.
- Passphrases of encrypted keys **(Claude's call)**: asked at Connect, with "Remember in Keychain".
  For an imported key it is stored with the key (synchronizable); for a key in `~/.ssh`, a local
  (this-Mac-only) item. Not remembered → an automatic reconnect cannot authenticate silently and
  ends in "Connection lost" with a Reconnect button. (Vincent's only key has no passphrase today.)
- Older clients: v1.0.0 decodes an unknown `kind` as `.macARD` (`MachineKind(rawValue:) ?? .macARD`
  in the schema files), so a Mac still on 1.0.0 would show SSH machines as Macs and an edit there
  could sync a wrong kind back. **Vincent (2026-11-08): every Mac updates through Sparkle**, so no
  code guard; release notes say to update every Mac before adding SSH machines.
- Session History: SSH sessions are recorded like screen sessions (outcomes connected / authFailed /
  unreachable / cancelled / dropped). A changed host key is recorded as a failure **(Claude's call:
  `authFailed` or a new outcome — builder decides, additive raw value)**.
- Status Notifications: the existing TCP probe on the machine's port works unchanged for port 22.

### Session

- **(Claude's call, shown to Vincent in the playback and accepted)** An SSH session is a tab of the
  Session Window, like a screen session; screen and SSH tabs can be mixed in one window. This makes
  `SessionModel`/`SessionManager` (today RFB-shaped) generic or adds a sibling model — that
  refactor is part of the plan. Same
  `WindowGroup(for: UUID.self)` + `SessionTabs` mechanism, ⌘1…⌘9, one session per machine (a second
  Connect brings it forward), session ends only on its window's `willClose`.
- **(Claude's call)** Resilience follows the screen-session rules (TRD › Session resilience): a drop
  after the session is up → one automatic attempt after `reconnectDelay`, then "Connection lost";
  sleep/wake and network loss handled the same way. The remote shell's state is lost on reconnect
  (no tmux magic); the terminal shows a clear separator line.
- Keepalive: send SSH keepalives (Vincent uses 30 s × 4 in his config) **(Claude's call: same
  values)**.
- No "Unencrypted connection over the Internet" warning for SSH — the channel is encrypted. The
  public-address consent sheet does not apply to this kind.
- Security on a public address (Azure direct): the host-key check is the protection; nothing else
  extra in v1.

### Terminal

- Engine: Ghostty's terminal core, as far as feasible. Recon (2026-11-07):
  - libghostty's full C API is not declared stable and not released standalone
    (ghostty.org/docs/about); community SwiftPM wrappers exist (`sethdeckard/libghostty-spm`,
    `Lakr233/libghostty-spm` "GhosttyKit") and building against the macOS 26 SDK needs Homebrew's
    Zig.
  - Mitchell Hashimoto announced (July 2026) a pure-Swift Metal renderer + Swift bindings for
    **libghostty-vt**, "coming soon"; not checked whether it shipped.
  - **(Claude's call)** Preference order: (1) the official libghostty-vt Swift package if released;
    (2) libghostty-vt through its C API with our own Metal/CoreText rendering; (3) full libghostty
    only if it can be fed bytes from an SSH channel instead of spawning a local process (Claude
    assumes it wants a pty child — unverified); (4) **SwiftTerm** as the fallback if none can be
    built reproducibly with the stable Xcode and pinned versions.
  - **Build dependencies (Vincent, 2026-11-08): accepted now.** Zig in the build toolchain (and in
    `release.sh` / CI if needed) or a third-party prebuilt xcframework pinned by version and
    checksum are both acceptable to get Ghostty's core; do not wait for the official Swift package
    (adopt it later if it ships). SwiftTerm is only the fallback if none of (1)–(3) works.
  - The builder's first task is a
    spike that settles this, reported back to Vincent before the **terminal** part is built.
    **(Claude's call)** Only the terminal waits on that report: the SSH package, schema V3, the
    editor, host-key checks, forwarding and SFTP proceed in parallel, and the SSH library choice is
    the builder's (no extra approval).
- Must work: 256-colour and truecolour, UTF-8 including wide characters, alternate screen
  (`htop`, `vim`, `tmux`), mouse reporting, bracketed paste, resize → SSH `window-change`,
  scrollback, copy/paste with ⌘C/⌘V, AZERTY input including ⌥ combinations.
- `TERM`: **(Claude's call)** `xterm-256color` (remote hosts do not have `xterm-ghostty` terminfo).
- Look: Ghostty's default font, cursor and rendering. **Theme follows the system appearance
  (Vincent, 2026-11-08):** Ghostty's default dark palette in dark mode, and a matching light
  palette in light mode (builder picks one of Ghostty's bundled light themes closest to the
  default). ⌥ is not Alt by default, as in Ghostty (keeps AZERTY ⌥ characters); a setting "Use ⌥
  as Meta" **(Claude's call)**.
  Font size adjustable with ⌘+/⌘− **(Claude's call)**.
- Clipboard: local copy/paste, plus OSC 52 **writes** (remote writing the Mac pasteboard) as Ghostty
  does **(Vincent's call, 2026-11-11, reversing Claude's earlier "off")**: needed because programs that
  track the mouse (Claude Code, tmux mouse on, vim) copy through OSC 52. Only while the tab's window is
  key, plain text only, at most 1 MiB, standard clipboard only; OSC 52 reads stay unanswered (T5.3).
- Keyboard capture: the terminal takes the keys a terminal needs; RemoteDeck's app shortcuts
  (⌘1…⌘9, ⌘W, ⌘Y…) keep working. The screen-session system-shortcut tap does not apply.

### Port forwarding

- Per machine, a list of local forwards: local port → remote host (default `localhost`, i.e. the
  machine itself) : remote port, with an optional label.
- Listening on `127.0.0.1` (and `::1`) only, never on other interfaces.
- Started when the SSH session reaches "connected", stopped when it ends; restarted after an
  automatic reconnect.
- A local port already in use → a visible error on that forward, the session stays up.
- "Open in browser" opens `http://localhost:<port>` **(Claude's call: http; a per-forward
  http/https choice is fine)**.
- **Entitlement consequence:** listening needs `com.apple.security.network.server`, which the app
  does not have today (TRD › Security says `network.client` only). Adding it is part of this
  project; TRD › Security and the CLAUDE.md note about the sandbox must be updated.

### File transfer

- Upload: drop a file on the terminal (or a menu item "Upload File…") → a sheet with the remote
  destination folder, pre-filled with the remote home directory **(Claude's call)** → progress →
  done/failed. Overwrite asks first.
- Download: "Download File…" → remote path → save panel → progress.
- Protocol: SFTP subsystem **(Claude's call)**; a server without SFTP shows a clear error (no scp
  protocol fallback in v1).
- Several files at once and folders: **(Claude's call)** multiple files yes, folders no in v1.

## Constraints

- Swift 6 language mode, strict concurrency; macOS 15+; sandboxed; Developer ID + notarized +
  Sparkle (release pipeline unchanged). No new App ID or container.
- Pinned dependency versions (`exactVersion`), like Sparkle; licences must allow a public repo and
  binary distribution.
- An SSH library is needed (none in the app today). Requirements, not a choice: ed25519 and RSA user
  keys (OpenSSH key format, encrypted or not), password and keyboard-interactive auth (*deviation, 2026-11-08: keyboard-interactive is
  not in v1, PRD › Open questions 15*), ed25519 /
  ECDSA / RSA-SHA2 host keys, session channel with pty, local port forwarding, SFTP. **Note:** Apple's
  `swift-nio-ssh` alone does not cover RSA; a layer on top of it (e.g. Citadel) or another library
  may be needed — the builder verifies.
- Testing follows the project's rules: protocol-free unit tests in packages with fakes, no real
  network in hosted tests, a loopback test server where a package can listen, live checks listed
  for Vincent (raspcorse, the Azure VM both directly and over Tailscale).
- Spec docs (PRD, TRD, AppFlow, DesignBrief, BackendSchema, ImplementationPlan) are updated in the
  same change as the decisions, with the same names; UI strings in fr and en.
- A `-LibraryDemo` mode for SSH (fake connection, fake terminal output, no network) so screenshots
  and UI checks never touch a real host **(Claude's call)**.

## Left to the builder

- Library choice for SSH and for the terminal engine (within the preference order above), proven
  by a spike.
- Where the SSH code lives (a new local package next to RFBKit, e.g. `SSHKit`, is the natural fit).
- Data representation of auth method and forwards within the CloudKit rules.
- Exact UI layout of the Machine Editor section, the host-key sheet and the transfer sheet,
  following DesignBrief.
- Task breakdown and order in ImplementationPlan.
