import Foundation
import AppKit
import Carbon.HIToolbox
import SpeakCore

/// Drives one agent run: screenshot → model → classify → maybe confirm → execute →
/// screenshot again, until the model says it's done or something stops it.
///
/// The decisions live in `AgentSession` (pure, tested); this owns only the I/O and
/// the waiting. When the session says `.execute`, the action has already cleared the
/// risk policy and, if needed, the user — so there is exactly one call site that can
/// touch the machine and it is unconditional by design.
@MainActor
@Observable
final class AgentRunner {
    private(set) var session = AgentSession()
    /// The step list the panel renders. Mirrors `session.steps` plus what's in flight.
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Fires when the run parks on (or leaves) a confirmation, so the hotkey layer can
    /// start consuming bare ⏎ and A only for as long as they mean something.
    var onConfirmationChanged: ((Bool) -> Void)?
    /// Fires once when the run ends, with what to show the user.
    var onEnded: ((String) -> Void)?

    private let model: AgentModel
    private let policy: AgentRiskPolicy
    private var contents: [[String: Any]] = []
    private var shot: ScreenCapture.Shot?
    private var task: Task<Void, Never>?
    /// Resumes the loop when the user answers a confirmation prompt.
    private var pendingDecision: CheckedContinuation<AgentEvent, Never>?

    init(model: AgentModel, policy: AgentRiskPolicy = .default) {
        self.model = model
        self.policy = policy
    }

    // MARK: - Lifecycle

    func start(task spoken: String, autoConfirm: Bool = false) {
        guard !isRunning else { return }
        session = AgentSession(maxSteps: AgentPromptBuilder.defaultMaxSteps,
                               autoConfirm: autoConfirm)
        contents = []
        lastError = nil
        isRunning = true
        self.task = Task { [weak self] in await self?.run(spoken) }
    }

    /// Esc. Also the path taken when the panel closes or the app quits, so it must be
    /// safe to call at any point, including with nothing running.
    func stop() {
        task?.cancel()
        task = nil
        resume(.userAborted)
        if !session.status.isTerminal {
            _ = session.handle(.userAborted)
        }
        isRunning = false
    }

    /// ↩ — approve just this action.
    func confirm() { resume(.userConfirmed) }

    /// A — approve this and everything after it, for this run only.
    func enableAuto() { resume(.userEnabledAuto) }

    private func resume(_ event: AgentEvent) {
        guard let continuation = pendingDecision else { return }
        pendingDecision = nil
        continuation.resume(returning: event)
    }

    // MARK: - The loop

    private func run(_ spoken: String) async {
        defer { isRunning = false }

        guard let first = await ScreenCapture.capture() else {
            finish(.modelFailed("I can't see the screen — grant Screen Recording in Settings."))
            return
        }
        shot = first
        contents = [[
            "role": "user",
            "parts": [
                ["inlineData": ["mimeType": "image/jpeg",
                                "data": first.jpeg.base64EncodedString()]],
                ["text": AgentPromptBuilder.task(spoken)],
            ],
        ]]

        while !Task.isCancelled && !session.status.isTerminal {
            let turn: AgentModel.Turn
            do {
                let encoded = try JSONSerialization.data(withJSONObject: contents)
                turn = try await model.next(
                    contentsJSON: encoded,
                    systemPrompt: AgentPromptBuilder.instructions())
            } catch {
                finish(.modelFailed(message(for: error)))
                return
            }
            if Task.isCancelled { return }

            // Echoed back exactly as received, thought signatures and all — see
            // `AgentModel.Turn.rawParts`.
            if let parts = try? JSONSerialization.jsonObject(with: turn.rawParts) as? [Any] {
                contents.append(["role": "model", "parts": parts])
            }

            let risk = policy.risk(of: turn.action,
                                   inApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   // Read live rather than from the watcher's poll: a
                                   // field that gained focus since the last tick is
                                   // exactly the case this rail exists for.
                                   secureInputActive: IsSecureEventInputEnabled())

            var effects = session.handle(.proposed(turn.action, risk))
            if case .awaitingConfirmation = session.status {
                onConfirmationChanged?(true)
                let decision = await waitForUser()
                onConfirmationChanged?(false)
                if Task.isCancelled { return }
                effects = session.handle(decision)
            }

            for effect in effects {
                switch effect {
                case let .execute(action):
                    await execute(action, name: turn.toolName)
                case .askModel:
                    break   // the loop's next pass is the ask
                case let .finish(summary), let .stop(summary):
                    lastError = nil
                    Log.talk.info("Agent run ended: \(summary, privacy: .public)")
                    onEnded?(summary)
                }
            }
        }
    }

    private func execute(_ action: AgentAction, name: String) async {
        guard let shot else { return }
        var outcome = "done"
        do {
            try await AgentExecutor.perform(action, in: shot)
        } catch {
            // A failed action isn't fatal: tell the model what went wrong and let it
            // adapt. Stopping here would abandon runs over a single unknown keyname.
            outcome = "failed: \(error.localizedDescription)"
            Log.talk.error("Agent action failed: \(outcome, privacy: .public)")
        }

        // Re-photograph before reporting, so the model judges its own result.
        let next = await ScreenCapture.capture()
        if let next { self.shot = next }

        var parts: [[String: Any]] = [[
            "functionResponse": [
                "name": name,
                "response": ["status": outcome],
            ],
        ]]
        if let next {
            parts.append(["inlineData": ["mimeType": "image/jpeg",
                                         "data": next.jpeg.base64EncodedString()]])
        }
        contents.append(["role": "user", "parts": parts])
        pruneOldScreenshots()

        _ = session.handle(.actionCompleted)
    }

    private func waitForUser() async -> AgentEvent {
        await withCheckedContinuation { continuation in
            // If a stop raced in between the status check and here, don't park
            // forever — resolve immediately with the abort.
            if Task.isCancelled {
                continuation.resume(returning: .userAborted)
            } else {
                pendingDecision = continuation
            }
        }
    }

    /// Keep only the newest screenshot. Each is ~1000 prompt tokens and a 15-step run
    /// would otherwise carry fifteen of them, paying for stale views of a screen that
    /// has since changed — the model only ever needs the current one.
    private func pruneOldScreenshots() {
        guard contents.count > 1 else { return }
        for index in 0..<(contents.count - 1) {
            guard var parts = contents[index]["parts"] as? [[String: Any]] else { continue }
            let kept = parts.filter { $0["inlineData"] == nil }
            guard kept.count != parts.count else { continue }
            // A content with no parts is rejected, so leave a marker behind.
            parts = kept.isEmpty ? [["text": "(screenshot omitted)"]] : kept
            contents[index]["parts"] = parts
        }
    }

    private func finish(_ event: AgentEvent) {
        let effects = session.handle(event)
        for case let .stop(reason) in effects {
            lastError = reason
            Log.talk.error("Agent stopped: \(reason, privacy: .public)")
            onEnded?(reason)
        }
    }

    private func message(for error: Error) -> String {
        if let modelError = error as? AgentModel.ModelError {
            return modelError.errorDescription ?? "the model failed"
        }
        if let talkError = error as? TalkError {
            return talkError.localizedDescription
        }
        return error.localizedDescription
    }
}
