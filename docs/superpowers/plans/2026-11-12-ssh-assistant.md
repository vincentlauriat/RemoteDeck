# Terminal Assistant (SSH) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Assistant Panel in SSH terminal tabs that reads the terminal as text and proposes one confirmed line or key sequence at a time, with Claude or Apple on-device.

**Architecture:** A sibling of the screen assistant: `TerminalAssistantModel` over a `TerminalAssistantPort` (`TerminalSessionModel`) and a `TerminalAssistantEngine` (`TerminalClaudeEngine`, `TerminalAppleEngine`). The provider-neutral confirmation rules move into a shared `AssistantDecisionGate` that the screen `AssistantModel` also uses, with no behaviour change. Pure parts (snapshot, validation, password detection, settling) are value types tested without UI.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, ClaudeKit (raw Messages API), FoundationModels (weak-linked), libghostty-vt via `GhosttyEngine`, swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-12-ssh-assistant-design.md`

## Global Constraints

- macOS 15 deployment target; FoundationModels only in `RemoteDeck/Assistant/AppleFoundationModels.swift` and the new `RemoteDeck/Assistant/Terminal/TerminalAppleFoundationModels.swift`, every symbol `@available(macOS 26.0, *)` (terminal) or `macOS 27` (screen, unchanged); still `LC_LOAD_WEAK_DYLIB`.
- Swift 6 language mode; fix isolation errors with `@MainActor`/`Sendable`, never by downgrading.
- The screen assistant's request body stays byte-identical (golden test, Task 1).
- Model `claude-opus-5-5`, thinking `{adaptive, display: "updates"}` + beta header, effort `medium`, top-level `cache_control` — same as `ClaudeAPI` today.
- Tools: `run_command {command, reason}`, `send_keys {keys, reason}` (confirmed), `wait_for_output {seconds 1…120, reason}` (automatic); `strict: true`, `additionalProperties: false`.
- Keys enum: `ctrl_c, ctrl_d, escape, q, return, tab, up, down, left, right, page_up, page_down`.
- Command: one line, 1…4000 characters, no C0 (U+0000–U+001F), DEL (U+007F) or C1 (U+0080–U+009F); typed with `\r` in the same writer chunk.
- Scrollback for Claude ≤ 200 lines and ≤ 16 000 characters; Apple gets the viewport only; Apple step summary = last 6.
- Settling: quiet 700 ms; 2 s with no first output → measured from Return; cap 15 s after a confirmed action; `wait_for_output` cap = its `seconds` (≤ 120).
- Arming 400 ms; pause after `maxStepsWithoutAction` = 8 turns without a confirmed action (`wait_for_output` counts as such a turn; the password wait does not advance it).
- No password, passphrase or Keychain item in any request; the assistant never types on a password prompt.
- Records: kinds `command` / `keys`; command payload `{"length": N, "program": "<first word>"}`, keys payload `{"keys": [...]}`; never the command text.
- Tests: no Anthropic API, no FoundationModels, no socket, no Keychain; demo modes use scripted engines.
- UI strings in both `fr` and `en` (`Localization/Strings.swift`).
- ⌘K toggles the panel in terminal tabs (same as screen tabs).
- Commits: conventional, English, no Co-Authored-By trailer; stage explicit paths (never the local `CLAUDE.md` RTK block).

## Review Focus

1. **Non-ASCII commands** (accents, emoji, CJK, `printf 'é'`) must be accepted and typed exactly; only control characters are refused. → test in Task 2.
2. **Tab closed or shell exited while a decision or a settling wait is pending**: no bytes typed afterwards, the row ends `cancelled`, no crash. → test in Task 6.
3. **A password prompt appearing mid-settling** (`sudo apt …`): settling returns at once and the model is not called again until Continue. → test in Task 6.
4. **The user types in the terminal while the panel waits for Confirm**: the user's keys reach the shell; only bytes during the assistant's own send are held back. → test in Task 5.
5. **Wide characters and a resized terminal** between proposal and Confirm: the snapshot is re-read after Confirm, and rows with double-width cells render without padding garbage. → tests in Tasks 2 and 6.

---

### Task 1: ClaudeKit — custom tools and plain tool results, screen request frozen

**Files:**
- Modify: `Packages/ClaudeKit/Sources/ClaudeKit/ClaudeAPI.swift` (`RequestConfiguration`)
- Modify: `Packages/ClaudeKit/Sources/ClaudeKit/Conversation.swift:72-125`
- Test: `Packages/ClaudeKit/Tests/ClaudeKitTests/RequestTests.swift`, new `Packages/ClaudeKit/Tests/ClaudeKitTests/CustomToolTests.swift`

**Interfaces:**
- Produces: `RequestConfiguration.tools: [JSONValue]` (default `[ClaudeAPI.computerToolset]`); `init(model:maxTokens:effort:system:tools:)` with `tools` defaulted; `ContentBlock.plainToolResult(id: String, text: String, isError: Bool = false) -> JSONValue` (no `toolset_name`).

- [ ] **Step 1: Golden test first, against current code.** `screenRequestBodyIsUnchanged`: build a `Conversation(configuration: .init(desktop: .mac))`, append a fixed user prompt + fixed screenshot block, take `requestBody()`; save the bytes as a fixture `Tests/ClaudeKitTests/Fixtures/screen-request.json` from the **unmodified** code; the test asserts `requestBody() == fixture`. Same for `.x11`.
- [ ] **Step 2:** `cd Packages/ClaudeKit && swift test --filter RequestTests` → PASS (fixture captured from current code).
- [ ] **Step 3: Failing tests** in `CustomToolTests`: `customToolsReplaceTheToolset` (body's `tools` equals the given array, no `computer_toolset_20260801`); `plainToolResultHasNoToolsetName` (`type: tool_result`, `tool_use_id`, text content, `is_error` only when true, no `toolset_name` key).
- [ ] **Step 4:** run → FAIL (no `tools` parameter).
- [ ] **Step 5:** implement; `requestBody()` writes `field("tools", configuration.tools)`.
- [ ] **Step 6:** `swift test` in ClaudeKit → all PASS, golden unchanged.
- [ ] **Step 7:** commit `feat(claudekit): allow custom tools and plain tool results`.

### Task 2: Pure terminal pieces — snapshot, validation, password prompt

**Files:**
- Create: `RemoteDeck/Assistant/Terminal/TerminalSnapshot.swift`, `TerminalCommandValidator.swift`, `PasswordPromptDetector.swift`
- Modify: `Packages/GhosttyVT/Sources/GhosttyEngine/VTTerminal.swift` (viewport/scrollback split helper only if `screenText()` cannot be split by row count; prefer `rows` × `screenText()` tail)
- Test: `RemoteDeckTests/TerminalAssistantPureTests.swift`

**Interfaces:**
- Produces:
  - `struct TerminalSnapshot: Equatable, Sendable { var screen: [String]; var scrollback: [String]; var cursorRow: Int?; var cursorColumn: Int?; var isAlternateScreen: Bool; var title: String; var columns: Int; var rows: Int; var promptLine: String? { get } ; func rendered(includeScrollback: Bool) -> String; func bounded(maxLines: Int = 200, maxCharacters: Int = 16_000) -> TerminalSnapshot }`
  - `enum TerminalCommandValidator { static func validate(_ command: String, snapshot: TerminalSnapshot, connected: Bool) -> CommandRefusal? }`, `enum CommandRefusal: Equatable { case empty, tooLong, controlCharacter, fullScreenProgram, passwordPrompt, notConnected }`
  - `enum PasswordPromptDetector { static func isShowing(in snapshot: TerminalSnapshot) -> Bool }`
  - `enum TerminalNamedKey: String, CaseIterable, Codable, Sendable` (the 12 keys) with `var bytes: Data` for the primary-screen encoding (`ctrl_c` = 0x03, `return` = 0x0D, `up` = `ESC [ A`; arrows use `ESC O A` when DECCKM is on — take a `cursorKeysApplication: Bool` parameter).

- [ ] **Step 1: Failing tests** (`TerminalAssistantPureTests`):
  - `validationTable`: `""`→`.empty`; 4001×`a`→`.tooLong`; `"ls\n"`, `"ls\r"`, `"a\u{1B}b"`, `"a\u{7F}"`, `"a\u{85}"`, `"a\tb"`→`.controlCharacter`; alternate screen→`.fullScreenProgram`; password prompt→`.passwordPrompt`; `connected: false`→`.notConnected`; `"printf 'é 🎉 日本'"`→`nil`.
  - `passwordPrompts`: true for cursor rows `"[sudo] password for pi: "`, `"Password:"`, `"pi@host's password: "`, `"Enter passphrase for key '/x': "`, `"Enter PIN for 'y':"` with the cursor at line end; false for `"password: set"` with the cursor elsewhere, and for `"$ echo password:"` when the cursor is not on that row.
  - `snapshotBounds`: 500 scrollback lines → 200 kept (newest); 20 000 chars → ≤ 16 000 kept (newest whole lines); `rendered(includeScrollback: false)` contains no scrollback line.
  - `wideCharactersRenderWithoutPadding`: a row of `"日本語"` from the surface is `"日本語"`, not with spacer cells.
  - `promptLineIsTheCursorRow`.
- [ ] **Step 2:** `xcodebuild … CODE_SIGNING_ALLOWED=NO test "-only-testing:RemoteDeckTests/TerminalAssistantPureTests"` → FAIL (types missing).
- [ ] **Step 3:** implement. `rendered` format: `<terminal cols=C rows=R alternate=yes|no title="…" cursor=row,col>` newline, `--- scrollback ---` lines (if any), `--- screen ---` lines, `</terminal>`.
- [ ] **Step 4:** run → PASS. **Step 5:** `xcodegen generate` (new files) then commit `feat(assistant): terminal snapshot, command validation and password prompt detection`.

### Task 3: Shared decision gate, screen assistant unchanged

**Files:**
- Create: `RemoteDeck/Assistant/AssistantDecisionGate.swift`
- Modify: `RemoteDeck/Assistant/AssistantModel.swift` (arming, `withCheckedContinuation` decision, step counter use the gate)
- Test: `RemoteDeckTests/AssistantDecisionGateTests.swift`; existing `AssistantModelTests` etc. must pass **unmodified**

**Interfaces:**
- Produces: `@MainActor final class AssistantDecisionGate { enum Decision: Equatable { case confirmed, skipped, stopped }; init(armDelay: Duration = .milliseconds(400), sleep: @escaping @Sendable (Duration) async -> Void); var pendingID: String? { get }; var isArmed: Bool { get }; func await(id: String) async -> Decision; func confirm(id: String); func skip(id: String); func stopAll(); var stepsWithoutAction: Int { get }; func recordTurn(confirmedAction: Bool); static let maxStepsWithoutAction = 8; var shouldPause: Bool { get }; func resetSteps() }`

- [ ] **Step 1: Failing tests:** `confirmBeforeArmingIsIgnored`, `confirmAfterArmingResolves`, `confirmWithAnotherIDIsIgnored`, `stopResolvesPendingAsStopped`, `pausesAfterEightTurnsWithoutAction`, `aConfirmedActionResetsTheCounter`.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement; move the logic out of `AssistantModel` and call the gate there.
- [ ] **Step 4:** run `AssistantDecisionGateTests`, `AssistantModelTests`, `AssistantSessionTests`, `AssistantReleasePassTests`, `AssistantDemoTests`, `AppleEngineTests` → PASS, no test edited. If keeping them green needs a behaviour change, stop and copy the logic instead (spec fallback), listing the invariants in the gate's doc comment.
- [ ] **Step 5:** commit `refactor(assistant): extract the decision gate shared by assistants`.

### Task 4: Output settling

**Files:**
- Create: `RemoteDeck/Assistant/Terminal/OutputSettler.swift`
- Test: `RemoteDeckTests/OutputSettlerTests.swift`

**Interfaces:**
- Produces: `enum OutputWait: Equatable { case settled, commandEnded(exitCode: Int?), stillRunning(seconds: Int), passwordPrompt, sessionEnded }`; `@MainActor final class OutputSettler { init(clock: any ReachabilityClock, quiet: Duration = .milliseconds(700), firstOutputGrace: Duration = .seconds(2)); func outputArrived(); func commandEnded(exitCode: Int?); func sessionEnded(); func wait(cap: Duration, snapshot: @MainActor () -> TerminalSnapshot?) async -> OutputWait }` — checks `PasswordPromptDetector` on every wake.

- [ ] **Step 1: Failing tests** with `FakeReachabilityClock`: `settlesAfterQuietPeriod`; `noOutputSettlesAfterGrace`; `commandEndWinsAtOnce`; `capGivesStillRunning(15)`; `passwordPromptEndsTheWaitAtOnce`; `sessionEndedEndsTheWait`. (Wait for `pending(...)` before `fire`, as `SessionResilienceTests` do.)
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS. **Step 5:** commit `feat(assistant): settle terminal output after a command`.

### Task 5: The port on `TerminalSessionModel`

**Files:**
- Create: `RemoteDeck/Assistant/Terminal/TerminalAssistantPort.swift`
- Modify: `RemoteDeck/SSH/TerminalSessionModel.swift` (`deliver(_:)` feeds the settler; `send(_:)` hold-back; conformance), `RemoteDeck/SSH/TerminalSurface.swift` (`func snapshot() -> TerminalSnapshot?` on the protocol; `GhosttyTerminalSurface` and `FakeTerminalSurface` implement it; OSC 133 COMMAND_END via `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT` → `onCommandEnd: ((Int?) -> Void)?` in `VTTerminal`)
- Test: `RemoteDeckTests/TerminalAssistantPortTests.swift`

**Interfaces:**
- Consumes: `TerminalSnapshot`, `OutputSettler`, `TerminalNamedKey` (Tasks 2, 4).
- Produces: `@MainActor protocol TerminalAssistantPort: AnyObject { var assistantCanAct: Bool { get }; func assistantSnapshot() async -> TerminalSnapshot?; func assistantType(_ command: String); func assistantSendKeys(_ keys: [TerminalNamedKey]); func assistantWaitForOutput(cap: Duration) async -> OutputWait; func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction?; func assistantSave(); func assistantAddTokens(_ count: Int); var assistantIsSending: Bool { get set } }`; `TerminalSessionModel.terminalAssistant: TerminalAssistantModel?`.
- `AssistantActionKind` (RemoteDeckCore `ModelEnums.swift`) gains `.command`, `.keys`.

- [ ] **Step 1: Failing tests** (fake connection + fake surface): `typeSendsCommandAndReturnInOneChunk` (writer receives exactly `"df -h\r"` once); `sendKeysEncodesNamedKeys`; `nothingIsTypedWhenNotConnected`; `userInputPassesWhileWaitingForConfirm` and `userInputIsHeldBackWhileTheAssistantSends` (Review Focus 4); `snapshotWaitsForPendingBytes`; `commandEndFromOSC133ReachesTheSettler`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS + `cd Packages/GhosttyVT && swift test` + `cd Packages/RemoteDeckCore && swift test`. **Step 5:** commit `feat(ssh): terminal assistant port on the terminal session`.

### Task 6: `TerminalAssistantModel`

**Files:**
- Create: `RemoteDeck/Assistant/Terminal/TerminalAssistantModel.swift`, `TerminalAssistantEngine.swift`
- Test: `RemoteDeckTests/TerminalAssistantModelTests.swift` (+ `FakeTerminalAssistantPort`, `ScriptedTerminalEngine` in the test target)

**Interfaces:**
- Consumes: `AssistantDecisionGate`, `TerminalAssistantPort`, `TerminalCommandValidator`, `OutputWait`.
- Produces:
  - `enum TerminalAction: Equatable { case runCommand(String), sendKeys([TerminalNamedKey]), waitForOutput(seconds: Int) }`
  - `struct TerminalTurnAction: Equatable { var id: String; var action: TerminalAction?; var parseError: String?; var reason: String? }`
  - `enum TerminalTurnBlock: Equatable { case answer(String), progress(String), action(TerminalTurnAction) }`, `struct TerminalTurn: Equatable { var blocks: [TerminalTurnBlock]; var stop: TurnStop; var usage: TokenUsage? }`
  - `struct TerminalActionOutcome: Equatable { var id: String; var text: String; var snapshot: TerminalSnapshot?; var isError: Bool }`
  - `@MainActor protocol TerminalAssistantEngine: AnyObject { var provider: AssistantProvider { get }; var isReady: Bool { get }; var notReadyReason: AssistantFailure? { get }; var hasConversation: Bool { get }; var canResend: Bool { get }; func begin(prompt: String, snapshot: TerminalSnapshot); func nextTurn() async throws(AssistantEngineError) -> TerminalTurn; func deliver(_ outcomes: [TerminalActionOutcome]); func reset() }`
  - `@MainActor @Observable final class TerminalAssistantModel { enum Phase: Equatable { case idle, running, awaitingDecision(id: String), waitingForUser(WaitReason), paused, stopping, failed(AssistantFailure), finished }; enum WaitReason: Equatable { case password }; init(port: any TerminalAssistantPort, provider: @escaping () -> AssistantProvider, makeEngine: @escaping (AssistantProvider) -> any TerminalAssistantEngine, gate: AssistantDecisionGate = .init(…)); func ask(_ prompt: String); func confirm(id: String); func skip(id: String); func stop(); func continueAfterPause(); func continueAfterUser(); func newConversation(); func syncProvider(); func sessionEnded(); func shellReconnected() }`

- [ ] **Step 1: Failing tests** (scripted engine, fake port, fake clock):
  - `answerOnlyFinishesWithoutTyping`.
  - `commandIsTypedOnlyAfterConfirm` (port typed nothing before `confirm`, exactly once after).
  - `skipAnswersSkippedAndTypesNothing`; `stopDuringDecisionTypesNothing`.
  - `invalidCommandIsRefusedWithoutAProposal` (`"ls\n"` → outcome `Refused: …`, phase never `.awaitingDecision`).
  - `fullScreenRefusesRunCommandButAllowsSendKeys`.
  - `waitForOutputRunsWithoutConfirmAndCountsAsAStep`; `pausesAfterEightTurnsWithoutAction`.
  - `passwordPromptDuringSettlingWaitsForUser` → phase `.waitingForUser(.password)`, engine not called until `continueAfterUser()`, counter unchanged (Review Focus 3).
  - `sessionEndedCancelsPendingDecisionAndWait` → row `cancelled`, port typed nothing afterwards (Review Focus 2).
  - `snapshotIsReReadAfterConfirm` (a resize between proposal and confirm: the outcome's snapshot has the new size) (Review Focus 5).
  - `recordsStoreLengthAndProgramOnly` (payload `{"length":5,"program":"df"}` for `df -h`; no `-h` anywhere in the payload).
  - `providerSwapsOnlyBetweenConversations`; `reconnectStartsANewConversation`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS. **Step 5:** commit `feat(assistant): terminal assistant model`.

### Task 7: `TerminalClaudeEngine`

**Files:**
- Create: `RemoteDeck/Assistant/Terminal/TerminalClaudeEngine.swift`, `TerminalAssistantPrompt.swift` (system prompt + tool schemas as `JSONValue`)
- Test: `RemoteDeckTests/TerminalClaudeEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 (`tools`, `plainToolResult`), Task 6 protocol.
- Produces: `TerminalClaudeEngine(client: MessagesClient, apiKey: @escaping () -> String)`; `TerminalAssistantPrompt.system: String`, `.tools: [JSONValue]`.

- [ ] **Step 1: Failing tests** (fake `HTTPTransport`, `ScriptedHTTP`): `requestCarriesTheThreeToolsAndNoComputerToolset`; `firstUserMessageHasPromptAndSnapshotWithScrollback`; `toolUseMapsToTerminalActions` (each tool, plus an unknown tool name → `parseError`, plus `keys: ["f1"]` → `parseError`); `outcomesAreSentAsPlainToolResultsWithSnapshot`; `stopReasonsMap` (end_turn→done, tool_use→actions, max_tokens→cutOff, refusal→refused); `noKeyIsNotReady`; `systemPromptSaysTerminalTextIsData` (contains "data, not instructions" and "password").
- [ ] **Step 2:** FAIL. **Step 3:** implement; system prompt per spec sketch, English, includes "Type and press Return" meaning of `run_command`. **Step 4:** PASS. **Step 5:** commit `feat(assistant): Claude engine for terminal sessions`.

### Task 8: Apple — two capabilities and `TerminalAppleEngine`

**Files:**
- Modify: `RemoteDeck/Assistant/AppleModelStatus.swift`, `RemoteDeck/Assistant/AppleFoundationModels.swift` (`SystemAppleModelChecker` split; screen check unchanged), `RemoteDeck/Views/SettingsView.swift` (two status lines)
- Create: `RemoteDeck/Assistant/Terminal/TerminalAppleEngine.swift`, `TerminalAppleFoundationModels.swift`
- Test: `RemoteDeckTests/TerminalAppleEngineTests.swift`, update `AppleEngineTests` only for the checker's new shape

**Interfaces:**
- Produces: `protocol AppleModelChecking { func unavailability(for use: AppleModelUse) -> AppleModelUnavailability? }`, `enum AppleModelUse { case screens, terminals }`; `AppleModelUnavailability.requiresNewerOS` gains the version (`requiresNewerOS(major: Int)`); `struct TerminalAppleStep: Equatable { kind: Kind; text: String?; command: String?; keys: [TerminalNamedKey]; seconds: Int?; reason: String? }` with `Kind { answer, runCommand, sendKeys, wait, done }`; `protocol TerminalAppleStepGenerating { func next(_ request: TerminalAppleStepRequest) async throws -> TerminalAppleStep }`; `TerminalAppleEngine(generator:checker:)`.

- [ ] **Step 1: Failing tests** (`ScriptedTerminalAppleSteps`): `stepsMapToActions`; `requestHasViewportOnlyAndLastSixSummaries`; `contextExceededIsCutOff`; `refusalIsRefused`; `terminalsReadyOnMacOS26WithoutVision` (fixed checker); `screensStillRequire27`; `settingsShowBothLines` (strings).
- [ ] **Step 2:** FAIL. **Step 3:** implement; `@Generable GeneratedTerminalStep` under `@available(macOS 26.0, *)`. **Step 4:** PASS; build, then `otool -l "build/DerivedData/Build/Products/Debug/RemoteDeck Dev.app/Contents/MacOS/RemoteDeck Dev.debug.dylib" | grep -A2 FoundationModels` shows `LC_LOAD_WEAK_DYLIB`. **Step 5:** commit `feat(assistant): Apple on-device engine for terminal sessions`.

### Task 9: Panel, toolbar, wiring, strings

**Files:**
- Create: `RemoteDeck/Views/TerminalAssistantPanelView.swift`
- Modify: `RemoteDeck/Views/TerminalSessionView.swift` (`.inspector`, 320 pt; sparkles toggle ⌘K in the toolbar group, shown when connected), `RemoteDeck/Session/SessionManager.swift` (`makeTerminalAssistant` closure, called in `terminal(for:)`; `sessionEnded()` before every terminal teardown path: close, suspend, network-loss close, reconnect, `Phase.ended`), `RemoteDeck/RemoteDeckApp.swift`, `RemoteDeck/Localization/Strings.swift`
- Test: `RemoteDeckTests/TerminalAssistantPanelRenderingTests.swift` (offscreen PNGs in `$TMPDIR/RemoteDeckTerminalAssistantSnapshots/`), `StringsTests`

**Interfaces:**
- Consumes: Tasks 6–8.

- [ ] **Step 1: Failing tests:** `panelRendersAProposedCommandVerbatim` (a 300-character command fully present in the accessibility tree, monospaced, no reveal button); `panelShowsThePromptLineAndNonEmptyNote`; `passwordWaitShowsContinue`; `destructiveBadgeIsShownForRmRf`; `stringsMatchInBothLanguages`; `teardownPathsCallSessionEnded` (SessionManager with fakes: close, suspend, reconnect, shell exit).
- [ ] **Step 2:** FAIL. **Step 3:** implement; reuse the screen panel's non-computer subviews (header, prompt field, failure banners, API key link) by moving them to a shared file if needed. Strings: `assistant_terminal_*` keys incl. "Type and press Return", "The command line isn't empty", "Type your password in the terminal, then click Continue", "New shell — start a new conversation", "Screens: …", "Terminals: …".
- [ ] **Step 4:** PASS; read the PNGs by eye (fr and en, light and dark). **Step 5:** commit `feat(ssh): assistant panel in terminal tabs`.

### Task 10: Demo mode, docs, full verification

**Files:**
- Modify: `RemoteDeck/LibraryDemo/LibraryDemo.swift`, `LibraryDemoSSH.swift` (mode `ssh-assistant`: "Raspberry" connected, panel open, scripted engine: explains a canned `df -h`, proposes `du -sh /var/log/*`, Confirm types it, the fake shell prints a canned answer), `RemoteDeckTests/LibraryDemoTests.swift`, `RemoteDeckTests/AppUpdaterTests.swift` (mode list)
- Docs: `PRD.md`, `TRD.md` (Claude Assistant › Terminal), `AppFlow.md` (Terminal tab › Assistant Panel), `DesignBrief.md`, `BackendSchema.md` (`command`/`keys` kinds, payloads), `ImplementationPlan.md` (Step 9: T9.1…, traceability), `CLAUDE.md` (architecture bullet + demo mode in Commands; do not stage the unrelated RTK block), `README.md` (Features row)

- [ ] **Step 1: Failing test:** `sshAssistantDemoUsesScriptedEngineOnly` (no `MessagesClient` transport, no FoundationModels checker other than `FixedAppleModelChecker`).
- [ ] **Step 2:** FAIL. **Step 3:** implement; update docs in the same commit.
- [ ] **Step 4: Full verification:** `xcodegen generate`; `xcodebuild … -allowProvisioningUpdates build` → BUILD SUCCEEDED; `xcodebuild … CODE_SIGNING_ALLOWED=NO test` → TEST SUCCEEDED (all suites); `swift test` in ClaudeKit, GhosttyVT, RemoteDeckCore, RFBKit, SSHKit → PASS; launch `-LibraryDemo ssh-assistant`, confirm the flow on screen.
- [ ] **Step 5:** commit `feat(demo): ssh-assistant demo mode and docs`.
