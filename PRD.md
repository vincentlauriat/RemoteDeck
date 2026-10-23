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
| File Transfer | Drag files to and from a remote Mac | P2 |
| Cowork & Cloud Sandbox Access | Reach the Claude Cowork VM and Claude Code cloud sandboxes if a documented access path exists | P2 |

## Out of scope for v1

- **ARD fleet management** (package deployment, reports, Unix command broadcast, asset inventory): this is what makes ARD heavy, and it is not needed for one-user screen access.
- **Audio forwarding**: not part of standard RFB, and rarely needed.
- **Access over the Internet without a VPN** (relay or NAT traversal): it needs server infrastructure. Use Tailscale or an existing VPN instead.
- **Apple's "High Performance" Screen Sharing mode** (macOS 14+): proprietary protocol, no public specification.
- **Multi-user, accounts, roles**: solo tool.

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

## Open questions

1. **Anthropic VM scope** — Claude computer use environments expose VNC, so they are P0. I found no documented remote-screen access for the Claude Cowork VM or Claude Code cloud sandboxes. *Recommendation:* keep them in P2 behind a research spike (task T4.7), and decide after the spike.
2. **RFB implementation** — write the RFB client in Swift, or wrap libvncclient (GPL-2.0)? *Recommendation:* pure Swift. It avoids GPL constraints on a signed DMG, and ARD auth (security type 30) is small enough to implement.
3. **Apple authentication types beyond type 30** — recent macOS versions also offer newer Apple-specific security types. *Recommendation:* ship type 30 + VNC password in v1, then probe a macOS 26 host during T1.4 and record what it offers. *Probed 2026-10-19 on macOS 26 (minim6):* banner `RFB 003.889`, types `[30, 33, 36, 2, 35]`; type 30 uses generator 5 with a 4096-bit RFC 3526 group 16 prime. Types 30 and 2 are enough for v1; 33/35/36 stay out of scope.
4. **Claude Assistant cost and control** — computer use calls send screenshots, which costs tokens. *Recommendation:* on demand only (never continuous), confirmation required for every action, and a visible per-session token counter.
5. **iCloud Sync storage** — SwiftData + CloudKit imposes optional fields and no unique constraints. *Recommendation:* accept it, and deduplicate on `host:port` in code.
6. **Passwords across Macs** — stored as synchronizable Keychain items (iCloud Keychain), never in CloudKit. *Recommendation:* keep it that way.
7. **Distribution** — signed and notarized DMG with Sparkle updates, like Vincent's other apps, or the Mac App Store (sandbox + network entitlements)? *Recommendation:* DMG + Sparkle.
8. **Minimum OS** — macOS 15 Sequoia. *Recommendation:* keep it, for current SwiftData and the Observation framework.
9. **Name** — "RemoteDeck" is provisional. *Recommendation:* check for name conflicts on the Mac App Store and GitHub before the first release.
10. **Visual identity** — no brand color given. *Recommendation:* system accent color and SF Symbols, sober and dense (see DesignBrief).
