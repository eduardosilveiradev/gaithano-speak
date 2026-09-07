import Foundation
import SpeakCore

/// Formats transcripts by shelling out to the `claude` CLI in print mode.
///
/// This replaced `VertexFormatter` as the cloud formatting option. It buys the same
/// thing — a real model that fixes grammar the on-device one is blind to — off the
/// user's existing Claude subscription rather than a GCP project with billing that
/// can lapse. Talk still runs on Vertex; only the dictation correction
/// pass moved.
///
/// Two properties of this path are worth knowing before touching it:
///
/// **It leaves the machine.** Every word dictated while this formatter is selected,
/// in every app, is sent to Anthropic. Same trade `VertexFormatter` made, different
/// destination — the Settings warning says so plainly and shouldn't be softened.
/// The CLI also writes a session transcript per invocation under `~/.claude/`, so
/// dictated text lands on disk as well as on the wire.
///
/// **The cost is the request, not process startup.** `claude --version` returns in 70ms;
/// `--output-format json` puts `duration_api_ms` at essentially the whole wall clock.
/// With thinking off — see `childEnvironment()`, which is doing most of the work here —
/// a one-sentence utterance takes ~1.5–3s. What's left is payload: the request carries
/// 29 tool definitions no matter what `--allowed-tools ""` says, so ~700 tokens of ours
/// arrive wrapped in ~16.5k. Prewarming doesn't help — `claude -p` does nothing until
/// stdin closes or the prompt argument parses, so spawning early and feeding the
/// transcript later measured *worse*, and stdin has a 3s idle bail-out. Nor does driving
/// a long-lived background session: it saves the 70ms, re-sends the tools every turn,
/// and accumulates history so each dictation carries the last one. Getting under a
/// second means the Messages API over HTTP, which costs an API key — the thing the CLI
/// exists here to avoid needing.
///
/// The flags are load-bearing, not tidiness:
/// - `--system-prompt` *replaces* Claude Code's own prompt. With its agentic prompt
///   in place, Haiku treats a dictated sentence as a task and answers it — two of
///   three trial runs did exactly that. `PromptBuilder.instructions` is what keeps
///   this a formatter.
/// - `--setting-sources ""` skips user/project/local settings, and with them every
///   hook the user has configured. Without it, a SessionStart hook runs on every
///   single utterance.
/// - `--strict-mcp-config` with an empty server map, `--allowed-tools ""`, and
///   `--disable-slash-commands` strip tools, MCP connections, and skills. None of
///   them belong in a punctuation pass, and all of them cost startup time.
/// - The working directory is a dedicated empty folder so CLAUDE.md auto-discovery
///   finds nothing. Run from a real project and its instructions — and its memory —
///   get pulled into the context of a punctuation request.
struct ClaudeCLIFormatter {
    struct Config: Sendable {
        /// Model alias or id passed to `--model`. See `AppSettings.formatterClaudeModel`
        /// for why the default is Sonnet rather than Haiku.
        var model: String
        /// Explicit path to the `claude` binary. Blank falls back to `discoveredPath`.
        /// A GUI app inherits a bare PATH from launchd, so the usual install locations
        /// are searched rather than trusted to be on it.
        var executablePath: String
    }

    /// Generous on purpose. A timeout here means the utterance silently degrades to
    /// grammar-blind `DeterministicCleanup`, and the floor for a successful call is
    /// already ~6s — anything tighter would fail good runs rather than catch hung ones.
    var timeout: TimeInterval = 20

    func format(_ raw: String,
                hints: FormattingHints,
                config: Config) async throws -> FormattedResult {
        guard let executable = Self.resolve(config) else {
            throw FormattingError.underlying("claude CLI not found")
        }

        let arguments = [
            "-p",
            "--model", config.model.isEmpty ? Self.defaultModel : config.model,
            "--system-prompt", PromptBuilder.instructions,
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "",
            "--allowed-tools", "",
            "--disable-slash-commands",
            // The prompt always begins with a letter (`PromptBuilder` ends with the
            // "Dictation to clean up:" block), so it can't be mistaken for a flag.
            PromptBuilder.prompt(for: raw, hints: hints),
        ]

        let signpost = Log.signposter
        let state = signpost.beginInterval("format")
        defer { signpost.endInterval("format", state) }

        let output = try await Self.run(executable: executable,
                                        arguments: arguments,
                                        workingDirectory: Self.workingDirectory,
                                        timeout: timeout)

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FormattingError.underlying("empty result") }
        guard !isRunaway(text, from: raw) else {
            Log.format.error("claude CLI returned \(text.count, privacy: .public) chars for \(raw.count, privacy: .public) — discarding")
            throw FormattingError.underlying("implausible formatter output")
        }
        return FormattedResult(text: text, formatter: .claude)
    }

    /// Whether the model wrote something other than a cleaned-up utterance.
    ///
    /// A cleanup pass can shorten text a lot ("scratch that") and lengthen it a little
    /// (expanded contractions, a restored article). It cannot triple it. What does
    /// triple it is the model breaking character and talking to the user — refusing,
    /// explaining its job, appending a note about what it won't do — which observably
    /// happens when thinking is off and the transcript reads as a command. The prompt
    /// forbids that and mostly holds; this is here because when it doesn't hold, the
    /// output goes straight into whatever the user was typing in.
    ///
    /// The floor keeps short utterances out of it: 3× of "ok fine" is still tiny, and
    /// legitimate small expansions there shouldn't trip a guard aimed at paragraphs.
    /// Throwing lands on `DeterministicCleanup` like every other formatter failure.
    private func isRunaway(_ text: String, from raw: String) -> Bool {
        text.count > max(120, raw.count * 3)
    }

    // MARK: - Locating the binary

    static let defaultModel = "sonnet"

    /// Install locations, in the order npm/bun/homebrew actually use them.
    private static let candidatePaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "\(NSHomeDirectory())/.bun/bin/claude",
        "\(NSHomeDirectory())/.npm-global/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// Where the CLI was found, or nil. Resolved once — a `static let` is lazy and
    /// thread-safe, and re-running six `stat`s per utterance buys nothing.
    static let discoveredPath: String? = candidatePaths.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    private static func resolve(_ config: Config) -> URL? {
        resolveExecutable(explicitPath: config.executablePath)
    }

    /// The user's explicit path if they set one, else wherever the CLI was found.
    /// Internal because `ClaudeCodeTalkProvider` runs the same binary — everything
    /// this file knows about locating and configuring it is shared, not duplicated.
    static func resolveExecutable(explicitPath: String) -> URL? {
        let explicit = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: explicit) else { return nil }
            return URL(fileURLWithPath: explicit)
        }
        return discoveredPath.map { URL(fileURLWithPath: $0) }
    }

    /// An empty directory of our own, so CLAUDE.md discovery walking up from the cwd
    /// finds nothing to load.
    static let workingDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("GaithanoSpeak/claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Running it

    /// Run the process to completion off the main actor, killing it if it overruns.
    private static func run(executable: URL,
                            arguments: [String],
                            workingDirectory: URL,
                            timeout: TimeInterval) async throws -> String {
        let run = ProcessRun(executable: executable,
                             arguments: arguments,
                             workingDirectory: workingDirectory,
                             environment: childEnvironment())
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try run.execute(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Inherit the environment — HOME is where the CLI keeps its credentials — but
    /// repair PATH and switch thinking off.
    ///
    /// PATH, because launchd hands a GUI app a bare one and the CLI shells out to its
    /// own helpers.
    ///
    /// Thinking, because it was most of the latency and all of the waste. Left on,
    /// Haiku spends ~530 output tokens reasoning about where a comma goes before
    /// emitting a 17-token sentence; these two variables take the call from ~16s and
    /// 530 tokens to ~1.5s and 17. `--effort low` does not do this — it is the only
    /// knob that looks like it should and the measurements say otherwise (726 tokens
    /// at low vs 580 at medium, i.e. noise). Removing them puts eight seconds back on
    /// every dictation.
    static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"] ?? ""
        let installDirs = candidatePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        environment["PATH"] = ([inherited] + installDirs)
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["MAX_THINKING_TOKENS"] = "0"
        environment["CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING"] = "1"
        return environment
    }

    /// Owns one `claude` invocation. `Process` and its pipes aren't `Sendable`, so
    /// they're confined here and never handed across an isolation boundary — the
    /// class is the boundary, and its own locking is what makes that safe.
    private final class ProcessRun: @unchecked Sendable {
        private let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private let lock = NSLock()
        private var timedOut = false

        init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            process.standardOutput = out
            process.standardError = err
            // Nothing to say on stdin, and an inherited one leaves the CLI waiting
            // out its 3s idle timer before it starts.
            process.standardInput = FileHandle.nullDevice
        }

        func execute(timeout: TimeInterval) throws -> String {
            // Drain stderr concurrently. It's small in practice, but a full 64KB pipe
            // buffer while the caller is blocked reading stdout is a deadlock.
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
                throw FormattingError.underlying(
                    "claude CLI failed to launch: \(error.localizedDescription)")
            }

            let killer = DispatchWorkItem { [self] in kill(after: timeout) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            drained.wait()

            lock.lock()
            let wasKilled = timedOut
            lock.unlock()

            if wasKilled {
                Log.format.error("claude CLI timed out after \(Int(timeout), privacy: .public)s")
                throw FormattingError.underlying("claude CLI timed out")
            }
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errorBuffer.value, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Log.format.error("claude CLI exit \(self.process.terminationStatus, privacy: .public): \(detail, privacy: .public)")
                throw FormattingError.underlying("claude CLI exit \(process.terminationStatus)")
            }
            return String(decoding: outputData, as: UTF8.self)
        }

        private func kill(after timeout: TimeInterval) {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
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
