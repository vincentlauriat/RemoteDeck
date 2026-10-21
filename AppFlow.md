# App flow — RemoteDeck

## Entry points

- Launching the app (Dock, Spotlight): opens the Library Window.
- Menu Bar Extra: quick-connect list of favorite and recent machines.
- URL scheme `remotedeck://connect?id=<machine-id>`, plus `vnc://host` URLs registered as a handler: opens a session directly. *(assumption)*
- Status Notifications: clicking an "online again" notification opens a session on that machine.
- First launch: Onboarding Sheet over the Library Window.

## Screen list

| Screen | Purpose | Data needed |
|---|---|---|
| Onboarding Sheet | Explain the app, ask for local network and notification permissions, offer to enable iCloud Sync | AppSettings |
| Library Window | Sidebar with groups and machines, search, toolbar (add, discover, connect) | Machine, MachineGroup |
| Machine Editor | Create or edit a machine: name, kind (Mac ARD / VNC / Anthropic VM), host, port, user, password, group, watch, favorite | Machine, MachineGroup, KeychainCredential |
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
| Connect | Double-click / Return / toolbar "Connect" | Machine has host and port | Row spinner | Session Window tab opens | — (errors are shown in the session) | Session Window |
| Add machine | ⌘N / "+" | — | — | Empty editor | — | Machine Editor |
| Discover | ⌘D / toolbar | — | — | Panel opens | Local network permission denied → blocked state | Discovery Panel |
| Search | ⌘F, type | — | — | List filtered live on name/host | — | — |
| Delete | ⌫ on selection | Confirm dialog naming the machine | — | Row removed, Keychain item removed | — | — |

### Machine Editor

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Save | ⌘S / "Save" | Name 1–64 chars; host is a valid hostname/IPv4/IPv6; port 1–65535; no duplicate `host:port` | — | Sheet closes, row selected | Inline field error in red under the field | Library Window |
| Test connection | "Test" button | Same as Save | "Testing…" spinner (timeout 5 s) | Green check: "Reachable, auth OK" | "Unreachable" / "Authentication failed" / "Unsupported security type" | — |
| Cancel | Esc | — | — | Sheet closes without changes | — | Library Window |

### Discovery Panel

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Browse | Panel opens | — | "Searching…" for up to 3 s | Rows: name, host, service type | No result after 10 s → empty state | — |
| Add | "Add" on a row | Not already in library (otherwise "Already added") | — | Machine Editor pre-filled | — | Machine Editor |

### Session Window

| Action | Trigger | Validation | Loading | Success | Error | Next |
|---|---|---|---|---|---|---|
| Connect | Tab opens | — | "Connecting to <name>…" overlay with Cancel | Framebuffer shown, overlay fades | Banner: "Unreachable" / "Authentication failed" (Edit credentials) / "Connection lost" (Reconnect) | — |
| Toggle scaling | ⌘⌥S | — | — | Fit-to-window ↔ 1:1 | — | — |
| Send clipboard | ⌘V while focused (Shared Clipboard on) | Text ≤ 1 MB | — | Text pasted remotely | Toast: "Clipboard too large" | — |
| Switch tab | ⌘1…⌘9 / click tab | — | — | Tab shown | — | — |
| Open Claude | ⌘K / toolbar sparkle icon | API key present | — | Claude Assistant Panel opens | No key → link to Settings Window › Claude | Claude Assistant Panel |
| Disconnect | ⌘W | — | — | Tab closes, SessionRecord saved | — | Library Window if no tab is left |

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

- One Library Window, one Session Window containing native macOS window tabs, and one Settings Window (⌘,).
- ⌘0 Library, ⌘1…⌘9 session tabs, ⌘K Claude Assistant Panel, ⌘Y Session History View.
- While a session has focus, all key combos are sent to the remote machine, except ⌘⌥Esc "release keyboard" (shown in the toolbar). *(assumption)*
  - Open item: macOS reserves ⌘⌥Esc for Force Quit, so the app is not expected to receive it without a `CGEventTap` (Accessibility permission). Until that is decided, the capture pauses whenever the session view loses focus (another window or view) and resumes when it gets focus back; after ⌘⌥Esc, a click in the session takes it again. Also open: while captured, the Session Window's own shortcuts (⌘W, ⌘K, ⌘⌥S, ⌘1…⌘9, ⌘V) go to the remote too; T3.5/T4.2 need an allow-list decision. System combos (⌘Tab, ⌘Space, Mission Control) stay local for the same reason (TRD › Input).
- Deep links open in a new tab of the existing Session Window.

## Empty and blocked states

- **Empty library:** illustration-free message "No machines yet", with two buttons: "Discover on network" and "Add manually".
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
