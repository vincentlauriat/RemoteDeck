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
| Terminal area (post-1.0) | Ghostty's palette, not a system color | Ghostty's bundled "Tomorrow" theme (chosen in T7.1) | Ghostty's default dark palette |

The terminal follows the **system appearance** (Vincent, 2026-11-08): Ghostty's default dark palette in dark mode and a matching light palette in light mode (`TerminalAppearance.isDark` from the effective appearance). Vincent runs Ghostty 1.4.0 with no config file, so "like Ghostty" means its defaults: font, cursor, rendering, scrollback. The terminal fills its own area with the palette's background (not the fixed black of the screen session).

## Typography

SF Pro (system font) only; SF Mono for hosts, ports and logs.
- Window title: 13 pt semibold (system).
- Sidebar row name: 13 pt regular; secondary line (host): 11 pt regular, secondary color.
- Section headers: 11 pt semibold, uppercase, secondary color.
- Body / forms: 13 pt regular.
- Overlay message ("Connecting…"): 15 pt medium, white on 60 % black.
- Monospaced values: SF Mono 12 pt.
- Terminal text (post-1.0): Ghostty's default font and size, JetBrains Mono 13 pt (bundled, SIL OFL 1.1; the system monospaced font if it cannot be loaded), not SF Mono; ⌘+ / ⌘− change the size (no ⌘0 reset: ⌘0 stays the Library Window; Settings › Terminal has a "Text size" stepper). Colours: dark = Ghostty's defaults (#282C34 / #FFFFFF, its built-in palette, selection by swapping foreground and background); light = Ghostty's bundled "Tomorrow" theme (#FFFFFF / #4D4D4C, selection #D6D6D6). Cursor: a block, hollow when the terminal is not focused. Settings › Terminal can replace both (a theme for both appearances, an installed monospaced font) or edit every colour: the defaults above are the "Automatic" theme.

## Components

- **Buttons:** standard `.bordered` for secondary actions, `.borderedProminent` only for the single primary action per sheet (Save, Connect). Destructive actions use the `.destructive` role and a confirm dialog.
- **Forms:** `Form` with `.grouped` style in sheets, labels aligned on the left, validation message 11 pt in red under the field.
- **Sidebar rows:** 28 pt height, SF Symbol by machine kind (`desktopcomputer`, `display`, `sparkles` for Anthropic VM, `terminal` for SSH, post-1.0), a star for favorites, and a status dot (8 pt) on the trailing side: `systemGreen` online, `systemRed` offline, `systemGray` when the status is not known yet, this Mac has no network, or Local Network access is off (T4.5); each with a VoiceOver label and a tooltip ("Online", "Offline — not answering", "Checking…", "No network on this Mac", "Local network access is off…"). A machine not watched has no dot in the row.
- **Tabs:** native window tabs, title = machine name, with a status dot (the dot is not built yet: T4.2 ships the titles only; candidate: `NSWindowTab.accessoryView`).
- **Session toolbar:** unified compact toolbar that auto-hides in full screen. Icons only, with tooltips.
- **Banners:** top-of-session inline banner 32 pt high, colored left bar (error/warning), with a single action button. The Library Window's in-memory banner runs across the bottom of the window (at the top, the sidebar's search field would cover it).
- **Toasts:** bottom-center, 2 s, for transient info ("Clipboard too large"). The Shared Clipboard syncs silently: a toast on every sync would be noise.
- **Host key sheet and changed-key banner (post-1.0):** security UI in the app's sober tone, no alarmism and no humour. The unknown-key sheet is 420 pt wide with 20 pt padding like the public-address sheet: headline "Trust this server?", the host and port, the algorithm and the SHA256 fingerprint in SF Mono 12 pt (selectable, so it can be compared with `ssh-keygen -lf`), a secondary 11 pt caption "This choice is remembered for this machine on this Mac.", then Cancel (Esc) and Trust (the single prominent button). When `~/.ssh/known_hosts` could not be checked, one orange callout line with a warning triangle sits above the caption ("~/.ssh/known_hosts was not checked: …"), and with access lost a plain "Grant access to ~/.ssh…" button sits at the left of the button row. Wording is a proposal for the builder to settle with the fr/en strings. The changed-key banner is the 32 pt red banner of the session errors with a red left bar: "The identity of this server has changed." and, below or in a popover, the previous and the new fingerprint in SF Mono; it has **no** continue, trust or ignore button (a Close button only); the way out (Machine Editor › Remove from RemoteDeck's trusted keys…) is never offered from the banner. Not orange: orange is a warning the user may accept, red is a block.
- **Claude Assistant Panel:** inspector 320 pt wide. Messages as plain text blocks (no bubbles): the prompt in semibold, progress notes in secondary with an `ellipsis.bubble` icon, answers in body text (selectable). Each action is a row on a 6 pt rounded fill with an icon (`cursorarrow.click`, `keyboard`, `scroll`, `camera.viewfinder`, `hourglass`), a description in remote pixels (e.g. "Click at (412, 230)", "Type “uptime⏎”"; the target's name is not known, the toolset gives only coordinates) and its status (✓, Skipped, Not run, Cancelled, Failed); a typing proposal shows its whole text with invisible characters visible (⏎ ⇥ `\u{…}`, plus a caption-size orange note when it holds controls or format characters), and a long or multi-line one a closed disclosure ("Show the full text (n characters)", 11 pt monospaced text in a 4 pt rounded block up to 200 pt high once open) that must be opened before Confirm is enabled; after 8 turns without an action the transcript ends with an orange "Paused — …" row with Continue (prominent, purple) and Stop (T5.3); the action waiting for confirmation is tinted purple with Confirm (prominent, purple) and Skip buttons, and its target is drawn on the framebuffer as purple rings (22 pt, 25 % fill, 2 pt stroke).
- **Terminal Assistant Panel:** the same inspector and transcript look in terminal tabs. A command row shows the exact text that will be typed in a monospaced, wrapped, selectable block (no reveal toggle), the prompt line above it dimmed, an orange "Destructive" label with a warning triangle for destructive patterns and an orange "The command line isn't empty" note; the password wait is an orange line with a key symbol and Continue / Stop.

## Layout rules

- Spacing scale: 4, 8, 12, 16, 20 pt (macOS standard). Sheet padding 20 pt.
- Library Window: sidebar 220–320 pt (resizable), detail pane with machine info and a large "Connect" button. Minimum window size 720 × 480.
- Session Window: the framebuffer fills the content area. Letterbox in black when the aspect ratios differ. Minimum 640 × 400.
- Scaling (⌘⌥S): **Fit** scales the framebuffer up or down to the content area, aspect ratio kept, centered (linear filtering). **Actual size** shows one remote pixel per device pixel of the local display, so it is pixel-exact (nearest filtering): a 2880 × 1800 Retina remote takes 1440 × 900 pt on a Retina Mac, a 1920 × 1080 remote 960 × 540 pt. Smaller than the content area → centered on black; larger → clipped, the visible part set by a scroll offset (panning UI: Session Window).
- Machine Editor sheet: 460 pt wide.
- No breakpoints (desktop only). In full screen, the toolbar reveals on hover at the top edge.

## Per-screen notes

- **Onboarding Sheet:** 3 pages, 520 × 400 pt, a large SF Symbol (48 pt: `desktopcomputer`, `lock.shield`, `icloud`), one sentence and one primary button per page (Continue, Continue, Not now), page dots above the buttons, "Later" bottom left on the first two pages. The iCloud page has an "Enable" button under its sentence, with an 11 pt caption ("Syncing starts the next time you open RemoteDeck…"); "Not now" stays the default button. The permissions page lists Local Network and Notifications as rows (symbol, title, 11 pt secondary text; "Allow notifications" under the latter).
- **Library Window:** groups as collapsible sidebar sections. Favorites section pinned at the top. The detail pane shows name, host:port (mono), kind, a status line (the dot, hidden from VoiceOver there, and its label, "Not watched" included), and last connected. Machine Editor: under "Watch", an 11 pt secondary note when notifications are not allowed, with a small "Allow notifications" button when macOS has not asked yet.
- **Machine Editor, SSH (post-1.0):** the kind picker comes first as always; for SSH the form shows host, port (22), user, an authentication picker (Password / Key in ~/.ssh / Imported key) with its field under it, then a "Port forwards" list (rows of label, local port, remote host, remote port, with + and −), and hides scaling and Shared Clipboard. "Import from ~/.ssh/config…" is a bordered button next to the host field. 11 pt secondary notes under the key fields ("The key stays in ~/.ssh; RemoteDeck only reads it." / "The key is stored in your Keychain and syncs with iCloud Keychain."). The exact layout is the builder's, within these rules.
- **Machine Editor:** the kind picker comes first, because it changes the fields (Anthropic VM hides the user field and shows an 11 pt secondary note under the password, which is optional; Mac ARD requires the user field). The "Test" button sits next to "Save".
- **Discovery Panel:** popover-sized sheet 420 × 360 pt, title on top, "Close" (Esc) at the bottom right. Each row shows the kind symbol, name, host in SF Mono (`:port` when not 5900) and service types in 11 pt secondary ("Screen Sharing · Remote Management"), with an "Add" button on the right; machines already added are greyed (50 %) with "Already added" instead of the button. Searching, empty, blocked and failed states use `ContentUnavailableView` with their one action (Retry / Open System Settings).
- **Session Window:** the remote screen is the hero. Connecting overlay centered over the screen dimmed to 60 % black (spinner, "Connecting to <name>…", Cancel). Keyboard-capture state shown as a toolbar pill: "Keyboard captured — ⌃⌥⌘R to release" (AppFlow › Keyboard capture), shown only while captured. Without Accessibility access, a toolbar button next to the pill reads "System shortcuts need Accessibility access — Open Settings"; it opens System Settings › Privacy & Security › Accessibility. Then two icon buttons with tooltips: scaling (fit ↔ actual size, ⌥⌘S) and Disconnect. A session whose address is on the public Internet shows an "Internet" capsule badge before the clipboard toggle (11 pt medium, `exclamationmark.shield.fill`, `systemOrange` text on `systemOrange` at 18 %, tooltip: unencrypted, Shared Clipboard off unless turned on). Before the first connection of a machine to a public address, a sheet (420 pt wide, 20 pt padding): orange headline "Unencrypted connection over the Internet" with the same symbol, the body naming the address, a secondary caption "This choice is remembered for this machine on this Mac.", then Cancel (Esc) and Connect anyway; it cannot be dismissed otherwise (T5.3). The Machine Editor shows an 11 pt `systemOrange` note under a host typed as a public IP address. On an error, the banner sits under the toolbar and the last frame stays behind it, dimmed to 35 %. Actual-size panning (scroll offset) is not built yet.
- **Claude Assistant Panel:** prompt field at the bottom (grows to 5 lines) with Ask, or Stop while busy, history above, and a token counter for the session at the top-right in 11 pt secondary (tooltip: input, cache read, cache write, output), next to New Conversation. No key: a centred key symbol, "Add your API key in Settings to use Claude" and "Open Settings…".
- **Session History View:** window 1000 × 600 pt (min 760 × 420); toolbar: machine and outcome pickers, Export (`square.and.arrow.up`), search. `Table` with sortable columns Machine, Started, Connect time (ms), Duration (h:mm:ss; "In progress" in green, "Unknown" in secondary with a tooltip), Outcome (failures in red), Received, Claude tokens; numbers right-aligned in monospaced digits. Summary strip above (16 pt padding): "Last 30 days" in 13 pt semibold, then metrics as an 11 pt secondary title over a 15 pt medium value (sessions, first frame ≤ 5 s floored to 0.1 % and in orange under 90 %, p50, p90, connected time), "By machine…" at the right (popover grid); an 11 pt secondary line under it with the failures, in-progress and unknown counts, and the static note "Apple Remote Desktop and Screen Sharing launches are not counted by RemoteDeck." (the sandboxed app does not watch other apps). Empty: `ContentUnavailableView` with `clock.arrow.circlepath`.
- **Terminal tab (post-1.0):** the terminal fills the content area under the unified toolbar, on the palette's background; no letterbox. The connecting overlay, banners and the dimming of the last output are those of the screen session (15 pt medium message on 60 % black; 32 pt banner, output dimmed to 35 %). The toolbar holds, icons only with tooltips: a port forwards menu (`network`, hidden without forwards; one section per forward titled with its label or `localhost:8080 → localhost:80`, a symbol per state (`checkmark.circle` active, `circle.dotted` starting, `exclamationmark.triangle` failed, `stop.circle` stopped; menu images are templates, so the shape carries the state) with its word or error, "Open in Browser" (disabled unless active), and "Retry" for a failed one), Terminal Appearance (`textformat`: opens the Settings Window on its Terminal tab, font, theme and colours changing this terminal at once), and Disconnect; no scaling, clipboard, Claude or "Internet" controls. The reconnect separator is one line across the width in the secondary palette color. The file transfer sheet is 420 pt wide, 20 pt padding: the file names, the remote folder field (SF Mono 12 pt, pre-filled with the remote home), a progress bar with bytes done and total, Cancel, and Upload or Download as the single prominent button; "Replace <name>?" is a confirmation row inside the sheet (orange triangle on 12 % orange); a failure is a red `xmark.octagon.fill` line with the path or the server's words under it in SF Mono 11 pt. Files hovering over the terminal draw a 3 pt accent frame on 12 % accent with "Drop to upload to <name>" in a material capsule.
- **Settings Window:** standard tabbed settings, two tabs: General (Appearance, Language, Sync, Claude, Notifications, About) and post-1.0 Terminal (the "Use ⌥ as Meta" switch with an 11 pt caption "Off by default, as in Ghostty, so ⌥ types the characters of your keyboard layout.", then font, text size, theme, a preview in the terminal's font and colours, a Colors disclosure with one colour well per colour, and "Restore Terminal Defaults"). iCloud section (T4.3): the "iCloud Sync" switch, one caption status line (spinner for "Checking…"/"Syncing…", secondary "Last synced: …" with `checkmark.icloud`, orange signed-out/restricted/unavailable and "Quit and reopen…" lines, red errors with `exclamationmark.icloud`), then a caption on what syncs. Notifications section (T4.5): the "Status notifications" switch, a caption, then the permission line (as in the Machine Editor, plus "Notifications allowed" in green). Claude section (T4.4): "An API key is stored." / "No API key stored." with a key symbol, a secure field with Save, the check's outcome on one caption line (spinner "Checking…", green "Key valid", red errors), "Remove Key" when one is stored, and the model name.
- **Menu Bar Extra:** `display.2` symbol; a menu with the Favorites section, the Recent section (the 5 most recent machines that are not favorites), each row with its kind symbol, then a separator, "Open Library…", "Session History…", a separator and "Quit RemoteDeck" (⌘Q).

## Accessibility

- Contrast WCAG AA minimum (system colors comply). Status is never shown by color alone: the dot has a VoiceOver label and a tooltip ("Online").
- Host-key fingerprints (post-1.0) are selectable text, and a changed key is told by words and a red bar, never by color alone.
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

- App icon: drawn by `Scripts/make-icon.swift` (every macOS size into `AppIcon.appiconset`): the macOS Big Sur+ rounded square on Apple's 824/1024 grid with a soft shadow, deep blue gradient (#284A96 → #0E1A3C), a light display on a short aluminium stand whose screen is a teal-to-indigo desktop (#36C4D6 → #2E70E8 → #3A3EC4) with a small window and a white pointer outlined in navy; at 16 px it reads as a monitor with a pointer. The DMG background (`Scripts/make-dmg-background.swift`, 540 × 380) is near-white with the same blue as the arrow between the app and Applications, and the hint "Drag RemoteDeck to Applications to install it". The landing page (`docs/index.html`) uses the icon's #2E70E8 as accent with white text on it.
- Help and What's New windows (760 × 720 and 760 × 620, minimum 560 × 440): the page in a scroll view, text column at most 820 pt, 24 pt padding, selectable text; headings large title / title 2 / title 3 / headline by level; code blocks monospaced callout on a quaternary 8 pt rounded fill, scrolling sideways; tables as a grid on a lighter fill (a header row of empty cells is left out); quotes with a 3 pt bar; a bottom bar (`.bar` material) with Reload and "View on GitHub"; loading, error and empty states as `ContentUnavailableView` (`wifi.slash` offline, `exclamationmark.triangle` otherwise, `shippingbox` for no release).
- SF Symbols only for UI icons: `desktopcomputer`, `display`, `sparkles`, `antenna.radiowaves.left.and.right`, `doc.on.clipboard`, `clock.arrow.circlepath`, `bell`, and post-1.0 `terminal` (SSH kind) and `network` (port forwards menu).
- No illustrations.
- README and release-page screenshots: Library Window, Session Window with Claude Assistant Panel.
