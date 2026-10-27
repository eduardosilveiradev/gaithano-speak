#!/usr/bin/env python
"""
Resident Qwen3-TTS sidecar for Gaithano Speak.

Reads one JSON job per line on stdin, writes one JSON reply per line on a private
copy of stdout, and keeps the model in memory between them.

## Why a server and not a script

Measured on this machine: importing mlx-audio and loading
Qwen3-TTS-12Hz-1.7B-CustomVoice takes ~13s, after which generation runs at about
1x realtime (a 4.4s answer takes 4.5s to synthesise). Spawning a process per
utterance would therefore put a 13s floor under every spoken answer — longer than
the answer itself, and longer than the model call that produced it.

So the process outlives the utterance. This is the same bargain
`FoundationModelFormatter.prewarm()` already makes on the dictation path: hold the
weights resident and pay the load once, at a moment nobody is waiting.

## stdout is not the protocol channel

mlx-audio prints straight to stdout — "Initialized encoder codebooks", the
speech-tokenizer path, tqdm bars — and none of it is ours. Any handshake sharing
that channel gets corrupted by the first load.

So fd 1 is duplicated to a private fd before anything is imported, and the real
stdout is then pointed at stderr. Replies go to the duplicate; every library that
thinks it is printing to stdout lands harmlessly in the app's log instead. This is
the same hazard the sibling `tts_qwen.py` sidesteps by writing results to a file,
solved in the way a long-lived process needs.
"""
import json
import os
import sys

# Do this FIRST, before any import that might print.
_PROTOCOL_FD = os.dup(1)
os.dup2(2, 1)
sys.stdout = sys.stderr

import warnings

warnings.filterwarnings("ignore")


def reply(payload):
    """Write one JSON object to the private channel and flush it."""
    os.write(_PROTOCOL_FD, (json.dumps(payload) + "\n").encode("utf-8"))


def log(message):
    print(f"qwen-tts: {message}", file=sys.stderr, flush=True)


# Lowercase, and matched exactly — anything else fails deep inside generation
# rather than at the call. Kept in step with `SpeechVoice` on the Swift side.
SPEAKERS = {
    "serena", "vivian", "uncle_fu", "ryan", "aiden",
    "ono_anna", "sohee", "eric", "dylan",
}

CUSTOM_VOICE = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
SAMPLE_RATE = 24000


def main():
    try:
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model
    except Exception as exc:  # noqa: BLE001 - the app needs the reason, not a trace
        reply({"ok": False, "fatal": True,
               "error": f"missing Python dependency: {exc}"})
        return 1

    try:
        log(f"loading {CUSTOM_VOICE}")
        model = load_model(CUSTOM_VOICE)
    except Exception as exc:  # noqa: BLE001
        reply({"ok": False, "fatal": True, "error": f"could not load the model: {exc}"})
        return 1

    log("ready")
    reply({"ok": True, "ready": True})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            job = json.loads(line)
        except json.JSONDecodeError as exc:
            reply({"ok": False, "error": f"bad job: {exc}"})
            continue

        if job.get("command") == "quit":
            log("shutting down")
            return 0

        text = (job.get("text") or "").strip()
        out = job.get("out")
        voice = (job.get("voice") or "ryan").strip().lower()
        if not text or not out:
            reply({"ok": False, "error": "job needs both 'text' and 'out'"})
            continue
        if voice not in SPEAKERS:
            reply({"ok": False, "error": f"unknown voice '{voice}'"})
            continue

        try:
            result = list(model.generate_custom_voice(
                text=text, speaker=voice, language=job.get("language", "English")))[0]
            audio = np.array(result.audio)
            rate = getattr(result, "sample_rate", SAMPLE_RATE)
            sf.write(out, audio, rate)
            reply({"ok": True, "out": out, "seconds": len(audio) / rate})
        except Exception as exc:  # noqa: BLE001
            # One bad utterance must not take the server down: the model is still
            # loaded and the next answer should still be speakable.
            log(f"generation failed: {exc}")
            reply({"ok": False, "error": str(exc)})

    return 0


if __name__ == "__main__":
    sys.exit(main())
