# Gaithano Speak

Local-first, system-wide voice dictation for macOS — a Wispr Flow–style app that
runs entirely on your Mac. Hold a key anywhere, speak, release, and polished text
is typed into whatever app you're in. No cloud, no subscription.

- **On-device STT** — NVIDIA Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML/ANE).
- **On-device formatting** — Apple Intelligence (Foundation Models) cleans fillers, punctuation, and casing; falls back to deterministic cleanup when unavailable.
- **Private by design** — audio and text never leave the machine.

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
