import Foundation
import SpeakCore

/// Answers Talk questions by shelling out to the `claude` CLI in print mode — the
/// same binary, and the same hardening, as `ClaudeCLIFormatter`.
///
/// It exists for the same reason the formatter does: it runs off the user's existing
/// Claude subscription rather than a GCP project whose billing can lapse, so it keeps
/// answering when Vertex doesn't. Everything the formatter's file documents about the
/// flags applies here unchanged — `--system-prompt` replacing Claude Code's own prompt
/// (without it a spoken question gets treated as a coding task in a scratch folder),
/// `--setting-sources ""` skipping the user's hooks, the empty cwd so CLAUDE.md
/// discovery finds nothing. `childEnvironment()` is shared rather than copied, which
/// is what keeps `MAX_THINKING_TOKENS=0` on this path too.
///
/// Two things differ from the formatter:
///
/// **It streams.** `--output-format stream-json --include-partial-messages` puts text
/// deltas on stdout as they arrive, so the answer panel fills in rather than sitting
/// blank for several seconds. The formatter has nothing to stream *to* — its output is
/// typed into another app in one go — so it takes the plain text output instead.
///
/// **It can see.** The CLI takes one text prompt and no inline image, so a screenshot
/// is written to the scratch folder and read with the Read tool, which is the only tool
/// allowed and only while an image is actually there. That costs a round trip: ~2.7s
/// text-only against ~5s with the screenshot, measured on Sonnet. The alternative was
/// letting this provider silently ignore the vision toggle, which is worse than the
/// wait — a setting that says an image is being sent has to mean it.
struct ClaudeCodeTalkProvider: TalkProvider {
    let id: TalkProviderID = .claudeCode

    /// Generous, because a timeout here doesn't mean "no answer" — it means the
    /// question quietly goes to the local server instead, and the user reads an answer
    /// from a much smaller model without being told which one wrote it. The floor is
    /// ~2.5s, ~5s with a screenshot; this only fires on a genuinely stuck run.
    var timeout: TimeInterval = 45

    func answer(_ request: TalkRequest,
                config: TalkConfig,
                onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let executable = ClaudeCLIFormatter.resolveExecutable(explicitPath: config.executablePath) else {
            throw TalkError.notConfigured(
                "can't find the `claude` command — install it, or set its path in Settings")
        }

        let screenshot = Self.writeScreenshot(request.context.screenshotJPEG)
        defer { if let screenshot { try? FileManager.default.removeItem(at: screenshot) } }

        let arguments = Self.arguments(for: request,
                                       config: config,
                                       screenshotPath: screenshot?.path)

        let signpost = Log.signposter
        let state = signpost.beginInterval("answer")
        defer { signpost.endInterval("answer", state) }

        let run = Run(executable: executable,
                      arguments: arguments,
                      workingDirectory: ClaudeCLIFormatter.workingDirectory)

        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try run.execute(timeout: timeout,
                                                                       onDelta: onDelta))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // esc dismissed the panel. Nothing is listening for the answer any more,
            // and a `claude` left running would keep spending the user's plan on it.
            run.cancel()
        }

        switch outcome {
        case let .answer(text): return text
        case let .failed(reason): throw TalkError.unreachable(reason)
        }
    }

    /// The flags, in the same order and for the same reasons as the formatter's, plus
    /// the streaming and vision ones. `--allowed-tools ""` is the default state: Read
    /// is granted only when there is an image in the scratch folder to read.
    private static func arguments(for request: TalkRequest,
                                  config: TalkConfig,
                                  screenshotPath: String?) -> [String] {
        var arguments = [
            "-p",
            "--model", config.model.isEmpty ? ClaudeCLIFormatter.defaultModel : config.model,
            "--system-prompt", TalkPromptBuilder.systemPrompt(forScreenshotAt: screenshotPath),
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "",
            "--allowed-tools", screenshotPath == nil ? "" : "Read",
            "--disable-slash-commands",
            "--output-format", "stream-json",
            "--include-partial-messages",
            // stream-json refuses to run in print mode without it.
            "--verbose",
        ]
        // The prompt always starts with a letter — "Earlier in this conversation",
        // "Screenshot", "(The user is currently in…", or "Question:" — so it can't be
        // mistaken for a flag.
        arguments.append(TalkPromptBuilder.flattenedPrompt(thread: request.thread,
                                                           screenshotPath: screenshotPath))
        return arguments
    }

    /// Put the screenshot in the CLI's own scratch folder, which is already its cwd —
    /// so Read reaches it without `--add-dir` widening what the model can open beyond
    /// one empty directory.
    ///
    /// Any earlier image is deleted first. `defer` in `answer` covers the normal path,
    /// but a crash mid-question would otherwise leave a picture of the user's screen
    /// sitting on disk indefinitely, and this bounds that to one.
    private static func writeScreenshot(_ jpeg: Data?) -> URL? {
        let directory = ClaudeCLIFormatter.workingDirectory
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.lastPathComponent.hasPrefix("talk-") {
            try? FileManager.default.removeItem(at: file)
        }

        guard let jpeg else { return nil }
        let url = directory.appendingPathComponent("talk-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return url
        } catch {
            // Degrade to a text-only question rather than failing it outright.
            Log.talk.error("Couldn't stage the screenshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Owns one `claude` invocation and its streaming stdout. `Process` and its pipes
    /// aren't `Sendable`, so — as in `ClaudeCLIFormatter` — the class is the isolation
    /// boundary and its own lock is what makes that safe.
    private final class Run: @unchecked Sendable {
        private let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private let lock = NSLock()
        private var timedOut = false
        private var cancelled = false

        init(executable: URL, arguments: [String], workingDirectory: URL) {
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = ClaudeCLIFormatter.childEnvironment()
            process.standardOutput = out
            process.standardError = err
            // An inherited stdin leaves the CLI waiting out its 3s idle timer.
            process.standardInput = FileHandle.nullDevice
        }

        func execute(timeout: TimeInterval,
                     onDelta: @escaping @Sendable (String) -> Void) throws -> ClaudeCodeOutcome {
            // Drain stderr concurrently: a full pipe buffer while this thread is
            // blocked on stdout is a deadlock.
            let errorBuffer = DataBuffer()
            let drained = DispatchSemaphore(value: 0)
            let errorHandle = err.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                errorBuffer.set(errorHandle.readDataToEndOfFile())
                drained.signal()
            }

            do {
                try process.run()
            } catch {
                throw TalkError.unreachable("couldn't start the claude CLI: \(error.localizedDescription)")
            }

            let killer = DispatchWorkItem { [self] in
                lock.lock(); timedOut = true; lock.unlock()
                kill()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            var outcome: ClaudeCodeOutcome?
            var streamed = ""
            readLines { line in
                if let delta = StreamChunkParser.claudeCodeDelta(fromJSONLine: line) {
                    streamed += delta
                    onDelta(delta)
                } else if let result = StreamChunkParser.claudeCodeResult(fromJSONLine: line) {
                    outcome = result
                }
            }

            process.waitUntilExit()
            killer.cancel()
            drained.wait()

            lock.lock()
            let wasKilled = timedOut
            let wasCancelled = cancelled
            lock.unlock()

            if wasCancelled { throw CancellationError() }
            if wasKilled {
                Log.talk.error("claude CLI timed out after \(Int(timeout), privacy: .public)s")
                throw TalkError.timedOut
            }
            if let outcome { return outcome }

            // No result line at all — the CLI died before finishing its turn.
            let detail = String(decoding: errorBuffer.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.talk.error("claude CLI exit \(self.process.terminationStatus, privacy: .public): \(detail, privacy: .public)")
            let streamedText = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            // A cut-off answer is still an answer; only fail if nothing arrived.
            guard streamedText.isEmpty else { return .answer(streamedText) }
            throw TalkError.unreachable(detail.isEmpty
                ? "the claude CLI exited \(process.terminationStatus)"
                : String(detail.prefix(200)))
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            kill()
        }

        /// Read stdout as it arrives, handing over one whole line at a time. The CLI
        /// emits one JSON object per line, so decoding only on a newline sidesteps
        /// both split objects and split UTF-8 sequences.
        private func readLines(_ onLine: (String) -> Void) {
            let handle = out.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        }

        private func kill() {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM is usually enough; Node occasionally isn't listening.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if self.process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }

    /// A lock-guarded `Data` slot, so the stderr reader and the waiting thread can
    /// share one buffer without a race.
    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
