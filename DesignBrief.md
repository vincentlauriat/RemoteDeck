# Design brief — RemoteDeck

## Audience and tone

For one technical user who spends long periods inside remote screens. The app must disappear behind the remote desktop.
**Tone: sober, dense, professional.** Native macOS look, no custom chrome, information-dense lists.

## Reference products *(assumption)*

| Product | Borrow | Avoid |
|---|---|---|
| Screens 5 (Edovia) | Clean sidebar library, connection overlay, toolbar with scaling/clipboard | Large decorative thumbnails |
| Jump Desktop | Fast tab switching, keyboard-capture indicator | Dense, cryptic settings |
| Apple Remote Desktop | Machine status dots, compact list rows | Fleet-management menus, dated UI |
| Xcode / Finder sidebars | Native `NavigationSplitView` behavior, source-list styling | — |

## Color palette

System colors are used everywhere so that light/dark mode and the user's accent color are honored. Hex values are given for reference (light / dark).

| Role | Token | Light | Dark |
|---|---|---|---|
| Primary / accent | `Color.accentColor` (system Blue default) | `#007AFF` | `#0A84FF` |
| Background (window) | `windowBackgroundColor` | `#ECECEC` | `#1E1E1E` |
| Background (session area) | fixed | `#000000` | `#000000` |
| Text primary | `labelColor` | `#000000` (85 %) | `#FFFFFF` (85 %) |
| Text secondary | `secondaryLabelColor` | `#3C3C43` (60 %) | `#EBEBF5` (60 %) |
| Success (online) | `systemGreen` | `#34C759` | `#30D158` |
| Warning (public IP, slow link) | `systemOrange` | `#FF9500` | `#FF9F0A` |
| Error (offline, auth failed) | `systemRed` | `#FF3B30` | `#FF453A` |
| Info / Claude activity | `systemPurple` | `#AF52DE` | `#BF5AF2` |

## Typography

SF Pro (system font) only; SF Mono for hosts, ports and logs.
- Window title: 13 pt semibold (system).
- Sidebar row name: 13 pt regular; secondary line (host): 11 pt regular, secondary color.
- Section headers: 11 pt semibold, uppercase, secondary color.
- Body / forms: 13 pt regular.
- Overlay message ("Connecting…"): 15 pt medium, white on 60 % black.
- Monospaced values: SF Mono 12 pt.

## Components

- **Buttons:** standard `.bordered` for secondary actions, `.borderedProminent` only for the single primary action per sheet (Save, Connect). Destructive actions use the `.destructive` role and a confirm dialog.
- **Forms:** `Form` with `.grouped` style in sheets, labels aligned on the left, validation message 11 pt in red under the field.
- **Sidebar rows:** 28 pt height, SF Symbol by machine kind (`desktopcomputer`, `display`, `sparkles` for Anthropic VM), a star for favorites, and a status dot (8 pt) on the trailing side: `systemGreen` online, `systemRed` offline, `systemGray` when the status is not known yet, this Mac has no network, or Local Network access is off (T4.5); each with a VoiceOver label and a tooltip ("Online", "Offline — not answering", "Checking…", "No network on this Mac", "Local network access is off…"). A machine not watched has no dot in the row.
- **Tabs:** native window tabs, title = machine name, with a status dot (the dot is not built yet: T4.2 ships the titles only; candidate: `NSWindowTab.accessoryView`).
- **Session toolbar:** unified compact toolbar that auto-hides in full screen. Icons only, with tooltips.
- **Banners:** top-of-session inline banner 32 pt high, colored left bar (error/warning), with a single action button. The Library Window's in-memory banner runs across the bottom of the window (at the top, the sidebar's search field would cover it).
- **Toasts:** bottom-center, 2 s, for transient info ("Clipboard too large"). The Shared Clipboard syncs silently: a toast on every sync would be noise.
- **Claude Assistant Panel:** inspector 320 pt wide. Messages as plain text blocks (no bubbles): the prompt in semibold, progress notes in secondary with an `ellipsis.bubble` icon, answers in body text (selectable). Each action is a row on a 6 pt rounded fill with an icon (`cursorarrow.click`, `keyboard`, `scroll`, `camera.viewfinder`, `hourglass`), a description in remote pixels (e.g. "Click at (412, 230)", "Type “uptime⏎”"; the target's name is not known, the toolset gives only coordinates) and its status (✓, Skipped, Not run, Cancelled, Failed); a typing proposal shows its whole text with invisible characters visible (⏎ ⇥ `\u{…}`, plus a caption-size orange note when it holds controls or format characters), and a long or multi-line one a closed disclosure ("Show the full text (n characters)", 11 pt monospaced text in a 4 pt rounded block up to 200 pt high once open) that must be opened before Confirm is enabled; after 8 turns without an action the transcript ends with an orange "Paused — …" row with Continue (prominent, purple) and Stop (T5.3); the action waiting for confirmation is tinted purple with Confirm (prominent, purple) and Skip buttons, and its target is drawn on the framebuffer as purple rings (22 pt, 25 % fill, 2 pt stroke).

## Layout rules

- Spacing scale: 4, 8, 12, 16, 20 pt (macOS standard). Sheet padding 20 pt.
- Library Window: sidebar 220–320 pt (resizable), detail pane with machine info and a large "Connect" button. Minimum window size 720 × 480.
- Session Window: the framebuffer fills the content area. Letterbox in black when the aspect ratios differ. Minimum 640 × 400.
- Scaling (⌘⌥S): **Fit** scales the framebuffer up or down to the content area, aspect ratio kept, centered (linear filtering). **Actual size** shows one remote pixel per device pixel of the local display, so it is pixel-exact (nearest filtering): a 2880 × 1800 Retina remote takes 1440 × 900 pt on a Retina Mac, a 1920 × 1080 remote 960 × 540 pt. Smaller than the content area → centered on black; larger → clipped, the visible part set by a scroll offset (panning UI: Session Window).
- Machine Editor sheet: 460 pt wide.
- No breakpoints (desktop only). In full screen, the toolbar reveals on hover at the top edge.

## Per-screen notes

- **Onboarding Sheet:** 3 pages, 520 × 400 pt, a large SF Symbol (48 pt: `desktopcomputer`, `lock.shield`, `icloud`), one sentence and one primary button per page (Continue, Continue, Not now), page dots above the buttons, "Later" bottom left on the first two pages. The permissions page lists Local Network and Notifications as rows (symbol, title, 11 pt secondary text; "Allow notifications" under the latter).
- **Library Window:** groups as collapsible sidebar sections. Favorites section pinned at the top. The detail pane shows name, host:port (mono), kind, a status line (the dot, hidden from VoiceOver there, and its label, "Not watched" included), and last connected. Machine Editor: under "Watch", an 11 pt secondary note when notifications are not allowed, with a small "Allow notifications" button when macOS has not asked yet.
- **Machine Editor:** the kind picker comes first, because it changes the fields (Anthropic VM hides the user field and shows an 11 pt secondary note under the password, which is optional; Mac ARD requires the user field). The "Test" button sits next to "Save".
- **Discovery Panel:** popover-sized sheet 420 × 360 pt, title on top, "Close" (Esc) at the bottom right. Each row shows the kind symbol, name, host in SF Mono (`:port` when not 5900) and service types in 11 pt secondary ("Screen Sharing · Remote Management"), with an "Add" button on the right; machines already added are greyed (50 %) with "Already added" instead of the button. Searching, empty, blocked and failed states use `ContentUnavailableView` with their one action (Retry / Open System Settings).
- **Session Window:** the remote screen is the hero. Connecting overlay centered over the screen dimmed to 60 % black (spinner, "Connecting to <name>…", Cancel). Keyboard-capture state shown as a toolbar pill: "Keyboard captured — ⌃⌥⌘R to release" (AppFlow › Keyboard capture), shown only while captured. Without Accessibility access, a toolbar button next to the pill reads "System shortcuts need Accessibility access — Open Settings"; it opens System Settings › Privacy & Security › Accessibility. Then two icon buttons with tooltips: scaling (fit ↔ actual size, ⌥⌘S) and Disconnect. A session whose address is on the public Internet shows an "Internet" capsule badge before the clipboard toggle (11 pt medium, `exclamationmark.shield.fill`, `systemOrange` text on `systemOrange` at 18 %, tooltip: unencrypted, Shared Clipboard off unless turned on). Before the first connection of a machine to a public address, a sheet (420 pt wide, 20 pt padding): orange headline "Unencrypted connection over the Internet" with the same symbol, the body naming the address, a secondary caption "This choice is remembered for this machine on this Mac.", then Cancel (Esc) and Connect anyway; it cannot be dismissed otherwise (T5.3). The Machine Editor shows an 11 pt `systemOrange` note under a host typed as a public IP address. On an error, the banner sits under the toolbar and the last frame stays behind it, dimmed to 35 %. Actual-size panning (scroll offset) is not built yet.
- **Claude Assistant Panel:** prompt field at the bottom (grows to 5 lines) with Ask, or Stop while busy, history above, and a token counter for the session at the top-right in 11 pt secondary (tooltip: input, cache read, cache write, output), next to New Conversation. No key: a centred key symbol, "Add your API key in Settings to use Claude" and "Open Settings…".
- **Session History View:** window 1000 × 600 pt (min 760 × 420); toolbar: machine and outcome pickers, Export (`square.and.arrow.up`), search. `Table` with sortable columns Machine, Started, Connect time (ms), Duration (h:mm:ss; "In progress" in green, "Unknown" in secondary with a tooltip), Outcome (failures in red), Received, Claude tokens; numbers right-aligned in monospaced digits. Summary strip above (16 pt padding): "Last 30 days" in 13 pt semibold, then metrics as an 11 pt secondary title over a 15 pt medium value (sessions, first frame ≤ 5 s floored to 0.1 % and in orange under 90 %, p50, p90, connected time), "By machine…" at the right (popover grid); an 11 pt secondary line under it with the failures, in-progress and unknown counts, and the static note "Apple Remote Desktop and Screen Sharing launches are not counted by RemoteDeck." (the sandboxed app does not watch other apps). Empty: `ContentUnavailableView` with `clock.arrow.circlepath`.
- **Settings Window:** standard tabbed settings (General, Sync, Claude, Notifications). Notifications section (T4.5): the "Status notifications" switch, a caption, then the permission line (as in the Machine Editor, plus "Notifications allowed" in green). Claude section (T4.4): "An API key is stored." / "No API key stored." with a key symbol, a secure field with Save, the check's outcome on one caption line (spinner "Checking…", green "Key valid", red errors), "Remove Key" when one is stored, and the model name.
- **Menu Bar Extra:** `display.2` symbol; a menu with the Favorites section, the Recent section (the 5 most recent machines that are not favorites), each row with its kind symbol, then a separator, "Open Library…", "Session History…", a separator and "Quit RemoteDeck" (⌘Q).

## Accessibility

- Contrast WCAG AA minimum (system colors comply). Status is never shown by color alone: the dot has a VoiceOver label and a tooltip ("Online").
- Full keyboard navigation in Library, Editor, Discovery, History and Settings; every toolbar icon has an accessibility label.
- Click targets ≥ 28 pt high (macOS standard). This document intentionally follows the macOS norm rather than the 44 px mobile touch norm.
- Respect Reduce Motion (no overlay fades) and Increase Contrast.

## Interaction states

- **Hover:** native row highlight; toolbar icons show a tooltip after 0.5 s.
- **Focus:** system focus ring; the session view shows a 2 pt accent border when it holds keyboard capture.
- **Disabled:** system disabled style; "Connect" is disabled when the host is empty.
- **Loading:** indeterminate spinner (small) for rows, overlay spinner for sessions, pulsing purple dot for Claude.
- **Error:** red banner/inline text with an action.
- **Success:** green check for the connection test; clipboard syncs show nothing.

## Required assets

- App icon (1024 pt master, macOS rounded-square template). *(assumption: to be designed; a monitor glyph with a remote "deck" stack)*
- SF Symbols only for UI icons: `desktopcomputer`, `display`, `sparkles`, `antenna.radiowaves.left.and.right`, `doc.on.clipboard`, `clock.arrow.circlepath`, `bell`.
- No illustrations.
- README and release-page screenshots: Library Window, Session Window with Claude Assistant Panel.
