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
- **Sidebar rows:** 28 pt height, SF Symbol by machine kind (`desktopcomputer`, `display`, `sparkles` for Anthropic VM), a status dot (8 pt) on the trailing side, and a star for favorites.
- **Tabs:** native window tabs, title = machine name, with a status dot.
- **Session toolbar:** unified compact toolbar that auto-hides in full screen. Icons only, with tooltips.
- **Banners:** top-of-session inline banner 32 pt high, colored left bar (error/warning), with a single action button.
- **Toasts:** bottom-center, 2 s, for transient info (clipboard sent).
- **Claude Assistant Panel:** inspector 320 pt wide. Messages as plain text blocks (no bubbles). Each proposed action is a row with an icon, a description (e.g. "Click at (412, 230) — 'Terminal'") and Confirm/Skip buttons.

## Layout rules

- Spacing scale: 4, 8, 12, 16, 20 pt (macOS standard). Sheet padding 20 pt.
- Library Window: sidebar 220–320 pt (resizable), detail pane with machine info and a large "Connect" button. Minimum window size 720 × 480.
- Session Window: the framebuffer fills the content area. Letterbox in black when the aspect ratios differ. Minimum 640 × 400.
- Scaling (⌘⌥S): **Fit** scales the framebuffer up or down to the content area, aspect ratio kept, centered (linear filtering). **Actual size** shows one remote pixel per device pixel of the local display, so it is pixel-exact (nearest filtering): a 2880 × 1800 Retina remote takes 1440 × 900 pt on a Retina Mac, a 1920 × 1080 remote 960 × 540 pt. Smaller than the content area → centered on black; larger → clipped, the visible part set by a scroll offset (panning UI: Session Window).
- Machine Editor sheet: 460 pt wide.
- No breakpoints (desktop only). In full screen, the toolbar reveals on hover at the top edge.

## Per-screen notes

- **Onboarding Sheet:** 3 pages, 520 × 400 pt, a large SF Symbol, one sentence and one primary button per page.
- **Library Window:** groups as collapsible sidebar sections. Favorites section pinned at the top. The detail pane shows name, host:port (mono), kind, last connected, and a status line. The sidebar status dot and the status line come with reachability monitoring (T4.5); until then rows show no dot.
- **Machine Editor:** the kind picker comes first, because it changes the fields (Anthropic VM hides the user field and shows an 11 pt secondary note under the password, which is optional; Mac ARD requires the user field). The "Test" button sits next to "Save".
- **Discovery Panel:** popover-sized sheet 420 × 360 pt, title on top, "Close" (Esc) at the bottom right. Each row shows the kind symbol, name, host in SF Mono (`:port` when not 5900) and service types in 11 pt secondary ("Screen Sharing · Remote Management"), with an "Add" button on the right; machines already added are greyed (50 %) with "Already added" instead of the button. Searching, empty, blocked and failed states use `ContentUnavailableView` with their one action (Retry / Open System Settings).
- **Session Window:** the remote screen is the hero. Connecting overlay centered over the screen dimmed to 60 % black (spinner, "Connecting to <name>…", Cancel). Keyboard-capture state shown as a toolbar pill: "Keyboard captured — ⌃⌥⌘R to release" (AppFlow › Keyboard capture), shown only while captured. Without Accessibility access, a toolbar button next to the pill reads "System shortcuts need Accessibility access — Open Settings"; it opens System Settings › Privacy & Security › Accessibility. Then two icon buttons with tooltips: scaling (fit ↔ actual size, ⌥⌘S) and Disconnect. On an error, the banner sits under the toolbar and the last frame stays behind it, dimmed to 35 %. Actual-size panning (scroll offset) is not built yet.
- **Claude Assistant Panel:** prompt field at the bottom, history above, and a token counter for the session at the top-right in 11 pt secondary.
- **Session History View:** `Table` with columns Machine, Started, Connect time (ms), Duration, Outcome. Summary strip above: sessions in the last 30 days, p90 connect time, ARD/Screen Sharing usage note.
- **Settings Window:** standard tabbed settings (General, Sync, Claude, Notifications).
- **Menu Bar Extra:** menu with favorites, a separator, the 5 most recent machines, "Open Library…" and "Quit".

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
- **Success:** green check for the connection test; a brief toast for clipboard.

## Required assets

- App icon (1024 pt master, macOS rounded-square template). *(assumption: to be designed; a monitor glyph with a remote "deck" stack)*
- SF Symbols only for UI icons: `desktopcomputer`, `display`, `sparkles`, `antenna.radiowaves.left.and.right`, `doc.on.clipboard`, `clock.arrow.circlepath`, `bell`.
- No illustrations.
- README and release-page screenshots: Library Window, Session Window with Claude Assistant Panel.
