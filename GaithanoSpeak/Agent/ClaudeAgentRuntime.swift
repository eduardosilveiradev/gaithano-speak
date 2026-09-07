import Foundation
import Observation
import SpeakCore
import os

/// Drives Agent Mode's embedded Claude Code session: one process per turn, its stdout
/// parsed into `AgentEvent`s, its session id carried forward so a follow-up continues
/// the same conversation.
///
/// This is the third thing in the app to run the `claude` binary, and it deliberately
/// borrows rather than repeats: `ClaudeCLIFormatter.resolveExecutable` finds the
/// binary (a launchd-started GUI app has a bare PATH, so `claude` is never simply "on
/// the path"), and `ClaudeCLIFormatter.childEnvironment()` repairs that PATH. What it
/// does *not* borrow is that environment's thinking switch — see `childEnvironment()`
/// below, where the difference is spelled out.
///
/// The flags are the tool boundary, and every one of them is load-bearing:
///
/// - `--system-prompt` **replaces** Claude Code's own prompt. Leave that prompt in
///   place and the model reads "book me a table" as a coding task in an empty
///   repository — the formatter and Talk both learned this the same way.
/// - `--allowed-tools` is a *positive* list of `mcp__*` names. `--disallowed-tools`
///   names the built-ins as well, but that list is belt-and-braces only: a denylist
///   cannot know about the tool Claude Code ships next month, and Agent Mode's whole
///   promise is that no file or shell tool exists.
/// - `--setting-sources ""` skips user, project, and local settings, and with them
///   every hook the user has configured. Without it someone's SessionStart hook runs
///   each time the user asks to turn the lights off.
/// - `--strict-mcp-config` with our own `--mcp-config` means the servers Claude sees
///   are exactly the ones the approval proxy published — not whatever the user has
///   configured for their own work.
/// - `--disable-slash-commands` keeps the user's skills out of a request that is
///   supposed to be four bounded MCP servers and nothing else.
@MainActor
@Observable
final class ClaudeAgentRuntime {

    /// Everything the runtime needs from the rest of the app. Injected rather than
    /// read from settings here so the MCP half can publish its config file and tool
    /// list without this type knowing how either was produced.
    struct Configuration: Sendable {
        /// `AppSettings.formatterClaudePath` — the same binary, so the same override.
        var executablePath: String = ""
        /// Written by the approval proxy: the only `mcpServers` map Claude Code sees.
        var mcpConfigPath: String = ""
        /// Fully-qualified `mcp__<server>__<tool>` names. The escalation tool is added
        /// here regardless, since the runtime cannot function without it.
        var allowedTools: [String] = []
        /// Not a run timeout — an agent run legitimately takes minutes. This is how
        /// long the CLI may emit *nothing at all* before it counts as dead. A run
        /// timeout would kill good long tasks; silence is the signal that means
        /// something actually broke.
        var stallTimeout: TimeInterval = 120
    }

    var configuration = Configuration()

    private(set) var tier: AgentModelTier = .sonnet
    private(set) var isRunning = false
    private(set) var conversation = AgentConversation(lastActivityAt: .distantPast)

    /// The only way out of here. The coordinator folds these into an `AgentTranscript`
    /// and the panel draws that — nothing renders an event directly.
    let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation

    private var router = AgentModelRouter()
    private var parser = ClaudeCodeStreamParser()
    private var turn: Task<Void, Never>?
    private var process: TurnProcess?
    private var expiry: Task<Void, Never>?
    /// Bumped by every `start` and `cancel`. A turn that has been superseded checks it
    /// before emitting, so a process killed mid-line cannot append a stale step to the
    /// request that replaced it.
    private var generation = 0
    /// Escalation outcomes by tool-call id. The request reaches this class twice — once
    /// as a tool call the control MCP server has to answer, once as a `tool_use` line
    /// on stdout — and the two race. Keyed by id so whichever arrives first moves the
    /// ladder and the other reads the same answer back rather than climbing a second
    /// rung on one request.
    private var escalations: [String: AgentModelRouter.Outcome] = [:]
    private var pendingEscalation: (tier: AgentModelTier, reason: String)?
    private let scratch: URL

    init() {
        let stream = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        sink = stream.continuation
        // The spec's "app termination deletes expired temporary data on the next
        // launch if an earlier shutdown could not clean it up" — a crash mid-run is
        // exactly the case where the 15-minute deletion promise otherwise quietly
        // becomes forever.
        Self.purgeStaleScratch()
        scratch = Self.makeScratchDirectory()
    }

    // MARK: - Driving a request

    /// Begin a request. Any turn still running is killed first: the spec makes a new
    /// spoken request a cancellation, and two Claudes acting on one screen is worse
    /// than either alone.
    func start(request text: String) {
        // Silently, because `.requestStarted` clears the transcript a moment later —
        // a `.cancelled` the user never sees drawn is noise in the event log.
        stopTurn(silently: true)
        expireIfNeeded()

        router.beginRequest()
        tier = router.tier
        escalations = [:]
        pendingEscalation = nil
        isRunning = true
        conversation.touch(at: Date())
        scheduleExpiry()

        emit(.requestStarted(text))
        emit(.phase(.thinking))

        let mine = generation
        turn = Task { [weak self] in
            await self?.drive(request: Self.requestPrompt(text), generation: mine)
        }
    }

    /// Escape, or the panel's stop button. Terminates the process and leaves the
    /// transcript as it stands — `AgentTranscript.apply(.cancelled)` marks anything
    /// that was mid-flight `.interrupted`, which is what stops a later run from
    /// replaying a half-sent message.
    func cancel() {
        guard isRunning else { return }
        stopTurn(silently: false)
    }

    /// End the conversation and delete everything it owned. Called on expiry, and
    /// available to the user as "new conversation".
    func reset() {
        stopTurn(silently: true)
        endSession()
    }

    // MARK: - The control server's one entry point

    /// What the `control` MCP server returns for a `escalate_model` call.
    ///
    /// The server is a thin shell on purpose: the ladder lives here, in the one object
    /// that also owns the session it has to resume, so there is no second place that
    /// can decide which model is running. `callID` is the `tool_use` id, which is what
    /// makes this safe to call alongside the same request arriving on stdout.
    func escalationAcknowledgement(callID: String, reason: String) -> String {
        AgentModelRouter.acknowledgement(for: recordEscalation(callID: callID, reason: reason))
    }

    @discardableResult
    private func recordEscalation(callID: String, reason: String) -> AgentModelRouter.Outcome {
        if let already = escalations[callID] { return already }
        let outcome = router.escalate(reason: reason)
        escalations[callID] = outcome
        if case let .escalated(_, to, cleaned) = outcome {
            pendingEscalation = (to, cleaned)
        }
        return outcome
    }

    private func drive(request: String, generation mine: Int) async {
        var prompt = request

        while generation == mine {
            let outcome = await runTurn(prompt: prompt, generation: mine)
            if let latest = parser.sessionID { conversation.sessionID = latest }
            conversation.touch(at: Date())
            scheduleExpiry()

            switch outcome {
            case .ended:
                isRunning = false
                return

            case .cancelled:
                return

            case let .escalate(to, reason):
                // Resuming is the whole mechanism behind "escalation must not repeat
                // actions already completed": the stronger model reads the same
                // session transcript, tool results included, so a click that already
                // landed is visible to it as done. Starting a fresh session on the
                // new model would hand it the request with no memory of what happened
                // — which is precisely how a message gets sent twice.
                guard conversation.sessionID != nil else {
                    emit(.failed("Couldn't escalate: Claude Code never reported a session to resume, "
                                 + "and starting over on \(to.displayName) would repeat work already done."))
                    isRunning = false
                    return
                }
                tier = to
                pendingEscalation = nil
                emit(.escalated(to: to, reason: reason))
                emit(.phase(.thinking))
                prompt = AgentModelRouter.continuationPrompt(reason: reason)
            }
        }
    }

    private enum TurnOutcome {
        case ended
        case cancelled
        case escalate(AgentModelTier, String)
    }

    private func runTurn(prompt: String, generation mine: Int) async -> TurnOutcome {
        guard let executable = ClaudeCLIFormatter.resolveExecutable(
            explicitPath: configuration.executablePath) else {
            emit(.failed("Can't find the `claude` command. Install Claude Code, or set its path in Settings."))
            return .ended
        }
        // Running without the proxy's config would give Claude a conversation and no
        // tools — it would answer as if it had acted. Failing loudly is the honest
        // version, and the spec asks for the unavailable capability to be named.
        guard !configuration.mcpConfigPath.isEmpty,
              FileManager.default.fileExists(atPath: configuration.mcpConfigPath) else {
            emit(.failed("Agent Mode has no tools: its MCP servers haven't started."))
            return .ended
        }

        let arguments = Self.arguments(prompt: prompt,
                                       resume: conversation.sessionID,
                                       tier: tier,
                                       configuration: configuration)
        let proc = TurnProcess(executable: executable,
                               arguments: arguments,
                               workingDirectory: scratch,
                               environment: Self.childEnvironment())
        process = proc

        let lines = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let stallTimeout = configuration.stallTimeout
        let exited = Task.detached(priority: .userInitiated) { () -> TurnProcess.Exit in
            let exit = proc.run(stallTimeout: stallTimeout) { lines.continuation.yield($0) }
            lines.continuation.finish()
            return exit
        }

        var sawTerminalEvent = false

        for await line in lines.stream {
            guard generation == mine else { break }
            for event in parser.parse(line: line) {
                if case let .step(step) = event,
                   let call = step.call,
                   let reason = AgentModelRouter.escalationReason(in: call),
                   escalations[call.id] == nil,
                   case let .atCeiling(top) = recordEscalation(callID: call.id, reason: reason) {
                    // The control server tells the model the same thing, but if that
                    // server is missing the user would otherwise watch the run carry
                    // on with no explanation of why the model stayed put.
                    emit(.step(AgentStep(id: step.id + ".ceiling",
                                         note: "Stayed on \(top.displayName) — there is no larger model to hand this to.",
                                         status: .completed)))
                }

                switch event {
                case .responseFinished, .failed:
                    sawTerminalEvent = true
                    // A turn that is being handed up the ladder has not produced the
                    // user's answer, only the losing model's parting words. Emitting
                    // it would end the run in the panel while the run continues.
                    if pendingEscalation != nil { continue }
                default:
                    break
                }
                emit(event)
            }
        }

        let exit = await exited.value
        if process === proc { process = nil }
        guard generation == mine else { return .cancelled }

        switch exit {
        case .cancelled:
            return .cancelled

        case .stalled:
            emit(.failed("Claude Code stopped responding after \(Int(stallTimeout))s. "
                         + "Nothing was retried — ask again and it will check the current state first."))
            return .ended

        case let .finished(status, stderr):
            if let pendingEscalation { return .escalate(pendingEscalation.tier, pendingEscalation.reason) }
            guard !sawTerminalEvent else { return .ended }
            // No `result` line at all: the CLI died before finishing its turn. It exits
            // 0 on a *failed* turn, so the status is only informative when it isn't.
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.error("agent turn exit \(status, privacy: .public): \(detail, privacy: .public)")
            emit(.failed(detail.isEmpty
                         ? "Claude Code ended the turn without answering."
                         : String(detail.prefix(200))))
            return .ended
        }
    }

    // MARK: - Lifecycle

    private func stopTurn(silently: Bool) {
        generation &+= 1
        process?.cancel()
        process = nil
        turn?.cancel()
        turn = nil
        if isRunning && !silently { emit(.cancelled) }
        isRunning = false
    }

    /// End the Claude Code session and delete what it left behind. Both halves matter:
    /// dropping the id without clearing the scratch directory leaves screenshots and
    /// CLI state on disk past the 15 minutes the spec promises.
    private func endSession() {
        expiry?.cancel()
        expiry = nil
        conversation = AgentConversation(lastActivityAt: .distantPast)
        parser = ClaudeCodeStreamParser()
        escalations = [:]
        pendingEscalation = nil
        router.beginRequest()
        tier = router.tier
        Self.emptyDirectory(scratch)
    }

    /// A conversation is only expired if nothing has happened for 15 minutes — the
    /// clock runs from the last request or the last turn, never from when the session
    /// opened, or a long task would lose its own context mid-run.
    func expireIfNeeded(now: Date = Date()) {
        guard !isRunning, conversation.sessionID != nil, conversation.isExpired(at: now) else { return }
        Self.log.info("agent conversation expired after 15 minutes idle — session ended, scratch deleted")
        endSession()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AgentConversation.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded()
        }
    }

    private func emit(_ event: AgentEvent) {
        sink.yield(event)
    }

    // MARK: - Arguments

    /// Built-ins named explicitly. Redundant against the positive list above and kept
    /// anyway: if a future Claude Code changes how an empty-ish allowlist is read,
    /// this is the line that still says "no files, no shell".
    static let disallowedTools = [
        "Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit",
        "Bash", "WebFetch", "WebSearch", "Task",
    ]

    static func arguments(prompt: String,
                          resume: String?,
                          tier: AgentModelTier,
                          configuration: Configuration) -> [String] {
        var arguments = [
            "-p",
            "--model", tier.claudeModelID,
            "--system-prompt", systemPrompt,
            "--strict-mcp-config",
            "--mcp-config", configuration.mcpConfigPath,
            "--setting-sources", "",
            "--allowed-tools", allowedTools(configuration).joined(separator: ","),
            "--disallowed-tools", disallowedTools.joined(separator: ","),
            "--disable-slash-commands",
            "--output-format", "stream-json",
            "--include-partial-messages",
            // stream-json refuses to run in print mode without it.
            "--verbose",
        ]
        if let resume, !resume.isEmpty {
            arguments += ["--resume", resume]
        }
        arguments.append(prompt)
        return arguments
    }

    /// Anything that isn't an `mcp__` name is dropped rather than passed through.
    /// This list *is* the boundary — a caller that could add "Bash" to it would have
    /// undone the one guarantee Agent Mode makes.
    static func allowedTools(_ configuration: Configuration) -> [String] {
        var names = Set(configuration.allowedTools.filter { $0.hasPrefix("mcp__") })
        names.insert(AgentModelRouter.escalateToolQualifiedName)
        return names.sorted()
    }

    /// A dictated request can begin with anything, and the prompt is a positional
    /// argument — a transcript starting with a dash would be read as a flag. The
    /// envelope guarantees a letter, and once `--resume` is in play it also marks
    /// where this request's words start in a conversation that already has several.
    static func requestPrompt(_ text: String) -> String {
        "User request: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// `ClaudeCLIFormatter.childEnvironment()` with thinking put **back on**.
    ///
    /// `MAX_THINKING_TOKENS=0` is worth eight seconds a dictation and it is the right
    /// call there, because deciding where a comma goes is not reasoning. This is the
    /// opposite job: the model is choosing which button to press on someone's screen,
    /// with an approval prompt as the only thing between a wrong choice and a sent
    /// message. The measurement that justified switching it off — ~530 output tokens
    /// to punctuate one sentence — is exactly the budget an agent step should have.
    /// Inheriting the formatter's environment wholesale would silently make Agent Mode
    /// the least careful path in the app.
    static func childEnvironment() -> [String: String] {
        var environment = ClaudeCLIFormatter.childEnvironment()
        environment.removeValue(forKey: "MAX_THINKING_TOKENS")
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING")
        return environment
    }

    static let systemPrompt = """
    You are the assistant inside Gaithano Speak, a macOS app. The user speaks a \
    request out loud and you carry it out on their Mac, in their browser, and on \
    their SmartThings devices, using only the MCP tools you have been given.

    You are not a coding assistant. You have no files, no shell, no scripting, and no \
    way to read or change anything on disk. Do not offer to write code, and never \
    claim to have done something a tool did not do.

    How to work:
    - Look before you act. Take a screenshot, read the accessibility tree, and confirm \
    the thing you are about to click is the thing you meant.
    - Act one step at a time and check the result of each step before the next.
    - Some actions pause for the user's approval. That is normal. If one is denied, \
    do not look for another route to the same thing — ask what they would prefer.
    - If a step's outcome is unclear, inspect the current state rather than repeating it.
    - Say what you are doing in short plain sentences. The user reads them in a small \
    panel and hears your final answer read aloud, so end with one or two sentences \
    that answer them — not a summary of your steps.
    - If you cannot do something, say so plainly and say why.

    \(AgentModelRouter.escalationGuidance)
    """

    // MARK: - Scratch storage

    /// Deliberately *not* `ClaudeCLIFormatter.workingDirectory`. That folder is shared
    /// by the formatter and Talk, which stage and sweep screenshots there by filename
    /// prefix; a conversation whose data must be gone in 15 minutes cannot live in a
    /// directory another feature deletes from on its own schedule. Same reason for
    /// keeping it empty: CLAUDE.md discovery walks up from the cwd, and a real project
    /// underneath would pull that project's instructions into "turn the lights off".
    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("GaithanoSpeak/agent", isDirectory: true)

    private static func makeScratchDirectory() -> URL {
        let directory = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func purgeStaleScratch() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: scratchRoot,
                                                    includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let cutoff = Date().addingTimeInterval(-AgentConversation.idleTimeout)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func emptyDirectory(_ directory: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? fm.removeItem(at: url) }
    }

    static let log = Logger(subsystem: Log.subsystem, category: "agent")
}

// MARK: - One `claude` invocation

/// Owns a single turn's process and its streaming stdout. `Process` and its pipes
/// aren't `Sendable`, so — as in `ClaudeCLIFormatter` and `ClaudeCodeTalkProvider` —
/// the class is the isolation boundary and its own lock is what makes that safe.
private final class TurnProcess: @unchecked Sendable {

    enum Exit {
        case finished(status: Int32, stderr: String)
        case cancelled
        /// No output at all for the stall window. Distinguished from a normal exit
        /// because the recovery differs: nothing is retried, and the model is asked to
        /// re-inspect rather than resume.
        case stalled
    }

    private let process = Process()
    private let out = Pipe()
    private let err = Pipe()
    private let lock = NSLock()
    private var lastOutput = Date()
    private var cancelled = false
    private var stalled = false

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        // An inherited stdin leaves the CLI waiting out its 3s idle timer before it
        // starts on a prompt it already has.
        process.standardInput = FileHandle.nullDevice
    }

    /// Blocking. Run on a detached task, never on the main actor.
    func run(stallTimeout: TimeInterval, onLine: @escaping @Sendable (String) -> Void) -> Exit {
        // Drain stderr concurrently: a full 64KB pipe buffer while this thread is
        // blocked reading stdout is a deadlock, and an agent turn writes far more
        // there than a formatting call does.
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
            return .finished(status: -1, stderr: "couldn't start the claude CLI: \(error.localizedDescription)")
        }

        // Polled rather than a single deadline: the window restarts with every line,
        // so a turn that keeps working keeps living, and one that has genuinely hung
        // is caught within a few seconds of the timeout.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + stallTimeout, repeating: 5)
        watchdog.setEventHandler { [self] in
            lock.lock()
            let idle = Date().timeIntervalSince(lastOutput)
            let alreadyDone = cancelled || stalled
            if idle >= stallTimeout && !alreadyDone { stalled = true }
            let shouldKill = idle >= stallTimeout && !alreadyDone
            lock.unlock()
            if shouldKill { kill() }
        }
        watchdog.resume()

        readLines { line in
            lock.lock(); lastOutput = Date(); lock.unlock()
            onLine(line)
        }

        process.waitUntilExit()
        watchdog.cancel()
        drained.wait()

        lock.lock()
        let wasCancelled = cancelled
        let wasStalled = stalled
        lock.unlock()

        if wasCancelled { return .cancelled }
        if wasStalled { return .stalled }
        let stderr = String(decoding: errorBuffer.value, as: UTF8.self)
        return .finished(status: process.terminationStatus, stderr: stderr)
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        kill()
    }

    /// One whole line at a time. The CLI emits one JSON object per line, so decoding
    /// only on a newline sidesteps both split objects and split UTF-8 sequences.
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

/// A lock-guarded `Data` slot, so the stderr reader and the waiting thread can share
/// one buffer without a race.
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
