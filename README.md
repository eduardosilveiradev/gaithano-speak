# Gaithano Speak

Local-first, system-wide voice dictation for macOS — a Wispr Flow–style app that
runs entirely on your Mac. Hold Right Control + Right Option anywhere, speak, release, and polished text
is typed into whatever app you're in. No subscription.

- **On-device STT** — NVIDIA Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML/ANE).
- **On-device formatting** — Apple Intelligence (Foundation Models) cleans fillers, punctuation, and casing; falls back to deterministic cleanup when unavailable.
- **Private by default** — audio never leaves the machine, and with the default formatter neither does the text.

### What leaves your Mac

Two things can send your words off the machine, and both are choices you make:

- **Audio never leaves, ever.** Transcription is on-device, full stop.
- **Dictation text stays on-device unless you pick the Claude CLI formatter.**
  Choosing it in Settings → Formatting sends every utterance — in every app — to
  Anthropic to be punctuated, and the CLI keeps a copy of each one on disk under
  `~/.claude`. Expect two to five seconds per dictation, billed against your Claude
  plan's usage. The other three formatters never leave your Mac.
- With the default **Vertex AI** provider, a Talk question sends your transcribed
  words, any text you had selected, and the name of the frontmost app to Google.
- **Vision is off by default.** Turning it on additionally uploads a screenshot of
  your whole screen — every window visible on it, not just the one you're working
  in — with each new question, and needs the Screen Recording permission.
- Choosing the **Claude (claude CLI)** provider sends the same things to Anthropic
  instead, on your Claude plan, and the CLI keeps a copy of each question on disk
  under `~/.claude`. With vision on, the screenshot is written to a scratch folder
  so the CLI can read it, and deleted once the answer arrives.
- Choosing the **local server** provider (LM Studio / Ollama) keeps Talk on-device
  too. It's also the automatic fallback when a cloud provider is unconfigured or
  unreachable — including when the `claude` command can't be found.
- **Reading answers aloud keeps everything local.** Speech is off by default. Turned
  on, it speaks Talk answers only — never your dictation, and
  never anything handed to Claude Code. The Qwen3-TTS engine runs on your machine
  through MLX, and the macOS engine is the system's own voice; neither sends any
  text anywhere.

Vertex uses your existing gcloud credentials (`gcloud auth application-default
login`) — there's no API key to paste and no account with us. The Claude provider
uses whatever the `claude` CLI is already logged in as.

## Requirements
- Apple Silicon Mac, macOS 26+
- Xcode 26 (for the macOS 26 SDK)
- Optional, only for the Qwen3-TTS voice: a Python with `mlx-audio` installed. Point
  Settings → Speech at it, or leave the field blank to have the usual locations
  searched. The macOS voice needs nothing.

## Layout
- `Packages/SpeakCore/` — pure, unit-tested core: the dictation state machine, personal dictionary, deterministic cleanup, prompt builder, settings, and the GRDB persistence layer. **No AppKit/CoreML deps** — runs under `swift test` in ~0.02s.
- `GaithanoSpeak/` — the macOS app: audio capture, the global Right Control + Right Option hotkey, STT/formatter engines, text insertion, the floating overlay, menu bar, and settings/history/dictionary/onboarding UI.
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
