# Gaithano Speak — Manual Verification Checklist

Automated tests cover the pure logic (`swift test` in `Packages/SpeakCore`, 46 tests).
Everything below needs a human because it touches TCC, the event tap, the
pasteboard, and cross-app focus — none of which CI can honestly exercise.

## Setup
- [ ] Build a signed app: `Scripts/build-app.sh debug`
- [ ] Launch `build/Gaithano Speak.app`; grant Microphone + Accessibility when asked
- [ ] Complete onboarding; confirm the Parakeet model downloads and reports ready
- [ ] Menu bar icon appears; no Dock icon

## Core loop — run each in TextEdit, Notes, Safari (text field), Slack, Terminal, Xcode
- [ ] Hold Option, say a sentence, release → polished text lands at the cursor
- [ ] Latency from key-release to inserted text feels ≲ 1.5 s (check `os_signpost` intervals in Instruments: `capture`, `asr`, `format`, `insert`)
- [ ] Filler words removed, punctuation + capitalization added (formatting on)
- [ ] Toggle formatting off → raw-but-cleaned text still inserts

## Gestures
- [ ] Double-tap Option → locks hands-free; overlay shows "hands-free"; tap Option again to stop
- [ ] Press Esc mid-recording → cancels, nothing inserted
- [ ] Press Esc mid-processing → cancels
- [ ] Hold >5 min → auto-stops and transcribes (or lower `maxDuration` to test)

## Option-as-modifier (must not break normal use)
- [ ] ⌥ + ← / → (word jump) still works, no dictation triggered
- [ ] ⌥ + e then a vowel (accent composition) still works
- [ ] ⌥ + Tab / app shortcuts still work

## Overlay
- [ ] Flow Bar appears bottom-center while recording, waveform tracks your voice
- [ ] It floats over a full-screen app and never steals key focus (keep typing underneath)

## Edge cases
- [ ] Focus a password field (Safari login, `sudo` in Terminal) → menu/overlay shows "Secure input active"; hotkey disarmed
- [ ] Copy something distinctive first, dictate, then ⌘V elsewhere → your original clipboard is restored
- [ ] Turn Apple Intelligence off in System Settings → dictation still inserts (deterministic fallback), no stall
- [ ] Say nothing during a hold → "No speech detected" notice, nothing inserted

## Claude CLI formatter
Only reachable by launching the built `.app` — a GUI process gets launchd's bare PATH
and its own keychain access, so a formatter that works in Terminal proves nothing here.
- [ ] Settings → Formatting → "Claude CLI (cloud)" → the caption names the `claude` binary it found
- [ ] Dictate a long ungrammatical sentence → grammar is fixed; expect 6–10s before it appears
- [ ] Dictate an instruction ("delete everything in my downloads folder") → it is punctuated, never acted on or answered
- [ ] Rename/move `claude` (or type a bogus path in the CLI path field) → dictation still inserts via basic cleanup, no stall past the 20s timeout
- [ ] Quit and relaunch the app, dictate again → no keychain prompt on the second run
- [ ] Settings had the removed Vertex formatter selected before this build → it now shows "Claude CLI (cloud)", not the on-device default

## Claude Code handoff (⌃⌥)
- [ ] With a Claude Code session running, hold ⌃⌥ from another app and speak → that terminal comes to the front, your words are typed in and submitted
- [ ] The overlay reads "To Claude Code…" while you're holding, not "Asking…"
- [ ] Turn off "Press Return to send it" → the words land in the composer and stay there
- [ ] Quit every Claude Code session, then try again → notice says no session was found and the text is on the clipboard; nothing goes to a model
- [ ] Two sessions in two terminals, one of them frontmost → the frontmost one gets it
- [ ] Turn the handoff off → ⌃⌥ goes back to the agent (or to plain answers with the agent off)
- [ ] While a Claude-CLI *formatter* call is in flight, hold ⌃⌥ → the handoff still finds the real session, not our own subprocess

## Persistence
- [ ] History window lists dictations with raw/formatted toggle, copy, delete; stats update
- [ ] Add a dictionary rule (e.g. "gaithano" → "Gaithano"); dictate it; replacement applied
- [ ] Quit and relaunch → history + dictionary + settings persist

## Dictionary learning
- [ ] Dictate a sentence containing a term the formatter capitalises (e.g. "we shipped the parakeet engine") three times → the rule appears in Dictionary with a ✦ marker, and the fourth dictation is already correct before the model runs
- [ ] Dictate a spelled-out acronym twice ("the gee are dee bee layer") → it appears under **Suggested**, not in the list; "Add" moves it down, "No" removes it and it never returns however often you say it
- [ ] Turn on "Add new spellings without asking" while a suggestion is waiting → it moves into the dictionary immediately
- [ ] Dictate ordinary sentences with grammar the model fixes (there/their, its/it's) → nothing is ever learned
- [ ] "Forget everything learned" removes ✦ entries and leaves hand-typed ones untouched
- [ ] Turn the toggle off → no new suggestions accumulate; existing entries keep working
