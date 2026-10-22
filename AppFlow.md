# App flow — RemoteDeck

## Entry points

- Launching the app (Dock, Spotlight): opens the Library Window, at every launch (also after a killed run). Session Windows are never restored at launch: reopening one would reconnect to a host without the user asking.
- Menu Bar Extra: quick-connect list of favorite and recent machines.
- URL scheme `remotedeck://connect?id=<machine-id>`, plus `vnc://host` URLs registered as a handler: opens a session directly. *(assumption)*
- Status Notifications: clicking an "online again" notification opens a session on that machine.
- First launch: Onboarding Sheet over the Library Window.

## Screen list

| Screen | Purpose | Data needed |
|---|---|---|
| Onboarding Sheet | Explain the app, ask for local network and notification permissions, offer to enable iCloud Sync | AppSettings |
| Library Window | Sidebar with Favorites (pinned; a favorite is listed there only, so each machine has one row), groups (by sort order, then name; empty groups shown unless searching) and ungrouped Machines; search; toolbar (add, discover, connect) | Machine, MachineGroup |
| Machine Editor | Create or edit a machine: name, kind (Mac ARD / VNC / Anthropic VM), host, port, user, password, group (or "New Group…"), watch, favorite, scaling, shared clipboard (new machines default to AppSettings `defaultSharedClipboard`) | Machine, MachineGroup, KeychainCredential, AppSettings |
| Discovery Panel | List of Bonjour services found on the LAN, with "Add" per row | Live Bonjour results |
| Session Window | Remote framebuffer with tabs, toolbar (scaling, clipboard, Ctrl-Alt-Del equivalents, Claude, disconnect) | Machine, KeychainCredential, SessionRecord |
| Claude Assistant Panel | Inspector beside the Session Window: prompt field, answers, proposed actions with Confirm/Skip, token counter | AssistantAction, KeychainCredential |
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
- **Skip onboarding:** the "Later" button. Permissions are requested when first needed.
- **Close a tab:** ⌘W disconnects that session only. Closing the last tab closes the Session Window.

## Action details

### Library Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Double-click / Return / toolbar "Connect" / detail pane "Connect" | Machine has host and port | Row spinner | Session Window opens (one window per machine until Session Tabs, T4.2); a machine whose window is already open: that window comes forward, no second connection | — (errors are shown in the session) | Session Window |
| Add machine | ⌘N / "+" | — | — | Empty editor | — | Machine Editor |
| Discover | ⌘D / toolbar | — | — | Panel opens | Local network permission denied → blocked state | Discovery Panel |
| Search | ⌘F, type | — | — | List filtered live on name/host (case- and accent-insensitive); empty sections hidden | "No results" | — |
| Delete | ⌫ on selection, or Delete… in the row's context menu | Confirm dialog naming the machine | — | Row removed, Keychain item removed | Keychain delete failed → alert with the status (the machine stays deleted) | — |
| Delete group | Delete Group… in the section header's context menu | Confirm dialog naming the group | — | Section removed; its machines move to Machines (ungrouped) | — | — |

### Machine Editor

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save | ⌘S / "Save" | Name 1–64 chars; host is a valid hostname/IPv4/IPv6; port 1–65535; user required for Mac ARD; no duplicate `host:port`; new group name 1–40 chars, unique | — | Sheet closes, row selected | Inline field error in red under the field. Keychain refusal → error under the password field, nothing saved; -34018 is not a refusal: saved to a local item, and the editor then notes "Password stored on this Mac only until iCloud Keychain is available" (BackendSchema › KeychainCredential) | Library Window |
| Test connection | "Test" button | Same as Save | "Testing…" spinner (timeout 5 s) | Green check: "Reachable, auth OK"; the connection is closed at once | "Unreachable — check VPN or network" (network error) / "Unreachable — no answer within 5 s" / "The server closed the connection" / "Connection refused by the server" (RFB-level, with its reason) / "Authentication failed" / "Unsupported security type (n, …)" / "This Mac needs a user name and password" / "This server needs a password" / "User name or password too long (63 bytes max)" / "Not a VNC / Screen Sharing server" / "Unexpected response from the server" | — |
| Cancel | Esc | — | — | Sheet closes without changes; a running test is cancelled | — | Library Window |

Changing kind, host, port, user or password clears a Test result (and cancels a running test): it no longer applies to the fields.

### Discovery Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Browse | Panel opens | — | "Searching…" for up to 3 s | Rows: name, host, service type | No result after 10 s → empty state | — |
| Add | "Add" on a row | Not already in library (otherwise "Already added") | — | Machine Editor pre-filled | — | Machine Editor |

### Session Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Tab opens | — | "Connecting to <name>…" overlay with Cancel (Esc), until the first framebuffer update; the screen behind it takes no click | Framebuffer shown, overlay goes, keyboard captured | Banner (see Session errors below): "Unreachable…" (Retry) / "Authentication failed" (Edit credentials) / "Connection lost" (Reconnect) | — |
| Release keyboard | ⌃⌥⌘R while captured | — | — | Capture off: every key, modifier and button held on the remote is released; the pill disappears | — | — |
| Capture keyboard | Click in the remote screen | — | — | Capture on; the first time in an app run without Accessibility access, the system prompt (see Keyboard capture) | — | — |
| Toggle scaling | ⌘⌥S (keyboard released) / toolbar button | — | — | Fit-to-window ↔ 1:1, for this session only (Machine.scalingMode is the starting mode and is not changed) | — | — |
| Send clipboard | ⌘V while focused (Shared Clipboard on) | Text ≤ 1 MB | — | Text pasted remotely | Toast: "Clipboard too large" | — |
| Switch tab | ⌘1…⌘9 / click tab | — | — | Tab shown | — | — |
| Open Claude | ⌘K / toolbar sparkle icon | API key present | — | Claude Assistant Panel opens | No key → link to Settings Window › Claude | Claude Assistant Panel |
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


### Claude Assistant Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Ask | Return in the prompt field | Prompt 1–2000 chars | "Claude is looking…" + pulsing indicator | Text answer and/or a list of proposed actions | API error message, with Retry | — |
| Confirm action | "Confirm" (⌘Return) | Session still connected | Action highlighted on the framebuffer | Action sent; Claude continues with a new screenshot | "Session disconnected" → actions cancelled | — |
| Skip / Stop | "Skip" / "Stop" (⌘.) | — | — | Loop stops; remaining actions are marked `rejected` | — | — |

### Session History View

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Open | Menu Window › Session History (⌘Y) | — | — | Table sorted by date, newest first | — | — |
| Reconnect | Double-click a row | Machine still exists | — | Session Window tab | "Machine deleted" | Session Window |
| Export CSV | "Export…" | — | — | Save panel → CSV file | Write error alert | — |

### Settings Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save API key | Paste the key, "Save" | Starts with `sk-ant-`, test call OK | "Checking…" | "Key valid" ✓ | "Invalid key" | — |
| Toggle iCloud Sync | Switch | iCloud account signed in | "Syncing…" | Last-sync timestamp shown | "iCloud unavailable" | — |
| Toggle notifications | Switch | Permission granted | — | — | Permission denied → button that opens System Settings | — |

## Navigation rules

- One Library Window, one Session Window containing native macOS window tabs, and one Settings Window (⌘,). Until Session Tabs (T4.2), each machine has its own Session Window.
- ⌘0 Library, ⌘1…⌘9 session tabs, ⌘K Claude Assistant Panel, ⌘Y Session History View.
- While a session has the keyboard captured, key combos go to the remote machine, with the exceptions in Keyboard capture below.
- Deep links open in a new tab of the existing Session Window.

### Keyboard capture

Shortcuts match the physical key (key code) and the exact set of ⇧⌃⌥⌘, so they work with any layout (AZERTY included); Caps Lock does not matter.

| While captured | What happens | Why |
|---|---|---|
| ⌃⌥⌘R | Releases the capture; never sent to the remote | Not used by macOS or common apps. (The Force Quit combo, which macOS never hands to apps, was the first choice.) |
| ⌘1…⌘9 (top-row digit keys) | Stay local: switch session tab | The only local allow-list (`LocalShortcut`); the remote sees ⌘ go down and up, nothing else |
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

- **Library in memory** (the on-disk store could not be opened): persistent orange banner at the top of the Library Window, "The library could not be opened — The library runs in memory: nothing you do now is saved, passwords included."
- **Empty library:** illustration-free message "No machines yet", with two buttons: "Discover on network" (disabled until T3.6) and "Add manually".
- **Discovery found nothing:** "No Mac with Screen Sharing found. Enable it in System Settings › General › Sharing on the remote Mac.", with a Retry button.
- **Local network permission denied:** explanation plus a button that opens System Settings › Privacy & Security › Local Network.
- **Offline / host unreachable:** session banner "Unreachable — check VPN or network", with a Retry button. Watched machines show a grey dot in the sidebar.
- **No Anthropic API key:** the Claude Assistant Panel shows "Add your API key in Settings to use Claude", with a button.
- **iCloud signed out:** the sync section shows "Sign in to iCloud to sync your library". The app keeps working locally.
- **Empty Session History:** "Sessions you open will appear here."

## First use

No account creation. Onboarding Sheet in 3 steps:
1. Welcome and what the app does.
2. Permissions: Local Network (triggered by a first Bonjour browse) and Notifications.
3. "Sync your library with iCloud?" (Enable / Not now). Then the Discovery Panel opens automatically.
