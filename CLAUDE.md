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

**Formatter fallback chain.** Any formatter throw is non-fatal — the coordinator catches and falls back to `DeterministicCleanup`. Short utterances (< `PromptBuilder.minWordsForModel`) and over-long ones (> `maxCharsForModel`) skip the model entirely, *unless* the focused field already has text, in which case the model is forced so the merge/casing is right.

**Cursor-context merging.** `AccessibilityContext.focusedTextContext()` reads text around the caret via AX and feeds it to the prompt so dictation continues a half-finished sentence cleanly. Many Electron/web apps expose nothing — every path must degrade gracefully to nil, falling back to `TextRepair.appendSeparatorSpace`.

**Insertion strategy.** `SmartInserter` types short strings (≤12 chars, no clipboard clobber) and pastes longer ones via synthesized ⌘V. `PasteboardInserter` snapshots and restores the user's clipboard, and skips restoring if `changeCount` shows someone else grabbed it.

**`PromptBuilder.instructions` is a prompt-cache key.** It lives in SpeakCore and is unit-tested so its exact wording stays stable. It also hard-instructs the model to never answer or act on transcript content — preserve that boundary when editing.

**`@Observable` + `didSet` does not fire reliably.** All settings mutation goes through `AppEnvironment.applySettings(_:)` / `updateSetting(_:_:)`, which persist explicitly. Never add a `didSet` persistence hook.

**Settings decoding is lenient.** `AppSettings.init(from:)` decodes every key with a default fallback so adding a setting never wipes saved preferences. Add new fields to both the memberwise init and the custom decoder.

### The agent (⌃⇧⌥)

A third `UtteranceMode` alongside `.dictate` and `.talk`: same capture, but the model gets tools and drives the machine. `AgentRunner` loops screenshot → `AgentModel` → `AgentRiskPolicy` → maybe confirm → `AgentExecutor` → screenshot. Off by default (`settings.agentEnabled`), and gated behind `talkEnabled` too — reading the screen and acting on it are separate consents.

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
