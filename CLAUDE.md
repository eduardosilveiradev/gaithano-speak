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

**Talk can run on the same CLI, and shares that hardening rather than copying it.** `ClaudeCodeTalkProvider` (`TalkProviderID.claudeCode`) is the third answer provider alongside Vertex and the local server, and it calls `ClaudeCLIFormatter.resolveExecutable/childEnvironment/workingDirectory` — so `MAX_THINKING_TOKENS=0`, the PATH repair, and the empty cwd hold there too, in one place. Two things differ. It **streams**: `--output-format stream-json --include-partial-messages --verbose`, parsed by `StreamChunkParser.claudeCodeDelta`, which takes `text_delta` only — `input_json_delta` (the Read being assembled) and the whole-message `assistant` line would otherwise put the scratchpad in the panel, or double the answer. And it **sees by reading a file**: the CLI takes no inline image, so a screenshot goes into the scratch folder that is already its cwd — which is why `--add-dir` isn't needed, and why `Read` is the only tool allowed and only while an image is staged. That costs a round trip (~2.5s text-only vs ~7s with vision, measured on Sonnet), and the alternative was a provider that silently ignores the vision toggle. Failures map to fallback-worthy `TalkError`s on purpose: a missing CLI or a spent plan limit falls through to the local server with a notice, the same as an unreachable Vertex. `talkClaudeModel` is separate from `formatterClaudeModel` — the formatter sits on the latency path of every dictation, an answer is read rather than typed.

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

### Speech (reading answers aloud)

Off by default, and only ever applied to **answers** — Talk replies and agent summaries. Dictation is never spoken: reading a user's own words back while they're being typed into a document is noise, and that path is the one where latency is the product. The Claude Code handoff isn't spoken either (there's no answer, just a prompt about to run), and neither is anything `ClaudeCLIFormatter` produces non-interactively — nothing on those paths calls `speakAnswer`, and the `speechEnabled` gate means that even if something did, it stays silent unless the user asked for it. The default is off because this app gets used in meetings and next to sleeping people.

**Qwen3-TTS has to be a resident process, and that dictates the whole design.** Measured here: ~13s to import mlx-audio and load `Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16`, then roughly 1× realtime generation (4.4s of audio in 4.5s). Spawning per utterance would put a 13s floor under every spoken answer — longer than the model call that produced it. So `qwen_tts_server.py` stays alive and `prewarmSpeech()` fires at *recording start*, the same bargain `formatter.prewarm()` makes. It warms on every recording, not just Talk ones, because the mode isn't known until the modifier is read and by then the user is mid-sentence.

**stdout is not the sidecar's protocol channel.** mlx-audio prints straight to it — "Initialized encoder codebooks", the tokenizer path, tqdm bars — and the first load would corrupt any handshake sharing it. So fd 1 is duplicated to a private fd *before any import*, and the real stdout is pointed at stderr; replies go to the duplicate and every library that thinks it's printing to stdout lands in the app log. The sibling `explainer-studio/pipeline/tts_qwen.py` dodges the same hazard by writing results to a file, which is the batch-script answer to it.

`SpeechText.spoken(from:limit:)` is pure and tested: answers are written to be *seen*, and a fenced code block read aloud is thirty seconds of narrated shell command. Fences go first and whole (including an unterminated one, which is what a cut-off stream leaves), then headings, bullets, tables, link URLs, and emphasis markers — keeping the words, dropping the glyphs. An answer that was entirely code returns nil rather than a stray bracket. The length clamp cuts at a sentence boundary so a clipped answer ends like an answer.

The Python interpreter is found, not assumed: `SpeechConfig.candidateInterpreters` looks in the usual places and each candidate must actually `import mlx_audio` before it's accepted — a Python that merely exists is the common case and the useless one. An explicit `speechPythonPath` skips the search and is honoured even if the import fails, so a misconfigured venv shows up as a real error instead of silently falling through to another Python. The sidecar is shut down when the engine changes or speech is switched off; 4 GB is not something to hold for a disabled feature. `SystemSpeechOutput` (AVSpeechSynthesizer) is the zero-setup alternative and needs none of this.

`qwen_tts_server.py` is copied into the bundle by `build-app.sh` — the app target is an SPM executable wrapped by that script, so `Bundle.module` doesn't exist and `Bundle.main` is whatever the script assembles. There is deliberately no fallback to a path inside the source tree: it would work on one machine and hide a broken build everywhere else.

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
