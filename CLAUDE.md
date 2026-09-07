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

**Two chords, and the side of the keyboard is the mode.** Right Control+Option dictates; left Control+Option runs the agent. Nothing else arms either one — no third key, no modifier arriving mid-utterance, so a user never has to watch the overlay to know where their words are going.

**`.maskControl` and `.maskAlternate` cannot tell the sides apart, and that is the entire distinction.** Both are set by either side. `HotkeyMonitor` reads the device-dependent flag bits instead (`NX_DEVICELCTLKEYMASK` 0x1, `NX_DEVICERCTLKEYMASK` 0x2000, `NX_DEVICELALTKEYMASK` 0x20, `NX_DEVICERALTKEYMASK` 0x40, from `IOKit/hidsystem/IOLLEvent.h`) — the only place side survives in a `CGEvent`. State is recomputed in full on every `flagsChanged` rather than tracked as per-key transitions, so a missed event heals on the next one instead of leaving a chord stuck down. An earlier version read `.maskAlternate` for the right Option and got the wrong answer whenever the left one was also held.

`ChordResolver` (SpeakCore, pure, tested) matches on *superset*, so a stray Shift joining a held chord doesn't end it, and lets the already-active chord win when all four keys are down — releasing a key must never change where an utterance already being spoken goes.

**Option-as-modifier.** A chord starts capture *provisionally* and silently; only after `minHold` does it "commit" — sound, overlay, media pause. Any other keypress inside that window silently abandons everything (`stopCaptureDiscard` + `passThroughModifier`).

**`minHold` currently defaults to 0**, which switches that protection off: the user asked for instant start, judging the half-second wait worse than the collisions. ⌃⌥-combos now start a dictation, and on the left side they start an *agent run* — a wider blast radius than a stray dictation, though VAD and `UtteranceGate` still bail out when nobody spoke. The machinery is intact and timing-driven, so raising `minHold` restores it — keep the provisional/commit split and the abandon path working, and don't collapse them into "commit immediately" just because the default makes the window empty. `HotkeyMonitor` never consumes a modifier; it consumes Esc while a dictation is active or an approval is pending, and bare `Y`/`N`/`A` only while an approval is pending.

**Secure input.** When a password field has focus the machine goes to `.blockedSecureInput` and the hotkey is disarmed. If secure input turns on mid-dictation, insertion reroutes to the clipboard rather than synthesized keystrokes.

**Foundation Model latency.** ~5–9s cold, ~0.5–3s warm. `formatter.prewarm()` fires when *recording starts* so the model is hot by the time a transcript exists. The 10s timeout is deliberately generous — a short timeout silently degrades every dictation to grammar-blind deterministic cleanup. Plain-string generation is used, not guided `@Generable` (guided measured ~7s even warm). A fresh `LanguageModelSession` is created per format call so prior dictations can't bleed into context; `keepWarm` exists only to hold weights resident.

**`.claude` is the one formatter that leaves the machine.** `ClaudeCLIFormatter` shells out to `claude -p` and sends every dictated utterance, in every app, to Anthropic — plus the CLI writes a session transcript per call under `~/.claude`, so it lands on disk too. It's offered because the on-device model is grammar-blind on long input and Apple Intelligence silently refuses some content — but it is not the default, and the Settings warning is deliberately blunt and non-collapsible. Keep that copy honest; a user picking it from a dropdown has no other cue that local-first just stopped applying. (It replaced a Vertex formatter, which is why `FormatterID.vertexGemini` still exists: `SettingsStore.load()` migrates that saved value to `.claude`, and removing the case would fail the decode and silently reset the user's choice. Talk still offers Vertex; the agent moved to Claude Code entirely.)

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

### Claude Code handoff (no gesture at present)

A fourth `UtteranceMode`, `.handoff`: same capture, but the transcript is typed into the terminal running a Claude Code session instead of being answered.

**Talk and the handoff currently have no key.** Moving dictation to right ⌃⌥ and the agent to left ⌃⌥ used up the gesture both of them shared. Their reducer paths, providers, and tests are all intact and still exercised — `.talkModifierEngaged` and `.handoffModifierEngaged` are simply never emitted. Deciding what gesture they get back (or whether the agent subsumes Talk) is open work; don't delete the paths on the assumption they're dead code.

**The session is found by process ancestry, not a list of terminals.** `ClaudeCodeHandoff.hostApplication()` walks up from every running Claude Code process until it reaches a pid `NSRunningApplication` recognises — that's the host, whether it's Warp, iTerm, Ghostty, or VS Code. A session under a daemon or an ssh login has no such ancestor and correctly drops out. Our own `ClaudeCLIFormatter` subprocess is excluded by pid, so the formatter can't be mistaken for a session.

**Don't identify the CLI by `p_comm`.** The native installer's binary is `~/.local/share/claude/versions/<version>`, so the accounting name is a version number — matching "claude" finds nothing, silently, on the most common install. `proc_pidpath` is used instead: basename `claude` (npm) or a path containing `/claude/versions/` (native). The `/claude/` test is case-sensitive so the Claude desktop app doesn't match.

**Failure is a notice, never a fallback.** No session found → `.handoffFailed(reason)` → the reason on screen and the text on the clipboard. Rerouting to a model because the terminal wasn't there would hand words meant for a terminal to something the user didn't pick — the reducer refuses the `.handoff` → `.agent`/`.talk` demotion for the same reason, even though the coordinator currently makes it unreachable.

**The handoff skips the model formatter.** Deterministic cleanup plus the personal dictionary only. The destination reads intent rather than prose, and `ClaudeCLIFormatter` now costs 6–10s — a wait on the way to a wait. The dictionary pass is the part that earns its place: it's what turns "gee are dee bee" into `GRDB` before an agent goes looking for the wrong file.

### Agent Mode (left ⌃⌥)

`AGENT_MODE_SPEC.md` is the product spec; this is what the code guarantees. A fifth `UtteranceMode`, `.agent`: transcribe, then hand the task to an embedded Claude Code session that reasons and acts through bounded MCP tools while a panel narrates it.

**One frozen vocabulary, one direction.** `SpeakCore/Agent/AgentTypes.swift` is the contract four separate halves speak — the runtime, the approval proxy, the panel, the screenshot service. The runtime emits `AgentEvent`, `AgentTranscript.apply(_:)` folds them, the panel renders the transcript. Nothing renders an event directly, so there is exactly one definition of what the user is looking at. Three invariants live in that reducer and are pinned by tests rather than left to callers: escalation only ever climbs, "allow all" is cleared by *every* way a run can end, and a step that was running when the run died becomes `.interrupted` rather than `.failed` because its outcome is genuinely unknown.

**The approval boundary is a proxy, not a prompt.** `MCPApprovalProxy` is the only MCP server Claude Code can see; it forwards to the real ones. `tools/list` is filtered on the way out and `tools/call` again on the way in, so a model that guesses a tool name it was never shown is still refused. `AgentApprovalGate.decide` *suspends the tool call* — the downstream server has not been sent anything yet, which is what makes "deny" mean the action never happened rather than that it was undone. There is deliberately no timeout: a prompt that expires into a default answer is a prompt that eventually answers itself.

**The allowlist is positive; the denylist is only belt-and-braces.** A denylist cannot know about a tool Claude Code adds next month. `AgentToolAllowlist` admits only names shaped `mcp__<known server>__<tool>` that are explicitly listed, and a forbidden-fragment check (`eval`, `run_code`, `applescript`, `shell`, …) runs *after* set membership so it survives a future edit that adds one to a server's set. `ActionRiskPolicy.classify` re-checks the allowlist before judging anything and returns `.unknown` — which means ask — for everything it does not positively recognise.

**SmartThings is judged by capability, never by label**, and that is deliberately the opposite of how a click is judged. A click has no authoritative field, so scanning its text can only ever *add* a confirmation; here there is one, and reading the label would let a name *remove* one. "Front Door Light" with `switch` stays automatic; `lock` on a device the user named "Lamp" is still `.security`. `run_scene` is `.unknown` because a scene is a stored list of commands the app cannot see, and one of them may be a lock.

**`@main` is on `GaithanoSpeakMain`, not `GaithanoSpeakApp`.** Claude Code spawns its stdio MCP servers itself, so whatever `--mcp-config` names has to be an executable — but the gate needs the *running* app. The executable is this same binary in relay mode, copying stdin to a Unix socket and back, and `MCPApprovalProxy.runRelayIfRequested()` must run before AppKit does anything. Remove that call and Claude Code spawns a second copy of the GUI app instead of a server; Agent Mode then has no tools at all, silently.

**Every agent ending is bridged back into the dictation reducer.** The reducer parks in `.processing(.answering)` when `.runAgent` is emitted and has no other way out. `.responseFinished` → `.answerReady`, `.failed` → `.answerFailed`, `.cancelled` → `.escPressed`. Miss one and the dictation hotkey stays dead for the rest of the session, with no error.

**`hotkeyMonitor.setApprovalPending` is derived from the transcript**, never set wherever a prompt is raised. It is the entire licence to consume three bare letters system-wide; left true after a run dies under a pending approval, the user loses `Y`, `N` and `A` in every text field on the machine.

**`AgentScratchStore` and `ClaudeAgentRuntime` own separate temp roots, and must keep doing so.** They used to share one. The store's `purgeStale()` deletes every entry in its root that isn't its own live conversation — correct on its own terms, and it described the runtime's working directory exactly, so `AppEnvironment` wiped the agent's cwd at launch and every run died in `Process.run()` reporting `The file "<uuid>" doesn't exist`. Two owners of one directory, each purging correctly. The runtime also recreates its cwd immediately before launch, because the failure names a UUID and nothing else, and no user could connect that to a conversation.

**Esc consumption spans any live transcript, not just an active run.** The agent panel stays up after a failure to show what went wrong, and `showsAnswerPanel` is false in agent mode — so keying it off `phase.isActive` left the monitor seeing neither an active run nor a panel, and the one key the panel tells the user to press did nothing. It is handed back in `endAgentConversation`, which is the only place the panel goes away.

**Escalation is a tool call on our own server, checked on server *and* tool name** (`mcp__control__escalate_model`), so an MCP package the user installs later cannot ship its own `escalate_model` and pick the model. Pattern-matching prose was the cheap alternative and is wrong twice: models say "this is hard" while handling things fine, and a model that genuinely needs help has no reliable way to say so. Claude Code cannot switch model mid-turn, so escalation is: let the turn end, then `--resume <session> --model <higher>` with a continuation prompt. `.escalated` fires when the *tool call* is seen, so the panel is honest about intent, not about which process is alive. With no session id the request **fails** rather than restarting fresh — a context-free retry is how a message gets sent twice.

**Screenshots reach Claude as MCP image content and never as a path.** `AgentCapture` splits the JPEG data from the panel's thumbnail reference so no single value offers both a file path and a way to send it. The Talk provider's stage-a-file-and-allow-`Read` trick is exactly what must not happen here. `capture()` throws rather than returning nil, because the spec's "stop computer-use actions that require visual verification" is a decision only the caller can make and only if it is told.

**Two of the three servers are ours, bundled in `Resources/MCPServers/`, and that was not the plan.** The allowlist was drafted against `mcp-macos-cua`, which names two of the sixteen macOS tools it listed; `smartthings-mcp` does not exist on npm at all. The macOS mismatch is the instructive one, because nothing about it fails: the proxy filters tools it doesn't recognise, filtering *is* the design, and a server whose every tool is unknown is indistinguishable from one behaving correctly. The only symptom is an assistant that quietly cannot act. `BundledServerToolsTests` now pins the servers and the allowlist to each other so that drift fails in a second instead of during a run.

**No shell, and no model-supplied value interpolated into an AppleScript.** Both rules are structural, and both come from reading the alternative: `mcp-macos-cua`'s `type_text` built a shell command by interpolating the model's own text between single quotes, escaping `\` and `"` but not `'` — a shell, reached through the tool most likely to carry text read off a web page. So every call here is `execFile` with an argument array, and every AppleScript is a fixed literal with `on run argv` whose values arrive as arguments. A window title containing `" of window 1` is a title. The only things built into script text are roles and modifier keywords, which are AppleScript *syntax*, and each is checked against a fixed map that fails closed. `set_brightness` and `media_control` were dropped rather than faked: neither is reachable from a subprocess without private frameworks, and listing a tool whose only outcome is a failed call is a promise the boundary can't keep.

**SmartThings takes fields, never a command string.** `send_device_command` receives capability, command and arguments separately and *the adapter* composes the `capability:command(args)` string the CLI wants. That is what keeps the CLI unaddressable — there is no route to `smartthings apps:delete` — and it is also what makes the gate work: `ActionRiskPolicy` classifies by capability, and it can only do that because the capability arrives as its own field. A single opaque string would have to be parsed by the gate, and a gate that parses is a gate that spacing can fool.

**Two spec requirements do not hold as written.** Model availability per plan is not checkable without one real request per tier, so an unavailable Opus surfaces as a mid-run failure rather than at preflight. "Chrome extension connected" is not observable from this app at all — the extension talks to the MCP server, not to us — so it is injected, defaulting to false. Both are honest gaps, not oversights.

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

V1 "core loop + polish", plus Agent Mode with its servers in place but still never run end to end.

The macOS and SmartThings servers ship in the bundle and answer `tools/list` correctly. Chrome runs on demand through `npx @playwright/mcp`. What is not done is the setup none of that can do for the user: Chrome needs the Playwright MCP extension, SmartThings needs `smartthings login`, and the desktop tools need Automation permission, which macOS only offers at the first real Apple Event. Until those three, a left ⌃⌥ press starts fewer servers than it looks like it should — and preflight reports which, rather than failing at the first tool call.

Nothing has been verified against a live Claude Code session, and `Scripts/verify-checklist.md` has no Agent Mode entries yet.

Open: a gesture for Talk and the Claude Code handoff; an `agentModelCeiling` for plans without Opus; multi-display capture; whether `.security` should be exempt from "allow all for this run", which today it is not.

Not built: per-app tone profiles, snippets, command mode, cloud STT.
