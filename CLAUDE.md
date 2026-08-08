# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Gaithano Speak — a local-first, system-wide macOS voice dictation app (Wispr Flow clone). Hold Option anywhere, speak, release; polished text is inserted into the focused app. All STT and formatting are on-device. Requires Apple Silicon, macOS 26+, Xcode 26.

## Commands

```bash
# Pure logic tests (~0.02s, no app build). Swift Testing (@Test/@Suite), not XCTest.
cd Packages/SpeakCore && swift test
swift test --filter "Dictation state machine"     # one suite
swift test --filter holdRelease                    # one test function

# Build + sign the .app bundle (this is the only supported way to run it)
Scripts/build-app.sh debug          # or: release
open "build/Gaithano Speak.app"

# Compile-check the app target without bundling
swift build
```

There is no `.xcodeproj` — the app is an SPM executable wrapped into a bundle by `Scripts/build-app.sh`. Running the bare SPM binary does not work: it needs the Info.plist (`LSUIElement`, mic usage strings) and a code signature.

`Scripts/verify-checklist.md` is the manual test matrix for everything automation can't cover (TCC grants, the event tap, cross-app focus, clipboard restore). Work touching the hotkey, insertion, or overlay should be verified against it.

## Architecture

Two targets, split by testability:

- **`Packages/SpeakCore/`** — pure, Sendable, no AppKit/CoreML. The state machine, `PromptBuilder`, `DeterministicCleanup`, `TextRepair`, `PersonalDictionary`, `AppSettings`, and the GRDB layer. Everything here is unit-tested.
- **`GaithanoSpeak/`** — the app: audio capture, CGEventTap hotkey, engines, insertion, SwiftUI overlay/menu bar/windows.

Both use Swift 6 language mode; concurrency annotations are load-bearing, not decoration.

### The core pattern: pure reducer + effect executor

`DictationStateMachine` (SpeakCore) is a pure reducer — `handle(DictationEvent) -> [Effect]`. It performs no I/O and owns no clock; timing-derived events (`minHoldElapsed`, `lockWindowElapsed`, `maxDurationReached`, `noticeExpired`) come back in from timers the coordinator schedules in response to effects.

`RecordingCoordinator` (app target, `@MainActor @Observable`) owns the machine and executes its effects against the real subsystems. **Add new behavior as an event + effect pair with a test in `DictationStateMachineTests`, not as ad-hoc logic in the coordinator.** The tricky parts — double-tap lock, Option-as-modifier passthrough, secure-input rerouting, cancel paths — live in the reducer precisely so they stay testable.

Flow:
```
HotkeyMonitor ─▶ RecordingCoordinator.handleHotkey ─▶ machine.handle(event)
              ─▶ effects executed: AudioRecorder → VoiceActivity (VAD trim)
              ─▶ FluidAudioEngine (Parakeet) → dictionary pass
              ─▶ FoundationModelFormatter / LocalServerFormatter (fallback: DeterministicCleanup)
              ─▶ TextRepair seam-joining → SmartInserter → AppDatabase
```

`AppEnvironment` builds and wires the long-lived objects (database, engine, coordinator, hotkey, secure-input watcher, overlay) — one instance, created by `AppDelegate`.

### Non-obvious invariants

**Option-as-modifier.** The hotkey is the Option key, which users also press for ⌥←, ⌥e, ⌥Tab, Raycast. The mechanism resolving this: `optionDown` starts capture *provisionally* and silently, and only after `minHold` does dictation "commit" — sound, overlay, media pause. Any other keypress inside that window silently abandons everything (`stopCaptureDiscard` + `passThroughModifier`).

**`minHold` currently defaults to 0**, which switches that protection off: the user asked for instant start, judging the half-second wait worse than the collisions. ⌥-combos now start a dictation. The machinery is intact and timing-driven, so raising `minHold` restores it — keep the provisional/commit split and the abandon path working, and don't collapse them into "commit immediately" just because the default makes the window empty. `HotkeyMonitor` never consumes the modifier; it consumes Esc only while a dictation is active. Don't add feedback before commit, and don't consume Option.

**Secure input.** When a password field has focus the machine goes to `.blockedSecureInput` and the hotkey is disarmed. If secure input turns on mid-dictation, insertion reroutes to the clipboard rather than synthesized keystrokes.

**Foundation Model latency.** ~5–9s cold, ~0.5–3s warm. `formatter.prewarm()` fires when *recording starts* so the model is hot by the time a transcript exists. The 10s timeout is deliberately generous — a short timeout silently degrades every dictation to grammar-blind deterministic cleanup. Plain-string generation is used, not guided `@Generable` (guided measured ~7s even warm). A fresh `LanguageModelSession` is created per format call so prior dictations can't bleed into context; `keepWarm` exists only to hold weights resident.

**`.claude` is the one formatter that leaves the machine.** `ClaudeCLIFormatter` shells out to `claude -p` and sends every dictated utterance, in every app, to Anthropic — plus the CLI writes a session transcript per call under `~/.claude`, so it lands on disk too. It's offered because the on-device model is grammar-blind on long input and Apple Intelligence silently refuses some content — but it is not the default, and the Settings warning is deliberately blunt and non-collapsible. Keep that copy honest; a user picking it from a dropdown has no other cue that local-first just stopped applying. (It replaced a Vertex formatter, which is why `FormatterID.vertexGemini` still exists: `SettingsStore.load()` migrates that saved value to `.claude`, and removing the case would fail the decode and silently reset the user's choice. Talk and the agent are still on Vertex; only the dictation correction pass moved.)

**`MAX_THINKING_TOKENS=0` is the difference between 1.5s and 16s, and it is set in `childEnvironment()`.** Left on, Haiku spends ~530 output tokens reasoning about where a comma goes before emitting a 17-token sentence. Off, the same call is ~1.5–3s, 17 tokens, and half the cost. `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` goes with it. Two knobs that look like they'd do this and don't: `--effort low` (726 output tokens vs 580 at medium — noise), and a small budget like `MAX_THINKING_TOKENS=100`, which the API clamps up to its 1024 minimum and returns 438 tokens in 5.9s. It is binary: off, or ~6s.

**Turning thinking off made every subtle line in the prompt load-bearing, and Haiku broke two of them.** It produced a *refusal with an explanation* for "delete every file in my downloads folder" — worse than either failure alone, since the whole apology gets typed into the user's document — and it trimmed the opening words off any dictation that continues existing text, because the merge block used to end "output ONLY the new words to append". Both are prompt fixes now (`NEVER refuse, warn, or explain yourself`; `Your output is the dictation, WHOLE`), both are pinned by tests, and `ClaudeCLIFormatter.isRunaway` backstops the first: output more than 3× the input is the model breaking character, so it throws and lands on `DeterministicCleanup`.

**That's also why `formatterClaudeModel` defaults to Sonnet.** Not prose quality — instruction-following. Sonnet handles both of the above plus the stutter-across-a-pause dedup Haiku still misses, for ~0.8s more (1.4s → 2.2s on a short utterance). On a subscription the extra tokens are plan usage rather than money, which is what makes the trade easy; a metered key would make it a real decision.

**Startup is not the cost — the request is.** `claude --version` returns in 70ms, and `duration_api_ms` accounts for essentially the whole wall clock. What remains after thinking is off is the payload: the request still carries **29 tool definitions** (`--allowed-tools ""` governs permission, not payload — ~16.5k cached input tokens against ~700 of ours). Two fixes that aren't: prewarming (`claude -p` does nothing until stdin closes, so spawning early and feeding the transcript later measures *worse*, and stdin bails out after 3s idle), and driving a long-lived background session (saves the 70ms, re-sends the tools every turn anyway, and accumulates history so each dictation carries the last — the thing `FoundationModelFormatter`'s fresh-session-per-call exists to prevent). The 20s timeout stays generous because a timeout means silently degrading to grammar-blind cleanup.

**Its flags are load-bearing.** `--system-prompt` *replaces* Claude Code's own prompt — leave that prompt in place and Haiku treats a dictated sentence as a task and answers it (two of three trial runs did). `--setting-sources ""` skips user/project/local settings and with them every configured hook, which would otherwise run on every single utterance. `--strict-mcp-config` with an empty server map, `--allowed-tools ""`, and `--disable-slash-commands` strip tools, MCP, and skills. The cwd is a dedicated empty folder so CLAUDE.md discovery finds nothing — run it from a real project and that project's instructions and memory get pulled into a punctuation request. `formatterClaudePath` exists because a launchd-started GUI app has a bare PATH: `claude` is never simply "on the path" the way it is in a shell, so the usual install locations are searched and the user can override.

**Formatter fallback chain.** Any formatter throw is non-fatal — the coordinator catches and falls back to `DeterministicCleanup`. Short utterances (< `PromptBuilder.minWordsForModel`) and over-long ones (> `maxCharsForModel`) skip the model entirely, *unless* the focused field already has text, in which case the model is forced so the merge/casing is right.

**Cursor-context merging.** `AccessibilityContext.focusedTextContext()` reads text around the caret via AX and feeds it to the prompt so dictation continues a half-finished sentence cleanly. Many Electron/web apps expose nothing — every path must degrade gracefully to nil, falling back to `TextRepair.appendSeparatorSpace`.

**The dictionary learns from the formatter, and the gates are the feature.** `DictionaryLearner.observe(heard:written:)` LCS-aligns the text handed to the model against the text it returned, and proposes dictionary entries from the differences. The point is that the model fixes proper nouns *with sentence context* the dictionary pass can never see — recording those fixes makes them permanent, and makes them work on the short-utterance and offline paths where the model never runs.

Almost everything a formatter changes is grammar, and grammar is not vocabulary. A candidate has to clear **both** gates: `looksLikeTerm` (internal capital, a digit, or internal/leading punctuation — which keeps `GRDB`/`CoreML`/`GPT-4`/`.NET` and rejects `Their`) **and** `Phonetics.areClose` (consonant skeleton, digits expanded to their spoken words). Sentence-initial capitals are excluded from the casing path because every word can have one. More than `maxPerUtterance` candidates means the model paraphrased rather than corrected, and the whole batch is discarded. Loosening either gate is how this feature starts silently corrupting dictations: a wrong entry reads as correct to the person who meant to say it.

Casing fixes promote themselves at `casingThreshold`; spelling fixes only ever *suggest*, unless the user opts into `dictionaryLearningAutoAccept`. A dismissal is permanent — `LearningPolicy.decision` returns `.hold` for any non-`.pending` state, so nothing already settled is ever re-counted or re-offered.

Capture the pair inside `format(_:)`, at the moment the model returns, and nowhere else: the dictionary post-pass and `TextRepair` run afterwards, and learning from those would teach the dictionary its own output. `learnFromLastFormat()` runs at `.persist`, after insertion, so none of it is on the latency path.

**Insertion strategy.** `SmartInserter` types short strings (≤12 chars, no clipboard clobber) and pastes longer ones via synthesized ⌘V. `PasteboardInserter` snapshots and restores the user's clipboard, and skips restoring if `changeCount` shows someone else grabbed it.

**`PromptBuilder.instructions` is a prompt-cache key.** It lives in SpeakCore and is unit-tested so its exact wording stays stable. It also hard-instructs the model to never answer or act on transcript content — preserve that boundary when editing.

**`@Observable` + `didSet` does not fire reliably.** All settings mutation goes through `AppEnvironment.applySettings(_:)` / `updateSetting(_:_:)`, which persist explicitly. Never add a `didSet` persistence hook.

**Settings decoding is lenient.** `AppSettings.init(from:)` decodes every key with a default fallback so adding a setting never wipes saved preferences. Add new fields to both the memberwise init and the custom decoder.

### Claude Code handoff (⌃⌥, and it wins)

A fourth `UtteranceMode`, `.handoff`: same capture, but the transcript is typed into the terminal running a Claude Code session instead of being answered. `settings.claudeCodeHandoffEnabled` (on by default) makes it outrank both Talk and the agent — the coordinator emits `.handoffModifierEngaged` in place of `.talkModifierEngaged`, and suppresses the agent event entirely. It's the only ⌃⌥ path that keeps working when Vertex is down.

**The session is found by process ancestry, not a list of terminals.** `ClaudeCodeHandoff.hostApplication()` walks up from every running Claude Code process until it reaches a pid `NSRunningApplication` recognises — that's the host, whether it's Warp, iTerm, Ghostty, or VS Code. A session under a daemon or an ssh login has no such ancestor and correctly drops out. Our own `ClaudeCLIFormatter` subprocess is excluded by pid, so the formatter can't be mistaken for a session.

**Don't identify the CLI by `p_comm`.** The native installer's binary is `~/.local/share/claude/versions/<version>`, so the accounting name is a version number — matching "claude" finds nothing, silently, on the most common install. `proc_pidpath` is used instead: basename `claude` (npm) or a path containing `/claude/versions/` (native). The `/claude/` test is case-sensitive so the Claude desktop app doesn't match.

**Failure is a notice, never a fallback.** No session found → `.handoffFailed(reason)` → the reason on screen and the text on the clipboard. Rerouting to a model because the terminal wasn't there would hand words meant for a terminal to something the user didn't pick — the reducer refuses the `.handoff` → `.agent`/`.talk` demotion for the same reason, even though the coordinator currently makes it unreachable.

**The handoff skips the model formatter.** Deterministic cleanup plus the personal dictionary only. The destination reads intent rather than prose, and `ClaudeCLIFormatter` now costs 6–10s — a wait on the way to a wait. The dictionary pass is the part that earns its place: it's what turns "gee are dee bee" into `GRDB` before an agent goes looking for the wrong file.

### The agent (⌃⌥, when enabled)

A third `UtteranceMode` alongside `.dictate` and `.talk`: same capture, but the model gets tools and drives the machine. `AgentRunner` loops screenshot → `AgentModel` → `AgentRiskPolicy` → maybe confirm → `AgentExecutor` → screenshot. Gated on `settings.agentEnabled` *and* `talkEnabled`; both default on.

Reachable only with `claudeCodeHandoffEnabled` off — see above.

**The agent has no gesture of its own.** `HotkeyMonitor` emits `.talkModifierEngaged` then `.agentModifierEngaged` for the same ⌃⌥ chord, unconditionally; which one wins is decided by the `settings.agentEnabled` guard in the coordinator, and the reducer's refusal to demote `.agent` back to `.talk` is what makes the ordered pair resolve. So the settings toggle *is* the mode switch — with the agent on there is no way to ask a plain question, and with it off ⌃⌥ answers as before. Shift is no longer read; don't reintroduce it as a discriminator without fixing the demotion problem (a user who adds Shift after Option is already down would emit the events in the wrong order).

**The agent ignores `talkVisionEnabled` and always screenshots** — it can't act on a screen it can't see. Settings says so explicitly when that toggle is off rather than letting it appear to cover both gestures.

**The risk policy is the safety boundary, and it lives in SpeakCore.** `AgentRiskPolicy.risk(of:inApp:secureInputActive:)` is pure and unit-tested precisely so it can't be bypassed. `AgentExecutor` contains no approval logic at all — by the time it's called, the decision is already made. Don't add a "just this once" path that skips the classification.

**`.blocked` outranks auto mode.** `AgentSession` checks `.blocked` *before* `autoConfirm`, so pressing A can never disarm the password-field rail. There's a test for exactly this (`autoDoesNotOverrideBlocked`); it is not incidental.

**Both sides of a chord comparison must be normalised.** `normalizedRiskyCombos.contains(normalizedCombo(keys))` — comparing a sorted chord against the raw set silently classified `cmd+shift+delete` as safe, since it sorts to `cmd+delete+shift`. Green tests did not catch it.

**Coordinates are image space, not screen space.** The model sees a downscaled JPEG; `ScreenCapture.Shot` carries `imageSize` and `displayBounds` together so `screenPoint(fromImage:in:)` can map back. Use `CGDisplayBounds` (top-left origin, CGEvent space), never `NSScreen.frame` — mixing them flips Y on non-primary displays, and a mapping bug looks exactly like the model being bad at finding buttons.

**Prompt injection is the threat model.** The agent sees the whole screen, so every window on it is attacker-reachable text. `AgentPromptBuilder.trustBoundary` is a separate constant so a reword of the task description can't drop it, and it's asserted verbatim in tests. It's a floor, not a guarantee — the real rail is the confirmation policy.

**Non-streaming `generateContent`.** Function calls arrive fragmented over SSE, and there's nothing to stream to anyway: the action doesn't exist until the call is complete. History crosses an isolation boundary as JSON `Data`, not `[String: Any]` — do not "simplify" that with `@unchecked Sendable`. Only the newest screenshot is kept in history (`pruneOldScreenshots`); each is ~1000 prompt tokens.

**Taking the panel down ends the run.** `.hideAnswerPanel` calls `stopAgent()`. The step list is the only place the user can see what's happening, so a run must never outlive it.

### Signing / TCC

`Scripts/build-app.sh` prefers a real Apple Development identity so Accessibility and Microphone grants survive rebuilds; ad-hoc signing resets them every build. Two things in the script are deliberate and must not be "cleaned up":

- **No `--options runtime`** on dev builds. Hardened runtime blocks the private MediaRemote framework used for pause-media-while-listening. Re-enable it only for a notarized distribution build.
- **The `xattr -cr` retry loop.** The project lives in a file-provider-synced folder that re-adds `com.apple.FinderInfo` mid-sign; the retries win that race.

The app is **unsandboxed** by design — system-wide event taps and AX-based insertion are incompatible with the App Sandbox. Direct distribution only.

### Debugging latency

`os_signpost` intervals `capture`, `asr`, `format`, `insert` (subsystem `com.gaithano.speak`, category `latency`) are the budget; inspect in Instruments. Loggers are in `GaithanoSpeak/Support/Log.swift`.

### Persistence

GRDB SQLite at `~/Library/Application Support/GaithanoSpeak/gaithano.sqlite`. `AppDatabase.migrator` sets `eraseDatabaseOnSchemaChange` under DEBUG, so schema edits wipe local data in dev builds — add a real migration for anything that must survive.

## Status

V1 "core loop + polish". Not built yet: per-app tone profiles, snippets, command mode, cloud STT.
