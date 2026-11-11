# Apple Foundation Models as a second assistant provider — design

Date: 2026-11-11. Status: approved scope (Vincent, 2026-11-11: "1 et prévoir PCC").

## Intent

The Claude Assistant Panel only works with an Anthropic API key. Vincent wants the same panel to
run on Apple's Foundation Models, chosen in Settings next to the Anthropic key: no key, no bill, and
for the on-device model nothing leaves the Mac. Private Cloud Compute (PCC) is planned, not built.

## Measured facts (2026-11-10, this Mac, Xcode 27.1, macOS 27.0 SDK)

| | On-device `SystemLanguageModel.default` | `PrivateCloudComputeLanguageModel` |
|---|---|---|
| Availability | available | `available` reported, but every request fails (`ModelManagerError 1046`) |
| Capabilities | vision, toolCalling, guidedGeneration; no reasoning | vision, toolCalling, guidedGeneration, reasoning |
| Context | 8,192 tokens | 32,768 tokens |
| Image cost | ~137 tokens whatever the size (downscaled internally) | not measured |
| Access | any app | managed entitlement granted by Apple ("Accessing Private Cloud Compute") |

Spikes (throwaway, scratchpad, not in the repo):

- **Coordinate clicks fail.** Asked to click the centre of a coloured rectangle on a 1280 × 800
  image, in pixels or normalised 0–1000, the on-device model missed by hundreds of pixels and
  disagreed with itself across runs. It cannot ground pointer coordinates.
- **Label clicks mostly work.** Guided generation of a `NextStep { kind, label, reason }` on a real
  Finder screenshot, the label located by Vision `VNRecognizeTextRequest`: 7/10 right element
  (TextEdit, Xcode, WhatsApp, Utilities: right; "the backup app" → Zendure twice: wrong). One run hit
  "8193 tokens exceeds 8192" with one image and a one-line prompt: the context is tight.
- Latency: 1.5–4 s per step.

## Goals

1. Settings › Assistant: a provider picker, **Claude (Anthropic API)** or **Apple (on device)**. The
   API key section shows only for Claude; Apple shows its availability (ready / device not eligible
   / Apple Intelligence off / model downloading) with the reason in fr and en.
2. With Apple selected, the same Assistant Panel works: prompt → the model sees the screen →
   answers, or proposes **one** action per step. Every action that reaches the remote still waits for
   Confirm (arm delay, type reveal, Skip, Stop, `maxStepsWithoutAction` pause, AssistantAction rows):
   the safety rules of T4.4/T5.3 are provider-independent.
3. Apple actions: `answer` (text only, ends the task), `click` / `doubleClick` / `rightClick` **on a
   visible text label**, `typeText`, `pressKey` (a key chord in `KeyChord` syntax), `scroll`
   (up/down/left/right at the screen centre or at a label), `wait`, `done`. **No raw coordinates**:
   the generable schema has no x/y field, so the model cannot propose one.
4. A label is resolved to a point by OCR on the very screenshot the model saw; the proposal row and
   the framebuffer highlight show the resolved point before Confirm. A label not found, or found
   more than once with no exact match, never becomes a click: the step is answered "label not
   found" and the model gets one more step.
5. PCC is prepared, not shipped: the provider enum, the engine and Settings leave a slot for
   `apple.privateCloud`, and the engine takes any `LanguageModel`, so adding PCC is: entitlement +
   availability + a picker row + the larger context budget.

## Non-goals

- No PCC request, no entitlement in `RemoteDeck.entitlements` (an unknown managed entitlement breaks
  automatic signing; Vincent applies to Apple first).
- No change to the Claude path's behaviour or wire format (its tests must pass unchanged, apart from
  construction).
- No Apple model for anything other than the Assistant Panel.
- No coordinate clicks, drags, `holdKey` or zoom for Apple.

## Anti-goals (a failure even if it "works")

- A click lands on something the user did not see highlighted before Confirm.
- The app stops launching or building on macOS 15–26 (deployment target stays 15.0).
- Tests or `-LibraryDemo` touch the real model (same rule as "tests never call the API").
- Token counts invented for Apple (it reports none).

## Constraints

- Swift 6 language mode; FoundationModels and its vision API are macOS 26/27 symbols behind
  `#available(macOS 27, *)` (check each symbol's `@available` in the swiftinterface); the framework
  weak-linked (verify `LC_LOAD_WEAK_DYLIB` with `otool -l` after the build; set it in `project.yml`
  if needed). On older systems the Apple row is shown disabled ("requires macOS 27").
- Sandboxed, signed app: the first real check is in the signed Debug app, not a CLI.
- 8,192-token context: the Apple engine builds a **fresh `LanguageModelSession` per step** from the
  instructions, the task, a short summary of the previous steps (last 6, one line each: action,
  label, outcome) and the latest screenshot. No accumulating transcript. `contextSizeExceeded` →
  the existing `cutOff` phase.
- Guardrail violations / refusals → the existing `refused` phase (category nil, explanation from the
  error's description).

## Design

### Seam: `AssistantEngine` (app, `RemoteDeck/Assistant/`)

`AssistantModel` keeps the loop, the transcript, Confirm/Skip/Stop, generation tokens, the pause rule
and the session port. What changes is the request/turn step, extracted behind:

```swift
@MainActor protocol AssistantEngine: AnyObject {
    var provider: AssistantProvider { get }
    var isReady: Bool { get }                       // Claude: key set; Apple: model available
    func begin(prompt: String, screenshot: EncodedImage?)
    func nextTurn() async throws(AssistantEngineError) -> AssistantTurn
    func deliver(_ outcomes: [ActionOutcome])      // results of the turn's actions, sent with the next turn
    func deferOutcomes(_ outcomes: [ActionOutcome])// owed to the next begin/continue (Claude's pendingResults)
    func reset()
}
```

- `AssistantTurn`: `blocks: [TurnBlock]` (`.answer(String)`, `.progress(String)`,
  `.action(id: String, name: String, action: ComputerAction?, parseError: String?, input: JSONValue)`),
  `stop: TurnStop` (`.actions`, `.done`, `.refused(category:explanation:)`, `.cutOff`),
  `usage: TokenUsage?` (nil for Apple).
- `ActionOutcome`: `id`, `text`, `image: EncodedImage?`, `isError`.
- `AssistantEngineError`: `.notReady(AssistantFailure)`, `.cancelled`, `.failed(AssistantFailure)`.
- `AssistantFailure` gains `.appleUnavailable(AppleModelUnavailability)` and
  `.appleGeneration(String)`; `.noAPIKey` stays Claude's. `hasAPIKey` gating in `canAsk`, `retry`,
  `continueAfterPause` becomes `engine.isReady`.
- **`ClaudeEngine`** wraps today's `MessagesClient` + `Conversation` exactly (tool results ↔
  `ContentBlock.toolResult`, `deferResults`, `pendingResults`, toolset-name check, refusal/cut-off
  mapping). Its tool-use ids are Claude's.
- **`AppleEngine`** (`@available(macOS 27, *)`, generic over `some LanguageModel`): one generated
  `AppleStep` per turn → zero or one action block (ids `apple-<n>`), `stop = .actions` for an action,
  `.done` for `answer`/`done`. Before each step after the first it takes a fresh screenshot through a
  closure the model passes (`AssistantModel.screenshot()`, so the mapping stays the model's). Outcomes
  only feed the step summary.

### Label resolution

- `TextLocator` protocol: `func locate(in image: CGImage) async -> [LocatedText]` (string, rect in
  image pixels). `VisionTextLocator` (accurate, languages fr-FR + en-US) in the app; a fake in tests.
- `LabelMatcher` (pure): case- and diacritic-insensitive, trimmed of punctuation; exact match first,
  then a unique "contains" match; several equal candidates → `.ambiguous`; none → `.notFound`. Point =
  the rect's centre, as an image-pixel `ScreenPoint`, then the existing `ScreenMapping` →
  `ActionPlanner` path. The OCR runs off the main actor on the encoded screenshot's pixels (decode the
  PNG/JPEG the model saw, or keep the `CGImage` next to it in `EncodedImage`'s producer).
- `AppleStepMapper` (pure): `AppleStep` + match result → `ComputerAction` (`.click(.left, 1|2, p,
  [])`, `.click(.right…)`, `.type`, `.key` via `KeyChord`, `.scroll`, `.wait`) or a step failure
  text.

### Settings and storage

- `AppSettings.assistantProvider: AssistantProvider` (`claude` default, `appleOnDevice`;
  `applePrivateCloud` declared, hidden), in UserDefaults.
- `AppleModelStatus` (`@MainActor @Observable`, behind a protocol so tests and the demo fake it):
  availability mapped to `AppleModelUnavailability` (`.deviceNotEligible`, `.appleIntelligenceOff`,
  `.modelNotReady`, `.requiresNewerOS`). Under XCTest and `-LibraryDemo` the real
  `SystemLanguageModel` is never touched.
- The panel's token counter shows "On device" instead of tokens for Apple; `SessionRecord`
  tokens are not incremented for Apple.
- Strings: every new key in fr and en (`StringsTests`).

### Wiring

`SessionManager.makeAssistant` builds `AssistantModel(port:engine:)` with the engine for the current
provider (read at Ask time is not needed: a provider change applies to the next new conversation,
`clear()` or a new session). `-LibraryDemo assistant-apple`: the panel on a scripted fake
`AppleEngine` (one label click, one type, one answer), no model.

### Tests

- `AssistantModelTests` run against a `FakeAssistantEngine` for the provider-neutral behaviour; the
  existing Claude-wire tests move to `ClaudeEngine` (fake `HTTPTransport`) and keep their
  assertions on request bodies.
- `LabelMatcherTests`, `AppleStepMapperTests` (pure), `AppleEngineTests` with a fake model behind
  a small protocol (`AppleStepGenerating`) and `FakeTextLocator`: label not found → no action,
  ambiguous → no action, context exceeded → cutOff, refusal → refused, never more than one action
  per turn.
- `StringsTests`, `AppSettingsTests` (provider persisted, default Claude).

## Left to the builder

File split inside `RemoteDeck/Assistant/`, exact `AppleStep` field names and `@Guide` wording,
instructions text, summary format, whether `EncodedImage` carries the `CGImage` or the OCR decodes
the bytes, and the demo script content.

## Follow-ups (TODOS)

- PCC: request the managed entitlement (developer.apple.com/private-cloud-compute), then add the
  entitlement, availability, quota display and the 32k budget.
- Measure label-click accuracy on real remote screens (macOS login window, Linux desktop over VNC)
  and decide whether to keep or narrow the action set.
