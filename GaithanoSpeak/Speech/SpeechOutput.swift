import Foundation
import AVFoundation
import SpeakCore

/// Reads answers out loud.
///
/// Only *answers* — Talk replies. Dictation is never spoken: the
/// user's own words being read back while they are being typed into a document is noise
/// with no purpose, and the dictation path is latency-critical in a way this is not.
///
/// Two implementations, picked by `SpeechEngineID`. The system one is always available
/// and starts instantly; the Qwen one sounds enormously better and needs a resident
/// Python process holding four gigabytes of weights. That tradeoff is the user's to
/// make, which is why it is a setting and not a decision baked in here.
@MainActor
protocol SpeechOutput: AnyObject {
    /// Speak, interrupting anything already in progress. Returns as soon as the
    /// utterance has been handed off, not when it finishes.
    func speak(_ text: String, config: SpeechConfig)
    /// Add to what is already being said, keeping order.
    ///
    /// This is what streaming needs. Synthesis runs at about 1× realtime, so waiting
    /// for a complete answer means the voice starts only once the whole thing has
    /// arrived and then talks for as long again. Handing over one sentence at a time
    /// overlaps the two: the second sentence is generated while the first is being
    /// spoken, and the delay the user hears is one sentence rather than one answer.
    func enqueue(_ text: String, config: SpeechConfig)
    /// Stop immediately and drop anything queued. Called on Esc and whenever the
    /// answer panel goes away.
    func stop()
    /// Get ready to speak, at a moment when nobody is waiting. Cheap and idempotent.
    func prewarm(config: SpeechConfig)
}

// MARK: - System

/// `AVSpeechSynthesizer`. No setup, no dependency, no wait.
@MainActor
final class SystemSpeechOutput: SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, config: SpeechConfig) {
        stop()
        enqueue(text, config: config)
    }

    /// `AVSpeechSynthesizer` already keeps its own ordered queue, so streaming here is
    /// just not stopping first.
    func enqueue(_ text: String, config: SpeechConfig) {
        let utterance = AVSpeechUtterance(string: text)
        // AVSpeechUtteranceDefaultSpeechRate is ~0.5 and maps to roughly 175 wpm, which
        // is what the setting is expressed in — a number a person can reason about.
        utterance.rate = Float(config.rate / 175.0) * AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Nothing to warm — the system voice is already resident.
    func prewarm(config: SpeechConfig) {}
}

// MARK: - Qwen3-TTS

/// Qwen3-TTS through a resident `mlx-audio` sidecar.
///
/// The model takes ~13s to load and then synthesises at about 1× realtime, so the
/// process is started once and kept — see the header of `qwen_tts_server.py` for the
/// measurements and for why the protocol doesn't use stdout. `prewarm` is what makes
/// that load land somewhere harmless: it's called when the answer panel opens, so the
/// weights are resident by the time there is an answer to read.
///
/// Every failure path here is silent-but-logged rather than user-facing. Speech is a
/// garnish on an answer the user can already read; a dialog because a Python
/// environment moved would be far more disruptive than the missing audio.
@MainActor
final class QwenSpeechOutput: SpeechOutput {
    private var sidecar: Sidecar?
    private var player: AVAudioPlayer?
    /// Fragments waiting to be synthesised, in the order they were handed over.
    private var pending: [String] = []
    /// Whether a drain loop is already consuming `pending`.
    private var draining = false
    /// Resumed when the current clip ends, so the drain loop plays one at a time
    /// instead of overlapping every fragment it has finished synthesising.
    private var finishedPlaying: CheckedContinuation<Void, Never>?
    /// Bumped on every `speak` and `stop`, so a synthesis that finishes after the user
    /// has moved on is discarded instead of talking over the next thing.
    private var generation = 0
    /// Remembered so a failed start isn't retried on every single answer, which would
    /// mean a 13s process launch per utterance for a user whose Python is broken.
    private var startupFailed = false

    func prewarm(config: SpeechConfig) {
        _ = ensureSidecar(config: config)
    }

    func speak(_ text: String, config: SpeechConfig) {
        stop()
        enqueue(text, config: config)
    }

    /// Append one fragment. Synthesis and playback are both serialised, so fragments
    /// come out in the order they arrived even though a later one may finish
    /// synthesising first.
    func enqueue(_ text: String, config: SpeechConfig) {
        guard let sidecar = ensureSidecar(config: config) else { return }
        pending.append(text)
        drain(sidecar: sidecar, config: config)
    }

    /// One drain task at a time, taking the queue in order. A second `enqueue` while
    /// this is running just leaves more in `pending` for the same loop to pick up.
    private func drain(sidecar: Sidecar, config: SpeechConfig) {
        guard !draining else { return }
        draining = true
        let mine = generation
        let voice = config.voice.rawValue

        Task { [weak self] in
            defer { Task { @MainActor in self?.draining = false } }
            while true {
                guard let self, self.generation == mine else { return }
                guard !self.pending.isEmpty else { return }
                let next = self.pending.removeFirst()

                guard let url = await sidecar.synthesize(text: next, voice: voice) else {
                    continue   // one bad fragment shouldn't silence the rest
                }
                defer { try? FileManager.default.removeItem(at: url) }
                // Discard a fragment that finished after the user moved on.
                guard self.generation == mine else { return }
                await self.playToEnd(url, config: config)
            }
        }
    }

    func stop() {
        generation += 1
        pending.removeAll()
        player?.stop()
        player = nil
        finishedPlaying?.resume()
        finishedPlaying = nil
    }

    /// Shut the sidecar down. Called when speech is switched off in Settings and at
    /// app exit — four gigabytes is not something to keep resident for a feature the
    /// user has just turned off.
    func shutdown() {
        stop()
        let running = sidecar
        sidecar = nil
        startupFailed = false
        Task { await running?.quit() }
    }

    private func ensureSidecar(config: SpeechConfig) -> Sidecar? {
        if let sidecar { return sidecar }
        guard !startupFailed else { return nil }
        guard let script = Self.scriptURL() else {
            Log.talk.error("qwen_tts_server.py isn't in the bundle — rebuild with Scripts/build-app.sh")
            startupFailed = true
            return nil
        }
        guard let python = Self.resolveInterpreter(explicit: config.pythonPath) else {
            Log.talk.error("No Python with mlx-audio found — set one in Settings")
            startupFailed = true
            return nil
        }
        let created = Sidecar(python: python, script: script)
        sidecar = created
        Task { [weak self] in
            if await created.start() { return }
            await MainActor.run {
                guard let self else { return }
                // Don't tear down a sidecar the user may have replaced in the meantime.
                if self.sidecar === created { self.sidecar = nil }
                self.startupFailed = true
            }
        }
        return created
    }

    /// Play one clip and wait for it to finish.
    ///
    /// The wait is what keeps a streamed answer in order: without it the drain loop
    /// would start the next fragment the moment its synthesis returned, and two
    /// sentences would talk over each other. `AVAudioPlayer.duration` is used rather
    /// than the delegate callback because the delegate would have to be a separate
    /// non-isolated object, and the duration of a file we just wrote is exact.
    private func playToEnd(_ url: URL, config: SpeechConfig) async {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            Log.talk.error("Couldn't play synthesised speech: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Qwen has no speaking-rate control of its own — it generates at whatever
        // pace it generates — so the rate setting is applied at playback instead.
        // Without this the slider silently did nothing on this engine, and there was
        // no way to speed up a voice that reads slowly.
        player.enableRate = true
        player.rate = Float(max(0.5, min(2.0, config.rate / 175.0)))
        self.player = player
        player.play()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishedPlaying = continuation
            let seconds = max(player.duration / Double(player.rate), 0.05)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // `stop()` may have resumed and cleared it already.
                guard let self, let waiting = self.finishedPlaying else { return }
                self.finishedPlaying = nil
                waiting.resume()
            }
        }
    }

    /// The sidecar lives next to the other bundled resources. There is deliberately no
    /// fallback to a path inside the source tree: that would work on this machine and
    /// nowhere else, and would hide a broken build until someone else ran it.
    static func scriptURL() -> URL? {
        Bundle.main.url(forResource: "qwen_tts_server", withExtension: "py")
    }

    /// An explicit setting wins. Otherwise try the usual places and take the first one
    /// that both exists and can actually import `mlx_audio` — a Python that merely
    /// exists is the common case and the useless one.
    static func resolveInterpreter(explicit: String) -> URL? {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // An explicit path is honoured even if the import check fails: the user
            // said to use this one, and a misconfigured venv should show up in the log
            // as the real error rather than as a silent fall-through to another Python.
            return FileManager.default.isExecutableFile(atPath: trimmed) ? URL(fileURLWithPath: trimmed) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in SpeechConfig.candidateInterpreters(home: home) {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if canImportMLXAudio(URL(fileURLWithPath: candidate)) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func canImportMLXAudio(_ python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import mlx_audio"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Owns the Python process and serialises requests to it.
    ///
    /// An actor because the process is one resource with one stdin: two answers
    /// arriving close together must queue rather than interleave their JSON lines.
    /// `Process` isn't `Sendable`, so it is confined here and never handed out.
    private actor Sidecar {
        private let python: URL
        private let script: URL
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var started = false

        init(python: URL, script: URL) {
            self.python = python
            self.script = script
        }

        /// Launch and wait for the ready handshake. ~13s on a warm filesystem, which is
        /// why this is called from `prewarm` rather than from the first `speak`.
        func start() async -> Bool {
            guard !started else { return true }
            process.executableURL = python
            process.arguments = [script.path]
            process.standardInput = input
            process.standardOutput = output
            // Left inherited so the model's own progress chatter lands in the app log.
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            // Without this the tokenizers library forks a thread pool per generation and
            // spends the first second warning about it.
            environment["TOKENIZERS_PARALLELISM"] = "false"
            process.environment = environment

            do {
                try process.run()
            } catch {
                Log.talk.error("Couldn't start the TTS sidecar: \(error.localizedDescription, privacy: .public)")
                return false
            }

            guard let reply = readReply(), reply["ready"] as? Bool == true else {
                Log.talk.error("TTS sidecar failed to load its model")
                terminate()
                return false
            }
            started = true
            Log.talk.info("TTS sidecar ready")
            return true
        }

        func synthesize(text: String, voice: String) async -> URL? {
            if !started, await !start() { return nil }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("gaithano-tts-\(UUID().uuidString).wav")
            let job: [String: Any] = ["text": text, "voice": voice, "out": out.path]
            guard let data = try? JSONSerialization.data(withJSONObject: job) else { return nil }

            do {
                try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
            } catch {
                Log.talk.error("TTS sidecar stdin closed: \(error.localizedDescription, privacy: .public)")
                started = false
                return nil
            }

            guard let reply = readReply() else {
                started = false
                return nil
            }
            if reply["ok"] as? Bool == true, FileManager.default.fileExists(atPath: out.path) {
                return out
            }
            let why = reply["error"] as? String ?? "unknown error"
            Log.talk.error("TTS synthesis failed: \(why, privacy: .public)")
            return nil
        }

        func quit() {
            guard process.isRunning else { return }
            let job = Data(#"{"command":"quit"}"# .utf8) + Data("\n".utf8)
            try? input.fileHandleForWriting.write(contentsOf: job)
            terminate()
        }

        private func terminate() {
            started = false
            guard process.isRunning else { return }
            process.terminate()
        }

        /// One newline-terminated JSON object from the sidecar's private channel.
        ///
        /// Byte-at-a-time because there is no framing beyond the newline and a bulk read
        /// would block until the pipe filled. The volume is a handful of short objects
        /// per answer, so the syscall count is irrelevant next to a 4.5s synthesis.
        private func readReply() -> [String: Any]? {
            let handle = output.fileHandleForReading
            var buffer = Data()
            while true {
                guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else {
                    return nil   // EOF: the process died.
                }
                if byte.first == 0x0A { break }
                buffer.append(byte)
                // A runaway line means the protocol channel got polluted after all.
                if buffer.count > 64_000 { return nil }
            }
            return try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
        }
    }
}
