# RemoteDeck

Native macOS client for remote screens: Macs over Apple Remote Desktop / RFB-VNC, and Anthropic computer use environments over VNC. *(Provisional name — work in progress.)*

## Status

Spec stage complete; project skeleton in place (step 1 of `ImplementationPlan.md`). See `PRD.md` for features and roadmap.

## Build

Requirements: Xcode (stable), macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate                                   # regenerate RemoteDeck.xcodeproj (not versioned)
xcodebuild -project RemoteDeck.xcodeproj -scheme RemoteDeck build
xcodebuild -project RemoteDeck.xcodeproj -scheme RemoteDeck test   # runs RFBKit tests
cd Packages/RFBKit && swift test                    # RFBKit tests alone (faster)
cd Packages/RemoteDeckCore && swift test            # models / Keychain / validation
```

## Project layout

```
RemoteDeck/            # app target (SwiftUI + AppKit)
Packages/RFBKit/       # RFB/VNC protocol library, no UI dependency
Packages/RemoteDeckCore/ # SwiftData models, Keychain store, validation
RemoteDeckTests/       # hosted app tests
Scripts/               # release.sh, icon and DMG background generators
project.yml            # XcodeGen config
PRD.md TRD.md AppFlow.md DesignBrief.md BackendSchema.md ImplementationPlan.md   # specs
```

## Roadmap

- [x] Framing documents
- [ ] Step 1 — project setup (T1.1 done; T1.2–T1.4 in progress)
- [ ] Step 2 — data and authentication (T2.1–T2.4 done; T2.5 RFB auth pending)
- [ ] Step 3 — main user path (P0)
- [ ] Step 4 — secondary features (P1)
- [ ] Step 5 — quality
- [ ] Step 6 — go-live

## License

MIT — see [`LICENSE`](LICENSE).
