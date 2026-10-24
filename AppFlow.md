# App flow — RemoteDeck

## Entry points

- Launching the app (Dock, Spotlight): opens the Library Window, at every launch (also after a killed run). Session Windows are never restored at launch: reopening one would reconnect to a host without the user asking.
- Menu Bar Extra (T4.6): quick-connect list of favorite and recent machines (see Menu Bar Extra below).
- URL scheme `remotedeck://connect?id=<machine-id>`, plus `vnc://host` URLs registered as a handler: opens a session directly. *(assumption)*
- Status Notifications (T4.5): clicking a notification brings the app forward with the Library Window and selects the machine in the Library, whichever the notification ("offline" or "online again"); since T5.3 a click never opens a session by itself. A machine deleted since is ignored.
- First launch: Onboarding Sheet over the Library Window, until it is finished or skipped (AppSettings `onboardingCompleted`); never under the hosted tests, `-FramebufferDebug` or a `-LibraryDemo` mode other than `onboarding`. No menu item reopens it.

## Screen list

| Screen | Purpose | Data needed |
|---|---|---|
| Onboarding Sheet | Explain the app, ask for local network and notification permissions, offer to enable iCloud Sync | AppSettings |
| Library Window | Sidebar with Favorites (pinned; a favorite is listed there only, so each machine has one row), groups (by sort order, then name; empty groups shown unless searching) and ungrouped Machines; search; toolbar (add, discover, connect) | Machine, MachineGroup |
| Machine Editor | Create or edit a machine: name, kind (Mac ARD / VNC / Anthropic VM), host, port, user, password, group (or "New Group…"), watch, favorite, scaling, shared clipboard (new machines default to AppSettings `defaultSharedClipboard`, except an Anthropic VM, off by default; the default follows the kind until the toggle is touched, T5.3). A host typed as a public IP address shows an orange note under the field: "Public address: the connection will travel unencrypted over the Internet. Prefer a VPN or the local network." | Machine, MachineGroup, KeychainCredential, AppSettings |
| Discovery Panel | Sheet listing the hosts found on the LAN through Bonjour (`_rfb._tcp` and `_net-assistant._udp`, merged per host; this Mac is left out), with "Add" per row | Live Bonjour results, Machine (for "Already added") |
| Session Window | Remote framebuffer with tabs, toolbar (scaling, clipboard, Ctrl-Alt-Del equivalents, Claude, disconnect) | Machine, KeychainCredential, SessionRecord |
| Claude Assistant Panel | Inspector beside the Session Window (320 pt): token counter and New Conversation at the top, transcript (prompts, progress notes, answers, actions with Confirm/Skip), prompt field with Ask/Stop at the bottom | AssistantAction, KeychainCredential, SessionRecord.assistantTokens |
| Session History View | Table of past sessions and a 30-day summary | SessionRecord |
| Settings Window | General, iCloud Sync, Claude (API key, model), Notifications, Shared Clipboard default | AppSettings, KeychainCredential |
| Menu Bar Extra | Favorites and recents, "Open Library…", "Session History…", "Quit RemoteDeck" | Machine, SessionRecord |

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
| Test connection | "Test" button | Same as Save | "Testing…" spinner (timeout 5 s) | Green check: "Reachable, auth OK"; the connection is closed at once | "Unreachable — check VPN or network" (network error) / "Unreachable — no answer within 5 s" / "The server closed the connection" / "Connection refused by the server" (RFB-level, with its reason) / "Authentication failed" / "Unsupported security type (n, …)" / "This Mac needs a user name and password" / "This server needs a password" / "User name or password too long (63 bytes max)" / "Not a VNC / Screen Sharing server" / "Unexpected response from the server". T5.3: a public address not confirmed for this machine at this host stops before any credential: "Public address not confirmed: nothing was sent. Connect once from the library and choose “Connect anyway”" (a new machine, or an edited host, is never confirmed); a Mac with a user name without type 30, or a password set with only type 1 offered, gets the session banners' wording (below) | — |
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
| Connect | Tab opens | — | "Connecting to <name>…" overlay with Cancel (Esc), until the first framebuffer update; the screen behind it takes no click | Framebuffer shown, overlay goes, keyboard captured. Address on the public Internet: orange "Internet" badge in the toolbar (tooltip: unencrypted, Shared Clipboard off unless turned on) | Banner (see Session errors below): "Unreachable…" (Retry) / "Authentication failed" (Edit credentials) / "Connection lost" (Reconnect). First connection of this machine to a public address: the sheet below | — |
| Confirm a public address (T5.3) | The address the connection reached (resolved at connect time, not the host name) is on the public Internet and this machine was never confirmed on this Mac; checked at every attempt, automatic reconnects included | Stopped right after TCP, before any RFB byte: no credential sent | — | Sheet "Unencrypted connection over the Internet": "<address> is a public address. The screen, keystrokes and clipboard travel unencrypted over the Internet, and ARD authentication can be intercepted by a man in the middle. Prefer a VPN or the local network." — "This choice is remembered for this machine on this Mac." **Connect anyway**: remembered for this machine at this host (editing the host asks again), a new attempt starts. **Cancel** (Esc): the tab closes, nothing remembered | — | SessionRecord of the stopped attempt `cancelled` |
| Release keyboard | ⌃⌥⌘R while captured | — | — | Capture off: every key, modifier and button held on the remote is released; the pill disappears | — | — |
| Capture keyboard | Click in the remote screen | — | — | Capture on; the first time in an app run without Accessibility access, the system prompt (see Keyboard capture) | — | — |
| Toggle scaling | ⌘⌥S (keyboard released) / toolbar button | — | — | Fit-to-window ↔ 1:1, for this session only (Machine.scalingMode is the starting mode and is not changed) | — | — |
| Send clipboard | Automatic while Shared Clipboard is on and the Session Window is key: the local text goes to the remote when the window becomes key and when the local clipboard changes while it stays key (checked every 0.5 s), so ⌘V (or a remote Paste menu) pastes it | Plain text ≤ 1 MiB (UTF-8 bytes); items marked concealed/transient/auto-generated (password managers) are never sent | — | Text pasted remotely | Toast (bottom-center, 2 s): "Clipboard too large"; nothing sent | — |
| Receive clipboard | Text copied on the remote (Shared Clipboard on) | Plain text ≤ 1 MiB; C0 control characters other than tab, line feed and carriage return, DEL and C1 controls removed | — | Written to the local clipboard only while the session runs and its window is key; otherwise the latest remote text waits and is written when the window becomes key, unless something was copied locally since it arrived (the local copy wins) (T5.3) | — (too large or malformed: ignored) | — |
| Toggle Shared Clipboard | Toolbar `doc.on.clipboard` toggle | — | — | On/off for this session only (Machine.sharedClipboard is the starting value and is not changed); off, nothing is read, written or sent. A session whose address is on the public Internet starts with it off; the user's toggle then holds for the session, reconnects included (T5.3) | — | — |
| Switch tab | ⌘1…⌘9 / click tab | — | — | Tab shown | — | — |
| Open Claude | Toolbar sparkle toggle (always) / ⌘K (keyboard released: while captured, ⌘K goes to the remote like every combo but ⌘1…⌘9) | — | — | Claude Assistant Panel opens with the prompt field focused, which takes the keyboard from the remote (capture off, everything held released) | No key → "Add your API key in Settings to use Claude" + "Open Settings…" | Claude Assistant Panel |
| Disconnect | ⌘W (keyboard released) / toolbar "Disconnect" / window close button | — | — | Tab closes, SessionRecord saved | — | Library Window if no tab is left |

#### Session errors (T3.5)

The banner sits at the top of the Session Window (32 pt, red bar, one button); the last frame stays dimmed behind it and takes no click. Copy for connection failures is the Machine Editor's Test copy, except the timeout.

| Cause | Banner | Button | SessionRecord.outcome |
|---|---|---|---|
| Mac with a user name, and the server does not offer Apple authentication (type 30), or an RFB 3.3 server imposes another type (T5.3): nothing but the version banner was sent | "This Mac does not offer Apple authentication (type 30): RemoteDeck will not send your macOS password with weaker authentication, nor connect without authentication" (offered types) | Edit credentials (kind or user name) | `authFailed` |
| A password is set but the server offers only no authentication (type 1), or an RFB 3.3 server imposes type 1 (T5.3) | "A password is set but the server offers no password authentication (type 2): RemoteDeck will not connect without authentication. Clear the password if the server has none" (offered types) | Edit credentials | `authFailed` |
| Wrong credentials, missing user name or password, credential too long | "Authentication failed" (with the server's reason) / the Test copy for the missing or too-long credential | Edit credentials (Machine Editor sheet; Save retries) | `authFailed` |
| Password unreadable from the Keychain (nothing is sent) | "The password could not be read from the Keychain (status)" | Edit credentials | `authFailed` |
| Network error, refused, not an RFB server, unsupported security type, protocol error | Test copy ("Unreachable — check VPN or network"…) | Retry | `unreachable` |
| No answer within 10 s (connect + handshake) | "Unreachable — no answer within 10 s" | Retry | `unreachable` |
| The session ends after authentication without the user asking (server gone, network, malformed data) | Before the first frame: "Connection lost" at once. After it: no banner, one automatic reconnect first (see Interruptions below) | Reconnect | `dropped` |
| The automatic reconnect fails (unreachable, timeout, refused, lost before its first frame) | "Connection lost" | Reconnect | that attempt's own outcome (`unreachable`, `dropped`) |
| The automatic reconnect fails on credentials | The authentication banner of that failure (nothing is retried, the Machine Editor never opens by itself) | Edit credentials | `authFailed` |
| Cancel / Esc / window closed before the first frame | — (window closes) | — | `cancelled` |

#### Interruptions (T5.1)

A session the user was looking at survives a drop, sleep and a network change without a banner storm. While it waits or reconnects, the last frame stays dimmed under the connecting overlay (same layout, Cancel/Esc closes the tab), the keyboard is released, and no SessionRecord is open between two attempts. Each attempt is its own SessionRecord.

| Cause | Overlay | What happens | SessionRecord |
|---|---|---|---|
| Drop after the first frame (server gone, malformed data, or a connection that died silently: TCP keepalive gives up after ≈ 25 s of silence, or its interface stays unusable for 5 s, e.g. Wi-Fi → Ethernet with the network still there — to verify live) | "Reconnecting to <name>…" | One automatic attempt 2 s later (only with a network path). Success: the session goes on, and takes the keyboard back only if it had it when lost. Failure: "Connection lost" banner + Reconnect, or the auth banner; never a second automatic attempt. An automatic attempt that is lost again within 60 s of its first frame (drop or network loss) gets no other one (banner), so a server that drops every session or a flapping Wi-Fi never loops. The password is read without any Keychain dialog: if one would be needed, the "password could not be read" banner shows instead | lost one `dropped`, then a new record per attempt |
| No network on this Mac (path not satisfied; a path that only needs a connection brought up, such as a VPN on demand, counts as network) | "Waiting for network…" — "The session reconnects when the network is back." | A connected session keeps its connection for 3 s under the overlay: a shorter blip changes nothing. Still no network after 3 s: it is closed (input released first). An automatic attempt in flight or waiting is held at once. No attempt and no banner while offline. Network back: one automatic attempt, 2 s later. A Connect, Retry or Reconnect the user clicks while offline runs and fails with its usual banner, and is not run again when the network comes back | connected one `dropped` (after the 3 s); a held automatic attempt `cancelled` |
| The Mac goes to sleep | (asleep) | Every connected or connecting session closes cleanly (assistant stopped, input released, then the connection closed) and is remembered; a session showing a banner stays as it is | connected one keeps `connected` with its end (as a Disconnect); connecting `cancelled` |
| The Mac wakes | "Reconnecting to <name>…" | 5 s grace (even if the network flaps back meanwhile), then one automatic attempt per remembered session still open; without a network path it waits for it ("Waiting for network…"). A tab closed during sleep is never reconnected | new record per attempt |

An action the Claude Assistant runs or proposes is stopped before any teardown ("Session disconnected — actions cancelled"); nothing it proposed runs after a reconnect (a new Ask is needed).

While a session waits or reconnects, its machine counts as being opened for Status Notifications: no probe, so no "offline" or "back online" notification for a machine whose session handles it.


### Status Notifications (T4.5)

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Watch | "Watch (notify when offline)" toggle in the Machine Editor, then Save | — | Grey dot, "Checking…", until the first answer | Green dot "Online" / red dot "Offline — not answering" in the row and the detail pane (a machine not watched has no dot in the row; the detail pane says "Not watched") | Notifications not allowed: a note under the toggle ("Allow notifications" button when not asked yet, a pointer to System Settings › Notifications when denied, or "turned off in Settings"); the dot works anyway | — |
| Offline notification | A watched machine seen online fails 2 probes in a row | Settings › Status notifications on, macOS permission granted (never requested here) | — | "<name> is offline" — "The machine no longer answers on the network." | — | — |
| Back online notification | First answer after offline | Same | — | "<name> is back online" — "Click to open it in the library." (replaces the offline one in Notification Center) | — | — |
| Click a notification | Banner or Notification Center | Machine still in the library | — | App forward, Library Window opened with the machine selected (both notifications; since T5.3 a click never connects by itself: Connect stays the user's) | Machine deleted: the app comes forward, nothing else | Library Window / Session Window |

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
| Confirm action | "Confirm" (⌘Return, keyboard released: the capture is released when an action waits). Enabled 400 ms after the proposal appears; a key repeat or a click meant for an earlier proposal does nothing. A typing proposal shows its whole text, never cut, with invisible characters made visible (⏎ line feed, ⇥ tab, `\u{…}` for controls, bidi overrides, zero-width and other default-ignorable characters, spaces other than U+0020); key names of `key` / `hold_key` proposals are escaped the same way, and an orange note when it holds any; a text over 80 characters (Unicode scalars, as the 4000 cap) or on several lines is in a closed block ("Show the full text (n characters)") that must be opened first: Confirm is enabled 400 ms after it is opened ("Show the full text before confirming"). A text over 4000 Unicode scalars is never proposed (Claude gets an error) (T5.3) | Session still connected | The proposal is highlighted in purple in the panel and as purple rings on the framebuffer; then "Running the action…" | Action sent through the session's input; Claude continues (often with a new screenshot) | "Session disconnected — actions cancelled" | — |
| Skip | "Skip" | — | — | The action is not run, the rest of Claude's turn is not run either ("Not run"); Claude is told and answers | — | — |
| Pause (T5.3) | 8 API turns in a row without a confirmed action (screenshots, zooms, waits, cursor positions, skips and errors count; a confirmed action, an Ask or Continue starts a new count) | — | — | "Paused — Claude made 8 steps without an action. Continue?" with **Continue** (the turn's results go out, a new count) and **Stop** (the results go with the next Ask). Busy: no Ask while paused. No token cap | — | — |
| Stop | "Stop" (⌘., keyboard released) | — | "Stopping…" (no Ask) until the loop has ended | The request in flight and the loop stop ("Stopped."); pending actions are marked `cancelled`; Claude hears of it with the next Ask | — | — |
| New conversation | Toolbar of the panel (`square.and.pencil`) | Not busy | — | Transcript and conversation cleared; the token counter keeps the session total | — | — |

### Session History View

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Open | Menu Window › Session History (⌘Y), or "Session History…" in the Menu Bar Extra | — | — | Table sorted by date, newest first | — | — |
| Sort | Click a column header | — | — | Rows reordered (no first frame sorts after every connect time; in progress after every duration, unknown last) | — | — |
| Filter / search | Toolbar pickers "All machines" / "All outcomes", search field (machine name, case- and accent-insensitive) | — | — | Rows filtered live; the summary is not filtered | "No results" | — |
| Reconnect | Double-click a row, or Reconnect in its context menu | Machine still exists and has a host and port | — | The Connect path (a new tab, or the machine's open tab brought forward) | "Machine deleted" alert; a machine without a valid address: "Cannot connect" alert | Session Window |
| Export CSV | "Export…" (toolbar) | At least one record | — | Save panel as a sheet on the History window (`RemoteDeck History <date>.csv`) → every record, whatever the filters, as CSV (BackendSchema › Export) | Write error alert with the error | — |

Columns (DesignBrief): Machine (the record's name snapshot, so a deleted or renamed machine keeps the name it had), Started, Connect time (ms; "—" without a first frame), Duration (`endedAt − startedAt`; "In progress" when the record's session is open now; "Unknown" when the record has no end and no open session, i.e. the run was killed: no end time is ever guessed), Outcome (the stored one, except a record with no end and no first frame, which still holds the `cancelled` it was created with: "Connecting…" while its session is open, "Interrupted" otherwise, in red; the outcome filter and the counts use the same values), Received (bytes; "—" for none), Claude tokens (empty for none).

30-day summary strip (over every record started in the last 30 × 24 h, absolute interval, whatever the filters): Sessions (attempts with a first frame; tooltip with the attempt count), First frame ≤ 5 s (fast sessions over sessions plus attempts that ended without a first frame after more than 5 s; floored to 0.1 %, orange under 90 %; PRD › Success metric), Connect p50 and p90 (nearest rank, ms), Connected time (sum of the sessions' durations with an end), then the failures per outcome (authentication failed, unreachable, connection lost, interrupted) and cancelled, the in-progress and unknown-duration counts (as the Duration column), and the note that Apple Remote Desktop / Screen Sharing launches are not counted. "By machine…" opens a popover: per machine id (newest name), sessions, attempts, connected time.

### Menu Bar Extra (T4.6)

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Click a machine | Machine still exists, has host and port (greyed otherwise) | — | App forward; the Connect path (a new tab, or the open tab brought forward) | — (errors are shown in the session) | Session Window |
| Open Library… / Session History… | Click | — | — | App forward, that window opens | — | Library Window / Session History View |
| Quit RemoteDeck | Click, ⌘Q | — | — | The app quits (sessions get their end, as ⌘Q) | — | — |

Content: Favorites (by name), then Recent: the 5 most recent other machines (distinct, by their newest attempt of any outcome; a favorite is listed once, under Favorites), only machines still in the library, read from the newest 200 records; with no row: "No machines yet" for an empty library, else "No favorites or recent machines yet". Always shown (no setting).

### Settings Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save API key | Paste the key, "Save" (or Return). Typing only edits a draft: nothing is written before Save | Starts with `sk-ant-` ("An Anthropic API key starts with sk-ant-.", nothing sent), then a test request (`GET /v1/models`, no tokens billed) | "Checking…" | "Key valid" ✓; the field is emptied and the section says "An API key is stored." (the key is never shown back) | "Invalid key" (401/403); "The key could not be checked, nothing was saved: …" (network, rate limit, server); Keychain refusal with its status. Nothing is saved in any of them | — |
| Remove API key | "Remove Key" | A key is stored | — | "Key removed." | Keychain error with its status | — |
| Toggle iCloud Sync | Switch | iCloud account signed in | "Syncing…" | Last-sync timestamp shown | "iCloud unavailable" | — |
| Toggle notifications | "Status notifications" switch (Settings › Notifications, AppSettings `notificationsEnabled`, on by default) | — | — | Off: no Status Notification is posted (probes and dots go on) | Under the switch, the macOS permission: not asked yet → "Allow notifications" (the system prompt, on that click only); denied → "Notifications are off in System Settings › Notifications" (text pointer, no deep link); request failed → Retry; allowed → "Notifications allowed" | — |

## Navigation rules

- One Library Window, one Session History View window, one Session Window containing native macOS window tabs (one per open machine, each with its own connection), and one Settings Window (⌘,). A tab can be moved to its own window or windows merged back (Window menu); a new session joins the frontmost Session Window (visible and not minimised; else the one opened last). The tab bar's "+" brings the Library Window forward, where the next machine is picked. Switching tabs, minimising and full screen never disconnect; only closing a tab does.
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

Each state can be reproduced: by a hosted test through its model, or with a Debug `-LibraryDemo` mode (`empty`, `store-error`, `discovery-empty`, `discovery-blocked`, `discovery-failed`; `session` for the auth-failure banner; `watch` for the status dots and Status Notifications: three watched sample machines on fake probes every 3 s, "NAS" going offline and back, notifications printed on stderr instead of posted; `history` for the Session History View: fixed past records of every outcome, one older than 30 days, one left open by a "killed run", two of deleted machines, and a live "Mac mini" session in progress; `resilience` for the Interruptions: "Mac mini" and "NAS" drop 4 s after their first frame, "Mac mini" reconnects on its own, the automatic attempt of "NAS" fails to "Connection lost"; the network path and sleep/wake are the real ones, the connections stay fake). States marked with a later task are not built yet.

- **Library in memory** (the on-disk store could not be opened): persistent orange banner across the bottom of the Library Window (at the top, the sidebar's search field covered it), "The library could not be opened — The library runs in memory: nothing you do now is saved, passwords included."
- **Empty library:** illustration-free message "No machines yet", with two buttons: "Discover on network" (opens the Discovery Panel) and "Add manually".
- **Discovery found nothing:** "No Mac with Screen Sharing found. Enable it in System Settings › General › Sharing on the remote Mac.", with a Retry button.
- **Local network permission denied:** "Local network access is off", explanation plus a button that opens System Settings › Privacy & Security › Local Network. Detected when a browser waits with kDNSServiceErr_PolicyDenied (TN3179); the browser keeps running, so granting access brings the rows without Retry.
- **Offline / host unreachable:** session banner "Unreachable — check VPN or network", with a Retry button. A session that was connected when this Mac lost its network shows "Waiting for network…" over its last frame instead, and reconnects once when the network is back (T5.1, Session Window › Interruptions). A watched machine that stops answering shows a red dot ("Offline — not answering") in the sidebar and the detail pane; grey while its status is not known yet or when this Mac has no network (T4.5).
- **No Anthropic API key** (T4.4): the Claude Assistant Panel shows "Add your API key in Settings to use Claude", with an "Open Settings…" button. All Claude Assistant Panel states can be reproduced with the Debug `-LibraryDemo assistant` mode (one session, the panel open, an in-memory demo key and scripted API answers: a progress note, an answer, a click and a typing proposal) or by the hosted `AssistantModelTests`.
- **iCloud signed out** (T4.3): the sync section shows "Sign in to iCloud to sync your library". The app keeps working locally.
- **Empty Session History** (T4.6): "Sessions you open will appear here." (no summary, no table); a search or filter with no match: "No results". The filled view, with an in-progress and an unknown-duration row, is reproduced with `-LibraryDemo history`.

## First use

No account creation. Onboarding Sheet in 3 steps:
1. Welcome and what the app does.
2. Permissions: Local Network (explained only: the system prompt comes with the first Bonjour browse, from the Discovery Panel at the end) and Notifications ("Allow notifications" button; the request is sent on that click only, never at launch or on a page change; the answer is shown: allowed, off with a pointer to System Settings › Notifications, or failed).
3. "Sync your library with iCloud?" (Enable / Not now). Until iCloud Sync ships (T4.3), Enable is disabled with "iCloud Sync comes in a later version", and nothing is turned on. "Not now" ends the sheet, then the Discovery Panel opens automatically.

Finishing or skipping sets `onboardingCompleted` once; the sheet is never shown again. Quitting before either shows it again at the next launch. On the notification row, a failed request offers Retry; a "no" is final there (System Settings › Notifications).
