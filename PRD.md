# PRD — RemoteDeck

## Product name and one-line pitch

**RemoteDeck** *(assumption: provisional name)* — a native macOS client that opens screen sessions on remote Macs (Apple Remote Desktop / VNC protocol) and on Anthropic-managed virtual machines from one window, replacing Apple Remote Desktop and Screen Sharing for daily use.

## Target users

- **Vincent, solo power user** — runs several Macs (servers, home/office machines) and works with Anthropic-managed environments (Claude computer use desktops, Cowork VM, Claude Code cloud sandboxes). Needs to reach any of them in a few seconds, with saved credentials, from a single app.

## Problem and current solution

Today, reaching a remote Mac means juggling Apple Remote Desktop (heavy, fleet-management oriented, aging UI) and the built-in Screen Sharing app (no machine library, no tabs). Anthropic-managed VMs are reached through yet other tools (a browser noVNC page, a VNC client, or not at all). There is no single, fast, keyboard-friendly client that covers both.

## Goal and success metric

- **Goal:** one app for every remote screen Vincent uses.
- **Success metric:** over 30 consecutive days of use, Apple Remote Desktop and Screen Sharing are opened **0 times**, and **≥ 90 %** of remote sessions start in **≤ 5 s** from the click to the first frame. Measured by **Session History** (session log with start time, connection time and duration). *(assumption)* How the ≤ 5 s share is counted (T4.6, `HistorySummary`; decision of the 2026-10-23 review, Vincent may revisit): over the attempts started in the last 30 × 24 h, fast = a first frame within 5000 ms of the click (inclusive). The denominator holds every attempt whose first frame came (outcome `connected`, or `dropped` after a frame, including a session whose run was killed later) **plus** every attempt that ended without a first frame more than 5000 ms after it started (unreachable or timeout, a cancel or a drop after a long wait: the user waited past the target, so it counts as slow). Attempts that ended without a first frame within 5000 ms (refused, authentication failed, a quick cancel; exactly 5000 ms included) and records without an end (in progress, interrupted) stay out. Each Retry or Reconnect is its own attempt. The summary also counts the failures apart, by outcome. The share is shown floored to 0.1 % (89.96 % reads 89.9 %). The Apple Remote Desktop / Screen Sharing half of the metric is not measured by the app (the summary says so); it stays a manual check (T6.5).
- **After 1.0 (SSH machines, `docs/superpowers/specs/2026-11-08-ssh-terminal-design.md`):** RemoteDeck also becomes the place for the machines Vincent reaches without a desktop (Raspberry Pis, an Azure VM). Success: he stops opening Ghostty to reach them. This does not change the success metric above, which counts screen sessions (see Open questions 14 for how SSH sessions enter Session History).

## Main features

| Feature | User benefit | Priority |
|---|---|---|
| Machine Library | All remote machines in one sidebar with saved credentials, groups and search | P0 |
| Screen Session | View and control a remote Mac or VNC desktop with ARD (Diffie-Hellman) and VNC password authentication | P0 |
| Bonjour Discovery | Find Macs with Screen Sharing / Remote Management enabled on the LAN without typing addresses | P0 |
| Anthropic VM Connect | Open a Claude computer use environment (VNC endpoint) like any other machine | P0 |
| Shared Clipboard | Copy and paste text between the local and remote machine | P1 |
| Session Tabs | Keep several sessions open in tabs of one window and switch with ⌘1…⌘9 | P1 |
| iCloud Sync | The Machine Library is identical on all of Vincent's Macs | P1 |
| Claude Assistant | Ask Claude to describe the remote screen or perform a task on it, with each action confirmed | P1 |
| Status Notifications | macOS notification when a watched machine goes offline or comes back | P1 |
| Session History | Local log of sessions (when, which machine, how long), which also measures the success metric | P1 *(assumption: proposed feature)* |
| SSH Machines & Terminal | Machines of a new kind "SSH" in the Library (search, groups, favourites, iCloud Sync, Status Notifications, Session History, Menu Bar Extra); Connect opens an integrated terminal as close to Ghostty as possible, as a tab of the Session Window. Authentication by password, by a key used in place from `~/.ssh` or by an imported key synced through iCloud Keychain; host key check with a trusted-host list of its own. Saved local port forwards per machine (e.g. a Pi's web UI opened in the browser) and file upload/download over SFTP | P1, post-1.0 (design and plan approved 2026-11-08; ImplementationPlan › Step 7) |
| File Transfer | Drag files to and from a remote Mac | P2 |
| Cowork & Cloud Sandbox Access | Reach the Claude Cowork VM and Claude Code cloud sandboxes if a documented access path exists. **Dropped** after the T4.7 spike (2026-10-25): no documented access path exists | P2 (dropped) |

## Out of scope for v1

- **ARD fleet management** (package deployment, reports, Unix command broadcast, asset inventory): this is what makes ARD heavy, and it is not needed for one-user screen access.
- **Audio forwarding**: not part of standard RFB, and rarely needed.
- **Access over the Internet without a VPN** (relay or NAT traversal): it needs server infrastructure. Use Tailscale or an existing VPN instead.
- **Apple's "High Performance" Screen Sharing mode** (macOS 14+): proprietary protocol, no public specification.
- **Multi-user, accounts, roles**: solo tool.
- **SSH machines, v1 non-goals** (design, Non-goals): a local shell or general-purpose terminal (RemoteDeck does not replace Ghostty for local work); a remote file browser (transfer is upload by drop and download by path only, several files but no folders); jump hosts / `ProxyJump`, agent forwarding, remote (`-R`) and dynamic (`-D`) forwarding, X11; the Claude Assistant on SSH sessions; Bonjour discovery of `_ssh._tcp` services (follow-up); the scp protocol (SFTP only); one machine reached through two addresses (the Azure VM directly and over Tailscale are two Library entries).

## User stories

1. **Machine Library** — As Vincent, I want to save a machine with its address, credentials and group, so that I can reconnect in one click.
2. **Screen Session** — As Vincent, I want to see and control the remote screen with my keyboard and mouse, so that I can work on it as if I were there.
3. **Bonjour Discovery** — As Vincent, I want to see the Macs advertising Screen Sharing on my network, so that I can add them without looking up IP addresses.
4. **Anthropic VM Connect** — As Vincent, I want to add a Claude computer use environment by its VNC endpoint, so that I can watch and take over what Claude is doing.
5. **Shared Clipboard** — As Vincent, I want text copied on one side to be pastable on the other, so that I don't retype commands.
6. **Session Tabs** — As Vincent, I want several sessions in tabs, so that I can hop between machines without window clutter.
7. **iCloud Sync** — As Vincent, I want my Machine Library on every Mac I own, so that I set a machine up only once.
8. **Claude Assistant** — As Vincent, I want to ask Claude "what is on this screen?" or "open Terminal and run `uptime`", so that I can delegate routine remote tasks while keeping control.
9. **Status Notifications** — As Vincent, I want to be notified when a watched server goes offline, so that I react before it matters.
10. **Session History** — As Vincent, I want a log of my sessions, so that I know which machines I use and whether the app is fast enough.
11. **SSH Machines & Terminal** — As Vincent, I want my Raspberry Pis and my Azure VM in the same Library as my Macs, and Connect to open a terminal that feels like Ghostty inside RemoteDeck, so that I no longer open Ghostty to reach them.
12. **SSH authentication and host keys** — As Vincent, I want to log in with a password, with my key in `~/.ssh` or with an imported key that follows me to my other Macs, and to be warned when a server's identity changes, so that I connect safely without retyping secrets.
13. **Port forwards** — As Vincent, I want saved local forwards on a machine (e.g. `localhost:8080` to the Pi's port 80) and an "Open in browser" action, so that I reach the Pi's web UI without a terminal command.
14. **File transfer** — As Vincent, I want to drop a config file on the terminal to upload it to the machine, and to download a remote file by its path, so that I do not need `scp` in another window.

## Acceptance criteria

1. Given an empty library, when I add a machine with host `mini.local`, user and password, then it appears in the sidebar, the password is stored in the Keychain, and a double-click opens a session.
2. Given a Mac with Remote Management enabled, when I connect with valid macOS credentials, then the first frame appears in ≤ 5 s on the LAN and mouse and keyboard input are applied with ≤ 50 ms of added local latency.
2b. Given wrong credentials, when I connect, then the session shows "Authentication failed" and offers to edit credentials, without crashing or looping.
3. Given two Macs advertising `_rfb._tcp` on the LAN, when I open the Discovery Panel, then both are listed within 3 s and one click pre-fills the Machine Editor.
4. Given a computer use container exposing VNC on port 5900, when I add it as an "Anthropic VM" machine and connect, then I see its desktop and can type into it.
5. Given an open session with Shared Clipboard enabled, when I copy text locally and press ⌘V in the remote window, then the text is pasted remotely; and the reverse works within 1 s.
6. Given three open sessions, when I press ⌘2, then the second tab is shown and the others keep their connection.
7. Given iCloud Sync enabled on two Macs, when I add a machine on one, then it appears on the other within 1 minute (password available if iCloud Keychain is on).
8. Given an open session and an Anthropic API key in the Keychain, when I ask "what is on the screen?", then a text answer appears in the Claude Assistant Panel; when I ask for a task, then each proposed click or keystroke is shown and executed only after I confirm it.
9. Given a machine marked "Watch", when it stops answering for 2 minutes, then a macOS notification is posted; and one more when it comes back.
10. Given past sessions, when I open Session History, then I see each session with machine, start time, connection time (ms) and duration, and a 30-day summary.

SSH Machines & Terminal (post-1.0; one criterion per design goal):

11. Given the Library, when I add a machine of kind SSH (host `raspcorse`, user `vincent`; port 22 by default), then it appears with the terminal icon and behaves like any machine (search, groups, favourite, Watch with the TCP probe on its port, iCloud Sync, Session History records, Menu Bar Extra); a double-click opens a terminal as a tab of the Session Window, next to screen tabs, reachable with ⌘1…⌘9; a second Connect on it brings its tab forward.
12. Given a connected SSH session, when I run `htop`, `vim` and `tmux`, print 256-colour and truecolour output and wide characters (`你好`), resize the window, type AZERTY characters (⌥ combinations included), copy with ⌘C and paste with ⌘V, then everything renders and types correctly, the remote shell receives the new size, and the look is Ghostty's defaults (dark palette in dark mode, a Ghostty light theme in light mode, ⌘+ / ⌘− change the font size). Given `yes` or the `cat` of a 50 MB log, the app stays responsive and no output is lost.
13. Given three SSH machines set to password, key in `~/.ssh` (folder granted once) and imported key, when I connect to each, then each authenticates; the imported key and its password are on another Mac of the same Apple ID after iCloud sync, and that Mac connects without importing again; an encrypted key asks for its passphrase with "Remember in Keychain".
14. Given a server never seen, when I connect, then a sheet shows the algorithm and SHA256 fingerprint and asks to trust it; given a server whose key changed, then the connection is blocked with both fingerprints and there is no button to continue; ed25519, ECDSA and RSA (`rsa-sha2-256/512`) host keys all work; `~/.ssh/known_hosts` is never modified (read only, and only when the `~/.ssh` folder is granted).
15. Given a machine with a saved forward `localhost:8080 → localhost:80`, when its session is connected, then `http://localhost:8080` serves the remote port 80 and "Open in browser" opens it; the port listens on `127.0.0.1` and `::1` only; a port already in use shows an error on that forward only, the session stays up; the forward stops when the session ends and restarts after an automatic reconnect.
16. Given a connected SSH session, when I drop `config été.toml` on the terminal (or choose Upload File…), then a sheet proposes the remote home folder and the file arrives byte for byte under that exact name; an existing remote file asks before being overwritten; a missing folder is a clear error and leaves no partial file; Download File… saves a remote path where I choose; a server without SFTP shows a clear error.
17. Given an SSH session that drops after it was up, when the network is there, then one automatic attempt follows after 2 s, a separator line marks where the previous shell ended, and a second drop within 60 s, a passphrase that was not remembered or a host key that changed meanwhile ends in "Connection lost" or the changed-key block, never in a prompt loop or a silent trust.

## Open questions

1. **Anthropic VM scope** — Claude computer use environments expose VNC, so they are P0. I found no documented remote-screen access for the Claude Cowork VM or Claude Code cloud sandboxes. *Recommendation:* keep them in P2 behind a research spike (task T4.7), and decide after the spike. **Answered (T4.7, 2026-10-25): dropped.** The Cowork VM is a local headless Linux VM (Virtualization.framework) with no user-facing remote access ([support article](https://support.claude.com/en/articles/14479288)); Claude Code cloud sessions run in Anthropic-managed VMs reached only through claude.ai/code, `--cloud` and `--teleport` ([docs](https://code.claude.com/docs/en/claude-code-on-the-web)). A workaround would be unsupported and would weaken their isolation. Only the computer use reference container stays in scope; revisit only for a self-hosted environment profile ([docs](https://code.claude.com/docs/en/self-hosted-environments)).
2. **RFB implementation** — write the RFB client in Swift, or wrap libvncclient (GPL-2.0)? *Recommendation:* pure Swift. It avoids GPL constraints on a signed DMG, and ARD auth (security type 30) is small enough to implement.
3. **Apple authentication types beyond type 30** — recent macOS versions also offer newer Apple-specific security types. *Recommendation:* ship type 30 + VNC password in v1, then probe a macOS 26 host during T1.4 and record what it offers. *Probed 2026-10-19 on macOS 26 (minim6):* banner `RFB 003.889`, types `[30, 33, 36, 2, 35]`; type 30 uses generator 5 with a 4096-bit RFC 3526 group 16 prime. Types 30 and 2 are enough for v1; 33/35/36 stay out of scope.
4. **Claude Assistant cost and control** — computer use calls send screenshots, which costs tokens. *Recommendation:* on demand only (never continuous), confirmation required for every action, and a visible per-session token counter.
5. **iCloud Sync storage** — SwiftData + CloudKit imposes optional fields and no unique constraints. *Recommendation:* accept it, and deduplicate on `host:port` in code.
6. **Passwords across Macs** — stored as synchronizable Keychain items (iCloud Keychain), never in CloudKit. *Recommendation:* keep it that way.
7. **Distribution** — signed and notarized DMG with Sparkle updates, like Vincent's other apps, or the Mac App Store (sandbox + network entitlements)? *Recommendation:* DMG + Sparkle.
8. **Minimum OS** — macOS 15 Sequoia. *Recommendation:* keep it, for current SwiftData and the Observation framework.
9. **Name** — "RemoteDeck" is provisional. *Recommendation:* check for name conflicts on the Mac App Store and GitHub before the first release.
10. **Visual identity** — no brand color given. *Recommendation:* system accent color and SF Symbols, sober and dense (see DesignBrief).
11. **SSH terminal engine** (post-1.0) — Ghostty's terminal core (libghostty / libghostty-vt) or SwiftTerm? *Recommendation (design, Claude's call, accepted with the design):* preference order (1) the official libghostty-vt Swift package if released, (2) libghostty-vt through its C API with our own Metal/CoreText rendering, (3) full libghostty only if it can be fed bytes from an SSH channel, (4) SwiftTerm as the fallback. Zig in the build toolchain or a pinned prebuilt xcframework is accepted (Vincent, 2026-11-08). **Open until the T7.1 spike is reported and Vincent has read it**; only the terminal view waits for that.
12. **Bonjour discovery of `_ssh._tcp`** — out of the SSH v1 *(Claude's call: easy follow-up)*.
13. **Older clients** — v1.0.0 decodes an unknown machine kind as Mac ARD, so a Mac still on 1.0.0 would show SSH machines as Macs. Vincent (2026-11-08): every Mac updates through Sparkle, so no code guard; the release notes say to update every Mac before adding SSH machines.
14. **SSH sessions in the success metric** — decided (Claude's call, 2026-11-08): for an SSH session the "first frame" is the shell channel opening (`connectMillis` = click → shell open, `bytesReceived` = shell output bytes); SSH sessions count in the ≤ 5 s share like screen sessions.
