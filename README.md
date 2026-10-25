# RemoteDeck

Native macOS client for remote screens: Macs over Apple Remote Desktop / RFB-VNC, and Anthropic computer use environments over VNC, with an optional Claude Assistant that can describe the remote screen or act on it, one confirmed action at a time.

[![Release](https://img.shields.io/github/v/release/vincentlauriat/RemoteDeck?label=release)](https://github.com/vincentlauriat/RemoteDeck/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-555555)](LICENSE)

## Install

1. Download the latest `RemoteDeck-<version>.dmg` from the [GitHub Releases page](https://github.com/vincentlauriat/RemoteDeck/releases/latest).
2. Open it and drag **RemoteDeck** to **Applications**.

Requires **macOS 15 Sequoia or later**. The DMG is signed with an Apple Developer ID, built with the Hardened Runtime and sandboxed, then notarized and stapled by Apple: it opens with a double-click, without a Gatekeeper warning. After that, **RemoteDeck › Check for Updates…** (Sparkle) installs new versions; it also checks once a day.

First launch:

- **Local Network.** macOS asks whether RemoteDeck may find devices on your local network. Allow it to use Bonjour Discovery and to reach machines on your LAN (System Settings › Privacy & Security › Local Network, if you said no).
- **Accessibility (optional).** To send system shortcuts such as ⌘Tab or ⌘Space to the remote Mac instead of your own, grant Accessibility to RemoteDeck (System Settings › Privacy & Security › Accessibility). Without it, sessions work and those shortcuts stay local.
- **Notifications (optional).** Asked only when you click "Allow notifications", for watched machines going offline or coming back.
- **iCloud.** Machine Library sync uses your iCloud account; turn it on in onboarding or in Settings › iCloud.

## Features

| Feature | What it does |
|---|---|
| Machine Library | All remote machines in one sidebar with saved credentials (Keychain), groups, favorites and search |
| Screen Session | View and control a remote Mac (ARD, Diffie-Hellman auth) or a VNC desktop; Raw, CopyRect, ZRLE and Tight decoding, Metal rendering |
| Bonjour Discovery | Find Macs with Screen Sharing or Remote Management on the LAN |
| Anthropic VM Connect | Open a Claude computer use environment (VNC endpoint) like any other machine |
| Shared Clipboard | Copy and paste text both ways, Extended Clipboard (UTF-8) when the server supports it |
| Session Tabs | Several sessions as tabs of one window, ⌘1…⌘9 |
| iCloud Sync | The same Machine Library on all your Macs; passwords through iCloud Keychain |
| Claude Assistant | Ask Claude about the remote screen or give it a task; every action waits for your Confirm |
| Status Notifications | A notification when a watched machine goes offline or comes back |
| Session History | Local log of sessions with a 30-day summary and CSV export; Menu Bar Extra for quick connect |
| Session resilience | One automatic reconnect after a drop, a clean stop before sleep and a reconnect after wake |
| Updates | Sparkle 2, EdDSA-signed, from this repository's GitHub Releases |

## Build

Requirements: Xcode (stable), macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate                                   # regenerate RemoteDeck.xcodeproj (not versioned)
xcodebuild -project RemoteDeck.xcodeproj -scheme RemoteDeck build
xcodebuild -project RemoteDeck.xcodeproj -scheme RemoteDeck CODE_SIGNING_ALLOWED=NO test   # all four suites
cd Packages/RFBKit && swift test                    # RFBKit tests alone (faster)
cd Packages/RemoteDeckCore && swift test            # models / Keychain / validation
cd Packages/ClaudeKit && swift test                 # Claude Assistant: Messages API, computer use toolset (fake HTTP)
```

Release (maintainer): `CLOUDKIT_SCHEMA_DEPLOYED=1 ./Scripts/release.sh <version>` after bumping `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`; `./Scripts/release.sh --dry-run <version>` stops before notarization. `./Scripts/prepublic-check.sh` runs gitleaks and the history checks.

## Project layout

```
RemoteDeck/            # app target (SwiftUI + AppKit)
Packages/RFBKit/       # RFB/VNC protocol library, no UI dependency
Packages/RemoteDeckCore/ # SwiftData models, Keychain store, validation
Packages/ClaudeKit/    # Claude Assistant protocol side: Messages API client, computer use toolset, screenshots
RemoteDeckTests/       # hosted app tests
Scripts/               # release.sh (archive → Developer ID → DMG → notarize → appcast), prepublic-check.sh, DMG and icon generators
appcast.xml            # Sparkle feed (one item per release)
project.yml            # XcodeGen config
PRD.md TRD.md AppFlow.md DesignBrief.md BackendSchema.md ImplementationPlan.md   # specs
```

## Roadmap

- [x] Framing documents
- [x] Step 1 — project setup (T1.4 live test hosts pending)
- [x] Step 2 — data and authentication
- [x] Step 3 — main user path (P0)
- [x] Step 4 — secondary features (P1); live two-Mac sync check pending
- [ ] Step 5 — quality: resilience, security review and parser fuzzing done; accessibility pass (T5.2) and 4K performance (T5.4) pending
- [ ] Step 6 — go-live: release pipeline ready (Sparkle, dmgbuild, notarization checks); clean-Mac test run, CloudKit Production schema and first release pending

## License

MIT — see [`LICENSE`](LICENSE).
