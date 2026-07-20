# Gaithano Speak

Local-first, system-wide voice dictation for macOS — a Wispr Flow–style app that
runs entirely on your Mac. Hold a key anywhere, speak, release, and polished text
is typed into whatever app you're in. No subscription.

- **On-device STT** — NVIDIA Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML/ANE).
- **On-device formatting** — Apple Intelligence (Foundation Models) cleans fillers, punctuation, and casing; falls back to deterministic cleanup when unavailable.
- **Talk mode** — hold ⌃⌥ instead of ⌥ and your words go to a model for a quick answer, shown in a panel rather than typed. ⌘C copies it, ⌘↩ inserts it, esc closes.
- **Private by default** — dictation is entirely on-device: audio and text never leave the machine.

### What Talk sends

Talk is the one feature that can leave your Mac, so it's worth being precise:

- **Dictation never leaves the machine.** Nothing below applies unless you hold Control.
- With the default **Vertex AI** provider, a Talk question sends your transcribed
  words, any text you had selected, and the name of the frontmost app to Google.
- **Vision is off by default.** Turning it on additionally uploads a screenshot of
  your focused window with each new question, and needs the Screen Recording
  permission.
- Choosing the **local server** provider (LM Studio / Ollama) keeps Talk on-device
  too. It's also the automatic fallback when Vertex is unconfigured or unreachable.

Vertex uses your existing gcloud credentials (`gcloud auth application-default
login`) — there's no API key to paste and no account with us.

## Requirements
- Apple Silicon Mac, macOS 26+
- Xcode 26 (for the macOS 26 SDK)

## Layout
- `Packages/SpeakCore/` — pure, unit-tested core: the dictation state machine, personal dictionary, deterministic cleanup, prompt builder, settings, and the GRDB persistence layer. **No AppKit/CoreML deps** — runs under `swift test` in ~0.02s.
- `GaithanoSpeak/` — the macOS app: audio capture, the global hotkey (CGEventTap on Option), STT/formatter engines, text insertion, the floating overlay, menu bar, and settings/history/dictionary/onboarding UI.
- `Scripts/build-app.sh` — builds the executable and wraps it into a signed `.app`.
- `Scripts/verify-checklist.md` — the manual test matrix.

## Build & run
```bash
# Fast logic tests (no app build needed):
cd Packages/SpeakCore && swift test

# Build the app bundle:
Scripts/build-app.sh debug
open "build/Gaithano Speak.app"
```
First launch walks you through Microphone + Accessibility grants and the one-time
model download. The app lives in the menu bar (no Dock icon).

## How it works
```
Hold Option ─▶ AVAudioEngine capture ─▶ energy VAD trim
           ─▶ Parakeet transcription ─▶ dictionary pass
           ─▶ Foundation Model cleanup (fallback: deterministic)
           ─▶ paste/keystroke insertion into the focused app ─▶ saved to history
```
A pure `DictationStateMachine` (in `SpeakCore`) drives the whole flow; the
`RecordingCoordinator` executes its effects against the real subsystems. That
split is why the tricky parts — double-tap lock, Option-as-modifier passthrough,
secure-input handling, cancel paths — are exhaustively unit-tested.

## Status
V1 "core loop + polish" milestone. Not yet built: context-aware formatting
(reading the focused field), per-app tone profiles, snippets, command mode, and
cloud STT.

## Licensing note
Parakeet model weights are CC-BY-4.0 (attribution in the About window). FluidAudio
is Apache-2.0.
