# Implementation plan — RemoteDeck

Owner/agent column: **Vincent** (decisions, Apple accounts, physical test machines), **executor** (code), **test-engineer** (tests), **verifier** (independent checks).

## Step 1 — project setup

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T1.1 Create git repo, `.gitignore`, Xcode project from `Templates/AppKitTemplate/`, SwiftUI app target, `RFBKit` Swift package | executor | TRD | Building empty app | `xcodebuild build` succeeds; app launches | — |
| T1.2 Signing, App Sandbox + `network.client`, hardened runtime, bundle ids (prod + `.dev`), iCloud/CloudKit capability | Vincent + executor | Apple Developer account | Configured targets | Debug build runs signed; the CloudKit container exists | T1.1 |
| T1.3 GitHub Actions CI running `xcodebuild test` | executor | T1.1 | `.github/workflows/ci.yml` | Green run on a PR | T1.1 |
| T1.4 Test hosts: enable Remote Management on one Mac; run the Anthropic computer use reference container in Docker (VNC 5900); record the security types each host offers | Vincent | — | Notes in `MEMORY.md` | Both endpoints reachable from the dev Mac | — |

**Checkpoint:** the app launches, CI is green, and both test endpoints answer on TCP 5900.

## Step 2 — data and authentication

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T2.1 SwiftData models Machine, MachineGroup, SessionRecord, AssistantAction; two `ModelConfiguration`s (synced / local) | executor | BackendSchema | `Packages/RemoteDeckCore` (`RemoteDeckSchemaV1`, `RemoteDeckSchema`) | Unit tests create, fetch and delete each model | T1.1 |
| T2.2 `KeychainStore` for KeychainCredential (sync and local items) | executor | BackendSchema | `RemoteDeckCore/KeychainStore.swift` | Tests: save/read/delete; the synchronizable flag is honored | T1.2 |
| T2.3 AppSettings wrapper over `UserDefaults` | executor | BackendSchema | `AppSettings` in `RemoteDeck/Localization/Localization.swift` | Defaults match BackendSchema | T1.1 |
| T2.4 Validation rules (host, port, name, unique `host:port`) | executor + test-engineer | BackendSchema › Data validation | `MachineValidator` + tests | All the rules have passing and failing tests | T2.1 |
| T2.5 RFB handshake: version, security negotiation, type 1, type 2 (VNC DES), type 30 (Apple DH: DH key exchange, MD5, AES-128-ECB credentials) | executor + test-engineer | RFC 6143, ARD auth notes | `RFBKit/Auth` | Authenticates against both T1.4 hosts; tests use recorded handshakes | T1.4 |

**Checkpoint:** handshake + auth succeed against the real Mac and the Anthropic container from a test harness; acceptance criterion 2b passes (wrong password → clean `authFailed`).

## Step 3 — main user path

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T3.1 RFB framebuffer protocol: SetPixelFormat, SetEncodings, update requests; decoders Raw, CopyRect, ZRLE, Tight; DesktopSize pseudo-encoding | executor | RFC 6143 | `RFBKit/Decoding` | Decoder tests on recorded frames pass; a 1080p full update decodes in < 30 ms | T2.5 |
| T3.2 Metal framebuffer view (AppKit) with dirty-rect texture upload and fit/actual scaling | executor | TRD, DesignBrief | `FramebufferView` | 120 Hz on a static desktop with CPU < 25 % (see the note below the table) | T3.1 |
| T3.3 Input: key mapping (keysyms, modifiers, keyboard capture, ⌃⌥⌘R release), pointer, scroll | executor | AppFlow › Navigation rules | `InputTranslator` | Typing, clicks and scrolling work on both hosts; ≤ 50 ms added latency | T3.2 |
| T3.4 Library Window + Machine Editor (create, edit, delete, search, test connection) | executor | AppFlow, DesignBrief | SwiftUI views | Acceptance criterion 1 passes | T2.1, T2.2, T2.4 |
| T3.5 Session Window: connecting overlay, error banners, reconnect, SessionRecord writing | executor | AppFlow › Session Window | `SessionWindow` | Acceptance criteria 2 and 2b pass; connect time recorded | T3.3, T3.4 |
| T3.6 Bonjour Discovery: `NWBrowser` on `_rfb._tcp` and `_net-assistant._udp`, Discovery Panel, pre-filled editor | executor | AppFlow › Discovery Panel | `DiscoveryService` + panel | Acceptance criterion 3 passes | T3.4 |
| T3.7 Anthropic VM Connect: `anthropicVM` kind (VNC auth, no user field, sparkles icon), tested on the reference container | executor | PRD, T1.4 | Kind support | Acceptance criterion 4 passes | T3.5 |
| T3.8 Onboarding Sheet + empty and blocked states | executor | AppFlow › First use | Views | Each blocked state in AppFlow can be reproduced and shows its message | T3.6 |

**Checkpoint:** run the main path end to end on both hosts; criteria 1–4 pass; record the p90 connect time over 10 connections.

**T3.2 done criterion, measurable form.** "120 Hz on a static desktop with CPU < 25 %" means:
(1) static desktop, no updates: **0 draws** (the display link is paused) and process CPU well under 25 % of one core;
(2) `-FramebufferDebug stream` (a 200 × 200 region repainted 120 times per second): draws at the display's maximum
rate (120 Hz on ProMotion, 60 Hz elsewhere) with CPU < 25 % of one core. Measured from `ps -o cputime=` deltas
over 5 s and the debug window's `draws/s` lines. Still to be measured live on an unlocked session (the first
measurement ran with the screen locked, so no frame could be drawn); 120 Hz needs a ProMotion display.

**T3.3 status.** Code-complete and unit-tested (`InputTranslator`, `InputSender`, `SessionInputController`; local latency measured in tests: NSEvent → messages ≈ 2–11 µs, enqueue → write on loopback p50 < 0.2 ms). The host verification (typing, clicks, scrolling, ⌘C/⌘V per modifier profile, on the test Mac and the Anthropic container) and the live ≤ 50 ms measurement move to T3.5 (test Mac) and T3.7 (container), once a Session Window wires `InputSender`. Product decisions closed (Vincent, 2026-10-21): release shortcut ⌃⌥⌘R; local allow-list ⌘1…⌘9 only; system combos taken by a session `CGEventTap` with the Accessibility permission, prompted once per run at the first capture (AppFlow › Keyboard capture, TRD › Input). Implemented and unit-tested (`ReleaseShortcut`, `LocalShortcut`, `SystemShortcut`, `SystemShortcutTapState`, `SystemShortcutTap`). Still to check live in T3.5: the tap on an unlocked session after granting access to the sandboxed app under its own identity, and the toolbar notice for `systemShortcutsAvailable`.

**T3.4 status.** Library Window and Machine Editor are implemented and unit-tested (`MachineLibraryModel`, `MachineEditorModel`, `TestConnectionFailure`; in-memory SwiftData, a fake password store and a fake `ConnectionTester`). Acceptance criterion 1 does **not** pass yet: "appears in the sidebar" is met (unit-tested); "the password is stored in the Keychain" is now satisfiable locally: the ad-hoc Debug build gets -34018 on the synchronizable save (measured 2026-10-22), so the password goes to a local Keychain item (Vincent's decision, 2026-10-22; verified live in the hosted tests with a throwaway service: `scope=local`, read back, deleted); T4.3 must call `migrateLocalPasswordsToSynced(machineIDs:)` once the entitlement exists; "a double-click opens a session" waits for the Session Window (T3.5): double-click, Return and Connect go through one inert `connect` entry point, and Connect/Discover are disabled. Still to check by hand: a real Test connection to the test Mac, and the windows on an unlocked session (`-LibraryDemo list|editor`, Debug only, in-memory sample data).

**T3.5 status.** Session Window implemented and unit-tested (`SessionModel`, `SessionManager`, `SessionFailure`; fakes for the connection, view, Keychain and clock; `RFBConnection.bytesReceived` with a loopback test). Connect (double-click, Return, toolbar, detail pane) opens one window per machine and brings an open one forward; overlay with Cancel/Esc; banners and Retry/Reconnect/Edit credentials per AppFlow › Session errors; SessionRecord per BackendSchema; teardown order per TRD › Input; capture pill and Accessibility notice in the toolbar; fit/actual toggle (⌥⌘S); session windows never restored and the Library Window presented at every launch. Seen on an unlocked session with `-LibraryDemo session` (fake sessions, no network; app windows captured one by one): the connecting overlay, a connected window with the capture pill and the Accessibility notice, the auth-failure banner. From the window list only (screen locked by then): two Connects on one machine give one window; after a `kill -9` with session windows open, the relaunch shows the Library Window and no session window. The Library-at-launch fix (`.defaultLaunchBehavior(.presented)`) is applied but its failing case (Library Window closed, then a killed run) is not verified. The SwiftUI wiring is not unit-tested (tests start at `SessionModel.close()`): Cancel/Esc, Disconnect and the close button closing the window, the dimmed screen taking the clicks, Edit credentials → Save → retry. Acceptance criteria 2 and 2b are **not** verified yet: they need the test Mac (minim6), with Vincent: first frame ≤ 5 s and connect time recorded, typing/clicks/scroll/⌘C⌘V per modifier profile, ⌘Tab through the tap after granting Accessibility, ≤ 50 ms added latency, wrong password → "Authentication failed" + Edit credentials without looping. Not built: actual-size panning, Ctrl-Alt-Del equivalents, the public-IP badge. Review fixes (2026-10-22): Esc reaches a Reconnect overlay's Cancel, the record is ended at the click (`beginClose`), held buttons are released after ⌃⌥⌘R, the stop waits at most 2 s for queued input, the credentials live only in the `open` task, shared `Machine.canConnect`; each with a test and a fail-proof.

## Step 4 — secondary features

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T4.1 Shared Clipboard: ClientCutText / ServerCutText (Latin-1), plus UTF-8 through the Extended Clipboard pseudo-encoding when the server supports it | executor | RFC 6143 | Clipboard bridge | Acceptance criterion 5 passes on both hosts | T3.5 |
| T4.2 Session Tabs: native window tabs, ⌘1…⌘9, independent connections | executor | AppFlow | Tabbing | Acceptance criterion 6 passes | T3.5 |
| T4.3 iCloud Sync: CloudKit-backed configuration for Machine/MachineGroup, toggle in Settings Window, duplicate merge | executor | BackendSchema | Sync | Acceptance criterion 7 passes between two Macs | T2.1, T1.2 |
| T4.4 Claude Assistant: Settings Window API key, Messages API client with the computer use tool, screenshot from the framebuffer, action → RFB events after confirmation, token counter, Claude Assistant Panel | executor (model=opus) | TRD, AppFlow › Claude Assistant Panel, current Anthropic API docs | `ClaudeAssistant` + panel | Acceptance criterion 8 passes; no action is sent without confirmation (test) | T3.5 |
| T4.5 Status Notifications: `ReachabilityMonitor` (TCP probe every 60 s), UserNotifications, click → connect | executor | TRD › Performance | Monitor | Acceptance criterion 9 passes (unplug the test Mac) | T3.4 |
| T4.6 Session History View + Menu Bar Extra recents + CSV export + 30-day summary | executor | AppFlow, BackendSchema | Views | Acceptance criterion 10 passes | T3.5 |
| T4.7 Spike: Cowork VM and Claude Code cloud sandbox remote access (P2) | Vincent + document-specialist | Anthropic docs | Short decision note in `MEMORY.md` | Documented yes/no and an access method for each | — |

**Checkpoint:** criteria 5–10 pass; Vincent answers PRD open questions 1 and 4 with the spike result and the observed token costs.

## Step 5 — quality

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T5.1 Error handling: dropped connections, sleep/wake, network change (auto-reconnect once) | executor | AppFlow › Empty and blocked states | Fixes | Unplug-network and sleep/wake tests behave as specified | Step 4 |
| T5.2 Accessibility pass: VoiceOver labels, keyboard navigation, Reduce Motion | executor + verifier | DesignBrief › Accessibility | Fixes | Accessibility Inspector audit clean on every screen | Step 4 |
| T5.3 Security review: secrets only in Keychain, no screenshots on disk, public-IP warning, sandbox entitlements minimal | security-reviewer | TRD › Security | Report + fixes | No high/critical findings | Step 4 |
| T5.4 Performance: Instruments (Time Profiler, Metal) on a 4K session | executor | TRD › Performance | Fixes | TRD performance targets met | Step 4 |
| T5.5 Fuzz the RFB parser with malformed server messages | test-engineer | RFBKit | Fuzz tests | No crash after 1M inputs | T3.1 |

**Checkpoint:** all criteria re-run; an independent verifier signs off.

## Step 6 — go-live

| Task | Owner or agent | Inputs | Deliverable | Done criterion | Depends on |
|---|---|---|---|---|---|
| T6.1 Test plan run on a clean Mac (fresh install, onboarding, sync from the existing library) | verifier | PRD acceptance criteria | Checklist | All P0/P1 criteria pass | Step 5 |
| T6.2 Deploy the CloudKit schema to production | Vincent | CloudKit Console | Production schema | Release build syncs | T4.3 |
| T6.3 Release: version + build bump, `Scripts/release.sh`, notarize, staple, appcast, GitHub Release | executor + Vincent | `macos-app-release` skill | DMG in `release/` | `spctl -a -t exec -vv` accepted; Sparkle update works from the previous build | T6.1, T6.2 |
| T6.4 Rollback: keep the previous DMG + appcast entry; Sparkle can ship the previous version as a newer build number | Vincent | — | Documented procedure | Procedure tested once | T6.3 |
| T6.5 Monitoring: Session History 30-day summary reviewed (success metric) | Vincent | Session History | Review note | Metric checked 30 days after release | T6.3 |

**Checkpoint:** v1.0 installed from the DMG on all of Vincent's Macs; the success metric review is scheduled.

## Traceability

| Feature | Priority | Screens (AppFlow) | Entities (BackendSchema, or "—" if none stored) | Tasks |
|---|---|---|---|---|
| Machine Library | P0 | Library Window, Machine Editor, Menu Bar Extra | Machine, MachineGroup, KeychainCredential | T2.1, T2.2, T2.4, T3.4 |
| Screen Session | P0 | Session Window | Machine, KeychainCredential, SessionRecord | T2.5, T3.1, T3.2, T3.3, T3.5 |
| Bonjour Discovery | P0 | Discovery Panel, Onboarding Sheet | Machine | T3.6, T3.8 |
| Anthropic VM Connect | P0 | Machine Editor, Session Window | Machine, KeychainCredential | T1.4, T3.7 |
| Shared Clipboard | P1 | Session Window, Settings Window | Machine, AppSettings | T4.1 |
| Session Tabs | P1 | Session Window | — | T4.2 |
| iCloud Sync | P1 | Settings Window, Onboarding Sheet | Machine, MachineGroup, KeychainCredential, AppSettings | T4.3 |
| Claude Assistant | P1 | Claude Assistant Panel, Settings Window | AssistantAction, KeychainCredential, SessionRecord, AppSettings | T4.4 |
| Status Notifications | P1 | Library Window, Settings Window | Machine, AppSettings | T4.5 |
| Session History | P1 | Session History View, Menu Bar Extra | SessionRecord | T4.6 |
