# Integration — capture & preflight

What the `agent/capture` branch adds, and the exact seams the coordinator, the
runtime, and the panel plug into.

## Files added

| File | Target | What it is |
| --- | --- | --- |
| `Packages/SpeakCore/Sources/SpeakCore/Agent/PreflightStatus.swift` | SpeakCore | Pure: `CLIVersion`, `PreflightCheck`, `PreflightFinding`, `PreflightRemedy`, `PreflightStatus`, `AgentCapability`, `AgentAvailability`. |
| `Packages/SpeakCore/Tests/SpeakCoreTests/PreflightTests.swift` | SpeakCore | 16 tests: version ordering, aggregation, remedy totality. |
| `GaithanoSpeak/Agent/ScreenshotService.swift` | app | `AgentCapture`, `ScreenshotFailure`, `ScreenshotService`. |
| `GaithanoSpeak/Agent/AgentScratchStore.swift` | app | The conversation's temp directory: runtime cwd, screenshots, tool log. |
| `GaithanoSpeak/Agent/AgentPreflight.swift` | app | The seven checks. No file outside this table was touched. |

## What the coordinator must call

`AgentScratchStore` is one long-lived actor, built in `AppEnvironment` next to the
database and the coordinator, and shared with `ScreenshotService`.

```swift
let scratch = AgentScratchStore()
let screenshots = ScreenshotService(scratch: scratch)
```

Four lifecycle calls, all `await`:

| When | Call | Why |
| --- | --- | --- |
| App launch, before the first request | `await scratch.purgeStale()` | Spec: a shutdown that couldn't clean up must not leave screenshots behind. |
| Conversation reset | `await scratch.reset()` | Deletes the cwd, every retained screenshot, and the tool log; a fresh conversation id follows. |
| Idle tick | `await scratch.expireIfIdle(conversation)` → `Bool` | Returns `true` when it deleted, so the coordinator tears the Claude Code session down to match. It reads `AgentConversation.idleTimeout`; it does not own a timer. |
| `applicationWillTerminate` | `await scratch.purgeAll()` | Normal termination deletes everything. |

`expireIfIdle` deliberately does not schedule anything. The coordinator already owns
every timer in this app (`minHoldElapsed`, `noticeExpired`); a second clock inside a
storage actor would be a second answer to "is this conversation over".

Screenshot points, per the spec's screenshot policy:

```swift
// request start, after every completed action, and on Claude's on-demand tool
let capture = try await screenshots.capture()
```

`capture()` **throws** rather than returning nil. That is the spec's line at
"if screenshot capture fails, stop computer-use actions that require visual
verification; text-only questions may continue" — the caller can only make that
decision if it is told. There is deliberately no variant that returns a blank or a
cached image. `ScreenshotFailure.remedy` gives the panel a `PreflightRemedy` with the
same wording Settings uses for the same missing grant.

## The runtime seam

Two things cross to the runtime sibling, and they are deliberately different types.

**The cwd.** `try await scratch.runtimeWorkingDirectory()` returns
`<temp>/GaithanoSpeak/agent/<conversation-uuid>/cwd`, created `0700` and empty. Pass
it as `Process.currentDirectoryURL`, same as `ClaudeCLIFormatter.workingDirectory`
does for the formatter, and for the same reason: CLAUDE.md discovery walks up from
the cwd. Agent Mode cannot share `claude-cwd` — the formatter runs concurrently and
this directory is deleted on conversation reset.

**The images.** `AgentCapture` splits them on purpose:

- `capture.mcpImageContent()` → `["type": "image", "mimeType": "image/jpeg", "data": <base64>]`. This is the only thing that goes to Claude.
- `capture.screenshot` is an `AgentScreenshot` (id, `capturedAt`, `url`) and goes into `AgentStep.screenshot` for the panel's thumbnail. **Never into a tool result, a prompt, or an `--add-dir`.**

No value in the file offers both a path and a way to send it, so passing a path to
Claude has to be typed out deliberately. Two independent barriers back that up:
retained screenshots live in `.../<conversation>/shots/`, a *sibling* of `cwd` and
never a child, so a future Claude Code release that adds a file tool the allowlist
hasn't caught up with still finds an empty directory.

Note this diverges from `ClaudeCodeTalkProvider`, which does the opposite — it stages
the screenshot *inside* the cwd and allows `Read`, because the `claude -p` CLI takes
no inline image. **Agent Mode must not copy that.** If the runtime ends up on the same
CLI transport, staging an image for `Read` needs its own temp file written and deleted
per call, outside `shots/`, and `Read` allowed only while it is staged — the runtime's
call, but it must not be solved by pointing the CLI at the retention directory.

**Tool log.** `await scratch.appendToolLog("browser_navigate → https://…")`. It lives
in the conversation directory and dies with it, because the spec puts tool logs under
the same 15-minute retention as screenshots. A GRDB table would outlive the
conversation by default.

**SmartThings binary.** The adapter can reuse
`AgentPreflight.smartThingsExecutable(explicitPath:)` rather than re-deriving the
path; a GUI app's PATH doesn't have it.

## Preflight

```swift
let preflight = AgentPreflight(claudePath: settings.formatterClaudePath,
                               smartThingsPath: settings.agentSmartThingsPath,
                               chromeBridgeConnected: { await runtime.isChromeBridgeConnected() })
let status = await preflight.run()
```

- `status.availability` — `.available` / `.degraded` / `.unavailable`.
- `status.isAvailable(.browser)` / `.smartThings` / `.core` / `.escalation` — the spec's rule that Chrome and SmartThings report separately without disabling desktop control. `core` gates the others: with no microphone there is no request, so "SmartThings is fine" would be true and useless.
- `status.escalationCeiling` — the highest tier a run may climb to. Feed this to the model router; it must not escalate past it.
- `status.remedies` — blocking failures first, each with `problem`, `actionLabel`, and a `PreflightAction` the settings/onboarding UI executes (`openSystemSettings(url)`, `openURL`, `runInTerminal(command)` — show it to copy, never run it — `retryCheck`).
- `status.headline` — one line for a Settings row or the panel.

The gesture is armed only when `status.availability != .unavailable`. A check that
never ran counts as blocking, so a preflight that crashed halfway is not a green
light.

**Nothing in `AgentPreflight` prompts.** Non-prompting TCC variants only, and no CLI
invocation with a side effect. Requesting a grant stays where it already is —
`PermissionsService.promptAccessibility()` / `requestScreenRecording()` — driven by a
button the user pressed. Do not wire the preflight to a launch-time refresh that also
requests; macOS shows the Screen Recording prompt once per app, and spending it on a
background poll means the user never sees it when it would have helped.

## AppSettings keys needed

Neither exists yet; `AppSettings.swift` is a sibling's file, so these are requests.
Both need adding to the memberwise init **and** the custom decoder — decoding is
lenient by design so a new key never wipes saved preferences.

| Key | Type | Default | Why |
| --- | --- | --- | --- |
| `agentSmartThingsPath` | `String` | `""` | Override for the `smartthings` binary. Same reason `formatterClaudePath` exists: launchd hands a GUI app a bare PATH. Blank means search the usual install locations. |
| `agentPreflightLastStatus` | *not requested* | — | Explicitly **not** wanted. Caching availability across launches would let a revoked grant read as granted; the pass is ~100ms and should run on demand. |

`formatterClaudePath` is reused as-is for locating `claude` — the preflight calls
`ClaudeCLIFormatter.resolveExecutable(explicitPath:)`, so a user who has already
pointed the formatter at their CLI does not have to do it twice.

## Info.plist and entitlements

**Nothing new is required.** Both usage strings the capture path needs are already
there:

- `NSMicrophoneUsageDescription` — present, dictation already uses it.
- Screen Recording has no usage-string key; macOS 26 gates it purely on the TCC grant, which Talk's vision path already exercises.

The app is unsandboxed by design and stays that way — ScreenCaptureKit against the
whole display, an AX-driven MCP, and spawning CLIs are all incompatible with the App
Sandbox. Two things in `Scripts/build-app.sh` matter to this branch and must not be
"cleaned up": the real Apple Development identity (ad-hoc signing resets the Screen
Recording and Accessibility grants on every build, which would make the preflight
report a fresh failure after each rebuild), and the absence of `--options runtime`.

## Assumptions made about siblings

1. **`AgentTypes.swift` is frozen.** `AgentScreenshot(id:capturedAt:url:)` is used exactly as written; `AgentConversation.idleTimeout` is the single source for the 15-minute window.
2. **The runtime owns the Chrome bridge.** `chromeBridgeConnected` is a closure because only the process holding the MCP connection knows whether the extension is attached. Anything this branch could measure locally — a listening port, a directory in a Chrome profile — reports "connected" for a bridge that has been down since the last Chrome restart. Unwired, it defaults to `false`, so the honest "not connected" with a remedy is what shows.
3. **The coordinator owns the clock.** `expireIfIdle` is called; it does not schedule.
4. **The panel renders `PreflightRemedy`,** and `PreflightAction.runInTerminal` is displayed for the user to copy, never executed. `smartthings devices` opens a browser login — the spec says reauthentication is a setup action in the app, not something a check or Claude sets off.
5. **Model availability is not probed.** The only entitlement fact readable for free is the CLI version, and the spec ties Fable 5.1 to it. Enumerating plan access would mean one real request per tier every time Settings opens. The runtime is expected to report a model that refuses mid-run, per "if a model is unavailable, report it; do not silently substitute."

## Deliberate divergences from the Talk vision path

`ScreenshotService` calls `ScreenCapture.capture()` rather than growing a second copy
of the ScreenCaptureKit code. The requirements match: whole active display, our own
application excluded via `SCContentFilter`, one downscale to 1536px at quality 0.7.
Three differences are handled in `ScreenshotService`, not by editing `ScreenCapture.swift`:

- **Failure is loud.** Talk folds everything into `nil` so a missing grant quietly degrades an answer to text-only. `ScreenshotService` checks `CGPreflightScreenCaptureAccess()` first so a denied grant is distinguishable from a capture that failed for another reason — the remedies are completely different — and throws the rest.
- **A copy is retained** in `shots/` for the panel's thumbnail. Talk's image is used once and dropped.
- **Its own signpost interval,** `agentScreenshot`. `capture` already means *audio* capture in the dictation latency budget.

One live limitation inherited from `ScreenCapture`: `config.showsCursor = false`. For a
vision question that is right; for computer-use verification the pointer's position is
sometimes the evidence ("did the drag land?"). Changing it means a parameter on
`ScreenCapture.capture()`, which is another branch's file. Flagged, not fixed.

## Single display

Built for the active display only — the one under the pointer, matching the rule the
overlay uses to pick a screen. The spec lists "whether *entire active display* should
expand to every connected display" as still open. If it expands:

- `ScreenCapture.capture()` returns one `Shot`; it would need to return an array, or `ScreenshotService` would iterate `SCShareableContent.displays` itself, which is the point where sharing `ScreenCapture` stops paying and this branch grows its own capture loop.
- `AgentCapture` becomes one-per-display and `AgentStep.screenshot` is a single value, so either the panel shows the active display's capture and the rest are attachment-only, or `AgentTypes.swift` changes — and it is frozen.
- `ScreenshotService.screenPoint(fromImage:in:)` already carries `displayBounds` per capture, so click mapping survives unchanged as long as each image keeps travelling with the bounds it came from. This is the part that would break silently: one merged image spanning two displays with a single `displayBounds` puts every click on the wrong monitor, and it looks exactly like the model being bad at finding buttons.
- Cost is linear in prompt tokens. Two 1536px displays roughly double the image payload on *every* post-action verification, not just the first.

Recommended if it does expand: capture each display separately, send the active one
first, and let Claude ask for the others through the on-demand screenshot tool with a
display argument.
