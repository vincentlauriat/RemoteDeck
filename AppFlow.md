# App flow — RemoteDeck

## Entry points

- Launching the app (Dock, Spotlight): opens the Library Window, at every launch (also after a killed run). Session Windows are never restored at launch: reopening one would reconnect to a host without the user asking.
- Menu Bar Extra: quick-connect list of favorite and recent machines.
- URL scheme `remotedeck://connect?id=<machine-id>`, plus `vnc://host` URLs registered as a handler: opens a session directly. *(assumption)*
- Status Notifications (T4.5): clicking a notification brings the app forward with the Library Window, the machine selected; an "online again" notification also opens a session on that machine (the Connect path: its tab is selected if already open). A machine deleted since is ignored.
- First launch: Onboarding Sheet over the Library Window, until it is finished or skipped (AppSettings `onboardingCompleted`); never under the hosted tests, `-FramebufferDebug` or a `-LibraryDemo` mode other than `onboarding`. No menu item reopens it.

## Screen list

| Screen | Purpose | Data needed |
|---|---|---|
| Onboarding Sheet | Explain the app, ask for local network and notification permissions, offer to enable iCloud Sync | AppSettings |
| Library Window | Sidebar with Favorites (pinned; a favorite is listed there only, so each machine has one row), groups (by sort order, then name; empty groups shown unless searching) and ungrouped Machines; search; toolbar (add, discover, connect) | Machine, MachineGroup |
| Machine Editor | Create or edit a machine: name, kind (Mac ARD / VNC / Anthropic VM), host, port, user, password, group (or "New Group…"), watch, favorite, scaling, shared clipboard (new machines default to AppSettings `defaultSharedClipboard`) | Machine, MachineGroup, KeychainCredential, AppSettings |
| Discovery Panel | Sheet listing the hosts found on the LAN through Bonjour (`_rfb._tcp` and `_net-assistant._udp`, merged per host; this Mac is left out), with "Add" per row | Live Bonjour results, Machine (for "Already added") |
| Session Window | Remote framebuffer with tabs, toolbar (scaling, clipboard, Ctrl-Alt-Del equivalents, Claude, disconnect) | Machine, KeychainCredential, SessionRecord |
| Claude Assistant Panel | Inspector beside the Session Window (320 pt): token counter and New Conversation at the top, transcript (prompts, progress notes, answers, actions with Confirm/Skip), prompt field with Ask/Stop at the bottom | AssistantAction, KeychainCredential, SessionRecord.assistantTokens |
| Session History View | Table of past sessions and a 30-day summary | SessionRecord |
| Settings Window | General, iCloud Sync, Claude (API key, model), Notifications, Shared Clipboard default | AppSettings, KeychainCredential |
| Menu Bar Extra | Favorites and recents, "Open Library" | Machine, SessionRecord |

## Main path

`Library Window -> double-click machine -> Session Window (connecting) -> first frame -> remote control active`

First-time variant: `Onboarding Sheet -> Discovery Panel -> Add -> Machine Editor -> Save -> Library Window -> double-click -> Session Window`

## Alternative paths

- **Cancel connection:** press Esc, or the "Cancel" button while connecting. The tab closes and the SessionRecord is saved with outcome `cancelled`.
- **Edit credentials after failure:** the auth error banner shows an "Edit credentials" button, which opens the Machine Editor; after saving, the session retries.
- **Back to library:** ⌘0 brings the Library Window forward. Sessions stay connected.
- **Skip onboarding:** the "Later" button (Esc) on the first two pages; the sheet dismissed any other way (Library Window closed) counts as Later. The last page has no Esc: "Not now" is the way out there. Permissions are requested when first needed, and the Discovery Panel does not open. Quitting the app before the sheet ends records nothing: it shows again at the next launch.
- **Close a tab:** ⌘W disconnects that session only. Closing the last tab closes the Session Window.

## Action details

### Library Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Double-click / Return / toolbar "Connect" / detail pane "Connect" | Machine has host and port | Row spinner | A new tab of the Session Window opens and is selected (one tab per machine); a machine whose tab is already open: that tab is selected and comes forward, no second connection | — (errors are shown in the session) | Session Window |
| Add machine | ⌘N / "+" | — | — | Empty editor | — | Machine Editor |
| Discover | ⌘D / toolbar | — | — | Panel opens | Local network permission denied → blocked state | Discovery Panel |
| Search | ⌘F, type | — | — | List filtered live on name/host (case- and accent-insensitive); empty sections hidden | "No results" | — |
| Delete | ⌫ on selection, or Delete… in the row's context menu | Confirm dialog naming the machine | — | Row removed, Keychain item removed | Keychain delete failed → alert with the status (the machine stays deleted) | — |
| Delete group | Delete Group… in the section header's context menu | Confirm dialog naming the group | — | Section removed; its machines move to Machines (ungrouped) | — | — |

### Machine Editor

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save | ⌘S / "Save" | Name 1–64 chars; host is a valid hostname/IPv4/IPv6; port 1–65535 (5900 by default); user required for Mac ARD; password optional for VNC and Anthropic VM (placeholder "Optional"; empty means no authentication, security type 1); no duplicate `host:port`; new group name 1–40 chars, unique | — | Sheet closes, row selected | Inline field error in red under the field. Keychain refusal → error under the password field, nothing saved; -34018 is not a refusal: saved to a local item, and the editor then notes "Password stored on this Mac only until iCloud Keychain is available" (BackendSchema › KeychainCredential) | Library Window |
| Test connection | "Test" button | Same as Save | "Testing…" spinner (timeout 5 s) | Green check: "Reachable, auth OK"; the connection is closed at once | "Unreachable — check VPN or network" (network error) / "Unreachable — no answer within 5 s" / "The server closed the connection" / "Connection refused by the server" (RFB-level, with its reason) / "Authentication failed" / "Unsupported security type (n, …)" / "This Mac needs a user name and password" / "This server needs a password" / "User name or password too long (63 bytes max)" / "Not a VNC / Screen Sharing server" / "Unexpected response from the server" | — |
| Cancel | Esc | — | — | Sheet closes without changes; a running test is cancelled | — | Library Window |

Anthropic VM: no user field (a user name typed under another kind is not saved), and a note under the password: "Leave empty when the VNC server has no password: Anthropic's reference computer use container has none (x11vnc -nopw)."

Changing kind, host, port, user or password clears a Test result (and cancels a running test): it no longer applies to the fields.

### Discovery Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Browse | Panel opens (browsing stops when it closes) | — | "Searching…" until the first row | Rows: name, host (`:port` when not 5900), service types (Screen Sharing · Remote Management), kind symbol; rows come and go live | No result after 10 s → empty state (Retry). Local Network access denied → blocked state; it clears by itself once access is granted. A browser failure with nothing listed → "Bonjour discovery failed", a localized hint and the error code, with Retry. Rows always win: if one service type fails (or is denied) while the other lists hosts, the rows stay and a note under the list says some machines may be missing (with Retry, or Open System Settings) | — |
| Add | "Add" on a row | Not already in library: same `host:port` as a machine (MachineValidator key); otherwise the row is greyed with "Already added" | — | Panel closes; Machine Editor (new machine) pre-filled: kind (Mac ARD when the host advertises Remote Management, else VNC), name (cut to 64 chars), host (`<name>.local`), port (the `_rfb._tcp` port, else 5900), user name empty | — | Machine Editor |
| Close | Esc / "Close" | — | — | Sheet closes | — | Library Window |

### Session Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Tab opens | — | "Connecting to <name>…" overlay with Cancel (Esc), until the first framebuffer update; the screen behind it takes no click | Framebuffer shown, overlay goes, keyboard captured | Banner (see Session errors below): "Unreachable…" (Retry) / "Authentication failed" (Edit credentials) / "Connection lost" (Reconnect) | — |
| Release keyboard | ⌃⌥⌘R while captured | — | — | Capture off: every key, modifier and button held on the remote is released; the pill disappears | — | — |
| Capture keyboard | Click in the remote screen | — | — | Capture on; the first time in an app run without Accessibility access, the system prompt (see Keyboard capture) | — | — |
| Toggle scaling | ⌘⌥S (keyboard released) / toolbar button | — | — | Fit-to-window ↔ 1:1, for this session only (Machine.scalingMode is the starting mode and is not changed) | — | — |
| Send clipboard | Automatic while Shared Clipboard is on and the Session Window is key: the local text goes to the remote when the window becomes key and when the local clipboard changes while it stays key (checked every 0.5 s), so ⌘V (or a remote Paste menu) pastes it | Plain text ≤ 1 MiB (UTF-8 bytes); items marked concealed/transient/auto-generated (password managers) are never sent | — | Text pasted remotely | Toast (bottom-center, 2 s): "Clipboard too large"; nothing sent | — |
| Receive clipboard | Text copied on the remote (Shared Clipboard on) | Plain text ≤ 1 MiB | — | Local clipboard holds the text (also when the window is not key) | — (too large or malformed: ignored) | — |
| Toggle Shared Clipboard | Toolbar `doc.on.clipboard` toggle | — | — | On/off for this session only (Machine.sharedClipboard is the starting value and is not changed); off, nothing is read, written or sent | — | — |
| Switch tab | ⌘1…⌘9 / click tab | — | — | Tab shown | — | — |
| Open Claude | Toolbar sparkle toggle (always) / ⌘K (keyboard released: while captured, ⌘K goes to the remote like every combo but ⌘1…⌘9) | — | — | Claude Assistant Panel opens with the prompt field focused, which takes the keyboard from the remote (capture off, everything held released) | No key → "Add your API key in Settings to use Claude" + "Open Settings…" | Claude Assistant Panel |
| Disconnect | ⌘W (keyboard released) / toolbar "Disconnect" / window close button | — | — | Tab closes, SessionRecord saved | — | Library Window if no tab is left |

#### Session errors (T3.5)

The banner sits at the top of the Session Window (32 pt, red bar, one button); the last frame stays dimmed behind it and takes no click. Copy for connection failures is the Machine Editor's Test copy, except the timeout.

| Cause | Banner | Button | SessionRecord.outcome |
|---|---|---|---|
| Wrong credentials, missing user name or password, credential too long | "Authentication failed" (with the server's reason) / the Test copy for the missing or too-long credential | Edit credentials (Machine Editor sheet; Save retries) | `authFailed` |
| Password unreadable from the Keychain (nothing is sent) | "The password could not be read from the Keychain (status)" | Edit credentials | `authFailed` |
| Network error, refused, not an RFB server, unsupported security type, protocol error | Test copy ("Unreachable — check VPN or network"…) | Retry | `unreachable` |
| No answer within 10 s (connect + handshake) | "Unreachable — no answer within 10 s" | Retry | `unreachable` |
| The session ends after authentication without the user asking (server gone, network, malformed data) | "Connection lost" | Reconnect | `dropped` |
| Cancel / Esc / window closed before the first frame | — (window closes) | — | `cancelled` |


### Status Notifications (T4.5)

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Watch | "Watch (notify when offline)" toggle in the Machine Editor, then Save | — | Grey dot, "Checking…", until the first answer | Green dot "Online" / red dot "Offline — not answering" in the row and the detail pane (a machine not watched has no dot in the row; the detail pane says "Not watched") | Notifications not allowed: a note under the toggle ("Allow notifications" button when not asked yet, a pointer to System Settings › Notifications when denied, or "turned off in Settings"); the dot works anyway | — |
| Offline notification | A watched machine seen online fails 2 probes in a row | Settings › Status notifications on, macOS permission granted (never requested here) | — | "<name> is offline" — "The machine no longer answers on the network." | — | — |
| Back online notification | First answer after offline | Same | — | "<name> is back online" — "Click to connect." (replaces the offline one in Notification Center) | — | — |
| Click a notification | Banner or Notification Center | Machine still in the library | — | App forward, Library Window opened with the machine selected; "back online" also connects | Machine deleted: the app comes forward, nothing else | Library Window / Session Window |

Rules:
- Probe: a TCP connect to the machine's host and port, closed at once (no RFB handshake, no credentials), every 60 s per watched machine, 5 s timeout, at most 4 at once.
- The first answer after Watch is turned on (or after launch) sets the dot without a notification: a machine already down when watched shows red and posts nothing; only online → offline and offline → online notify. Turning Watch off or deleting the machine stops its probe at once.
- A machine with a connected session counts as online (no probe), and turns green again without a "back online" notification; a connecting session skips the round.
- Turning Watch off or deleting the machine also removes its delivered notification from Notification Center. A Watch or address change takes effect wherever it is saved (the Library, or the Machine Editor opened from a session's Edit credentials with the Library Window closed).
- Local Network privacy: the first probe of a watched LAN machine may bring the system's Local Network prompt (as the Discovery Panel's first browse does). While access is off, the machine's dot is grey with "Local network access is off (System Settings › Privacy & Security › Local Network)": never red, no notification.
- No network on this Mac: probes stop, every watched dot turns grey ("No network on this Mac"), earlier failures are forgotten; they resume when the network is back. Sleep stops them too; after wake they wait 15 s, even if the network comes and goes meanwhile.
- Timing: the offline notification comes 60–120 s after the port starts refusing (Screen Sharing turned off), 70–130 s after the machine stops answering at all (unplugged: two 5 s timeouts; the 60 s are counted from the end of each probe).
- Notifications show while the app is frontmost too (banner, Notification Center, sound).

### Claude Assistant Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Ask | Return in the prompt field / "Ask" | Prompt 1–2000 chars ("At most 2000 characters."); API key present; session connected ("The session is not connected.") | "Claude is looking…" + pulsing purple dot; a screenshot of the framebuffer goes with the prompt | Progress notes, a text answer and/or proposed actions. Screenshot, zoom, cursor position and wait run without asking (rows marked ✓) | API error message (invalid key, rate limited, overloaded, server error, no connection, conversation too large…), with Retry (same request again). Refusal: "Claude declined this request." + the API's explanation. Cut off (`max_tokens`): "Claude's answer was cut off. Ask again to continue." | — |
| Confirm action | "Confirm" (⌘Return, keyboard released: the capture is released when an action waits). Enabled 400 ms after the proposal appears; a key repeat or a click meant for an earlier proposal does nothing | Session still connected | The proposal is highlighted in purple in the panel and as purple rings on the framebuffer; then "Running the action…" | Action sent through the session's input; Claude continues (often with a new screenshot) | "Session disconnected — actions cancelled" | — |
| Skip | "Skip" | — | — | The action is not run, the rest of Claude's turn is not run either ("Not run"); Claude is told and answers | — | — |
| Stop | "Stop" (⌘., keyboard released) | — | "Stopping…" (no Ask) until the loop has ended | The request in flight and the loop stop ("Stopped."); pending actions are marked `cancelled`; Claude hears of it with the next Ask | — | — |
| New conversation | Toolbar of the panel (`square.and.pencil`) | Not busy | — | Transcript and conversation cleared; the token counter keeps the session total | — | — |

### Session History View

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Open | Menu Window › Session History (⌘Y) | — | — | Table sorted by date, newest first | — | — |
| Reconnect | Double-click a row | Machine still exists | — | Session Window tab | "Machine deleted" | Session Window |
| Export CSV | "Export…" | — | — | Save panel → CSV file | Write error alert | — |

### Settings Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save API key | Paste the key, "Save" (or Return). Typing only edits a draft: nothing is written before Save | Starts with `sk-ant-` ("An Anthropic API key starts with sk-ant-.", nothing sent), then a test request (`GET /v1/models`, no tokens billed) | "Checking…" | "Key valid" ✓; the field is emptied and the section says "An API key is stored." (the key is never shown back) | "Invalid key" (401/403); "The key could not be checked, nothing was saved: …" (network, rate limit, server); Keychain refusal with its status. Nothing is saved in any of them | — |
| Remove API key | "Remove Key" | A key is stored | — | "Key removed." | Keychain error with its status | — |
| Toggle iCloud Sync | Switch | iCloud account signed in | "Syncing…" | Last-sync timestamp shown | "iCloud unavailable" | — |
| Toggle notifications | "Status notifications" switch (Settings › Notifications, AppSettings `notificationsEnabled`, on by default) | — | — | Off: no Status Notification is posted (probes and dots go on) | Under the switch, the macOS permission: not asked yet → "Allow notifications" (the system prompt, on that click only); denied → "Notifications are off in System Settings › Notifications" (text pointer, no deep link); request failed → Retry; allowed → "Notifications allowed" | — |

## Navigation rules

- One Library Window, one Session Window containing native macOS window tabs (one per open machine, each with its own connection), and one Settings Window (⌘,). A tab can be moved to its own window or windows merged back (Window menu); a new session joins the frontmost Session Window (visible and not minimised; else the one opened last). The tab bar's "+" brings the Library Window forward, where the next machine is picked. Switching tabs, minimising and full screen never disconnect; only closing a tab does.
- ⌘0 Library, ⌘1…⌘9 session tabs (Window › Session Tabs; the physical top-row keys, so AZERTY's ⌘& ⌘é… too, captured or not), ⌘K Claude Assistant Panel, ⌘Y Session History View.
- Only the selected tab of the key window captures the keyboard, runs the system-shortcut tap and reads the local clipboard; leaving a tab releases every key held on its remote, and a background tab stops drawing but stays connected and up to date.
- While a session has the keyboard captured, key combos go to the remote machine, with the exceptions in Keyboard capture below.
- Deep links open in a new tab of the existing Session Window.

### Keyboard capture

Shortcuts match the physical key (key code) and the exact set of ⇧⌃⌥⌘, so they work with any layout (AZERTY included); Caps Lock does not matter.

| While captured | What happens | Why |
|---|---|---|
| ⌃⌥⌘R | Releases the capture; never sent to the remote | Not used by macOS or common apps. (The Force Quit combo, which macOS never hands to apps, was the first choice.) |
| ⌘1…⌘9 (top-row digit keys) | Stay local: switch session tab | The only local allow-list (`LocalShortcut`); the tab left sees ⌘ go down and up, nothing else; the tab selected sees nothing of the combo |
| ⌘Tab, ⌘⇧Tab, ⌘Space, ⌥⌘Space, ⌃Space, ⌃⌥Space, ⌃↑ ⌃↓ ⌃← ⌃→ (and with ⇧), ⌘⇧3/4/5, ⌃⌘⇧3/4, ⌥⌘D | Sent to the remote, swallowed locally, **only with Accessibility access** (`SystemShortcut`). Without it, macOS acts on them locally as usual | macOS takes them before the app (app switcher, Spotlight, input sources, Mission Control and Spaces, screenshots, Dock hiding) |
| Force Quit, F-key hotkeys (F11, ⌃F1…⌃F8, brightness) | Stay local | Force Quit is the way out if the app hangs; the top row sends media keys by default |
| Everything else (⌘W, ⌘Q, ⌘K, ⌘V, ⌘⌥S…) | Sent to the remote | The Session Window's own shortcuts work after ⌃⌥⌘R, or from the toolbar and menus |

Capture states:

| State | Enters when | Keys | Leaves when |
|---|---|---|---|
| Captured | The session view is first responder of the key window and the user has not released it (a new session starts captured) | To the remote, as above | ⌃⌥⌘R → Released; another window, view or app takes focus → Paused |
| Paused | Focus left while captured | Local | Focus comes back → Captured |
| Released | ⌃⌥⌘R | Local (menus work) | Click in the remote screen → Captured |

Leaving Captured always releases, on the remote, every key, modifier (including the ⌃⌥⌘ of ⌃⌥⌘R) and mouse button still held.

Accessibility prompt flow (system combos):
1. Never at launch. The first time a capture starts in an app run without Accessibility access, the app shows the system prompt once ("RemoteDeck would like to control this computer using accessibility features"), then keeps working with the local shortcuts only.
2. While access is missing and the keyboard is captured, the toolbar shows a button "System shortcuts need Accessibility access — Open Settings" next to the capture pill (T3.5); it opens System Settings › Privacy & Security › Accessibility. No further prompt in that run.
3. Once granted, the next capture (click, or focus coming back) takes the system combos, without a restart *(expected; not yet verified live)*. If access is revoked while captured, the app drops the tap as soon as macOS announces the change; revoking with a tap active is a known macOS risk (system input can become unresponsive, Apple bug FB24619068, TRD › Input), so releasing the capture (⌃⌥⌘R) first is safer.
## Empty and blocked states

Each state can be reproduced: by a hosted test through its model, or with a Debug `-LibraryDemo` mode (`empty`, `store-error`, `discovery-empty`, `discovery-blocked`, `discovery-failed`; `session` for the auth-failure banner; `watch` for the status dots and Status Notifications: three watched sample machines on fake probes every 3 s, "NAS" going offline and back, notifications printed on stderr instead of posted). States marked with a later task are not built yet.

- **Library in memory** (the on-disk store could not be opened): persistent orange banner across the bottom of the Library Window (at the top, the sidebar's search field covered it), "The library could not be opened — The library runs in memory: nothing you do now is saved, passwords included."
- **Empty library:** illustration-free message "No machines yet", with two buttons: "Discover on network" (opens the Discovery Panel) and "Add manually".
- **Discovery found nothing:** "No Mac with Screen Sharing found. Enable it in System Settings › General › Sharing on the remote Mac.", with a Retry button.
- **Local network permission denied:** "Local network access is off", explanation plus a button that opens System Settings › Privacy & Security › Local Network. Detected when a browser waits with kDNSServiceErr_PolicyDenied (TN3179); the browser keeps running, so granting access brings the rows without Retry.
- **Offline / host unreachable:** session banner "Unreachable — check VPN or network", with a Retry button. A watched machine that stops answering shows a red dot ("Offline — not answering") in the sidebar and the detail pane; grey while its status is not known yet or when this Mac has no network (T4.5).
- **No Anthropic API key** (T4.4): the Claude Assistant Panel shows "Add your API key in Settings to use Claude", with an "Open Settings…" button. All Claude Assistant Panel states can be reproduced with the Debug `-LibraryDemo assistant` mode (one session, the panel open, an in-memory demo key and scripted API answers: a progress note, an answer, a click and a typing proposal) or by the hosted `AssistantModelTests`.
- **iCloud signed out** (T4.3): the sync section shows "Sign in to iCloud to sync your library". The app keeps working locally.
- **Empty Session History** (T4.6): "Sessions you open will appear here."

## First use

No account creation. Onboarding Sheet in 3 steps:
1. Welcome and what the app does.
2. Permissions: Local Network (explained only: the system prompt comes with the first Bonjour browse, from the Discovery Panel at the end) and Notifications ("Allow notifications" button; the request is sent on that click only, never at launch or on a page change; the answer is shown: allowed, off with a pointer to System Settings › Notifications, or failed).
3. "Sync your library with iCloud?" (Enable / Not now). Until iCloud Sync ships (T4.3), Enable is disabled with "iCloud Sync comes in a later version", and nothing is turned on. "Not now" ends the sheet, then the Discovery Panel opens automatically.

Finishing or skipping sets `onboardingCompleted` once; the sheet is never shown again. Quitting before either shows it again at the next launch. On the notification row, a failed request offers Retry; a "no" is final there (System Settings › Notifications).
