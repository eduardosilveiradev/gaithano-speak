import Foundation

/// A completed (or attempted) step, for the panel's step list and for the model's
/// own history — it needs to see what it already did or it will repeat itself.
public struct AgentStepRecord: Equatable, Sendable {
    public var action: AgentAction
    public var confirmed: Bool
    public var note: String?

    public init(action: AgentAction, confirmed: Bool, note: String? = nil) {
        self.action = action
        self.confirmed = confirmed
        self.note = note
    }
}

public enum AgentEvent: Equatable, Sendable {
    /// The model proposed an action, already classified by the risk policy.
    case proposed(AgentAction, AgentRisk)
    case userConfirmed
    /// Approve this action and stop asking for the rest of the run.
    case userEnabledAuto
    case userAborted
    /// The executor finished the action it was handed.
    case actionCompleted
    case modelFailed(String)
}

public enum AgentEffect: Equatable, Sendable {
    case execute(AgentAction)
    /// Re-screenshot and ask the model what to do next.
    case askModel
    /// Run is over. The string is what the panel shows.
    case finish(String)
    case stop(String)
}

/// The agent loop as a pure reducer, mirroring `DictationStateMachine`: it decides
/// *whether* a step runs, never performs one. The runner owns the screenshots, the
/// network, and the CGEvents.
///
/// Keeping the loop here is what makes the confirmation rail testable — the step cap,
/// the auto-confirm escalation, and the "blocked survives auto mode" rule are all
/// exercised in `AgentTests` rather than trusted to the runner.
public struct AgentSession: Sendable, Equatable {
    public enum Status: Equatable, Sendable {
        case thinking
        case awaitingConfirmation(AgentAction, reason: String)
        case executing(AgentAction)
        case finished(String)
        case stopped(String)

        public var isTerminal: Bool {
            switch self {
            case .finished, .stopped: return true
            default: return false
            }
        }
    }

    public private(set) var status: Status = .thinking
    public private(set) var steps: [AgentStepRecord] = []
    /// Set by `.userEnabledAuto`. Deliberately per-run and not persisted here: the
    /// whole point of the rail is that a screen full of attacker-controlled text
    /// can't act unattended, and a setting that survives runs quietly removes it.
    public private(set) var autoConfirm: Bool
    /// Hard ceiling on actions. A model that loops — clicking the same dead button
    /// forever — costs real money and real clicks, so the cap is not optional.
    public let maxSteps: Int

    public init(maxSteps: Int = 15, autoConfirm: Bool = false) {
        self.maxSteps = maxSteps
        self.autoConfirm = autoConfirm
    }

    /// Number of actions actually performed on the machine (`.done` isn't one).
    public var executedCount: Int { steps.count }

    @discardableResult
    public mutating func handle(_ event: AgentEvent) -> [AgentEffect] {
        // Once the run is over, nothing restarts it — a late model response or a
        // stray keypress after an abort must not resurrect a loop the user killed.
        guard !status.isTerminal else { return [] }

        switch event {
        case let .proposed(action, risk):
            return propose(action, risk: risk)

        case .userConfirmed:
            guard case let .awaitingConfirmation(action, _) = status else { return [] }
            return run(action, confirmed: true)

        case .userEnabledAuto:
            guard case let .awaitingConfirmation(action, _) = status else { return [] }
            autoConfirm = true
            return run(action, confirmed: true)

        case .userAborted:
            status = .stopped("Stopped")
            return [.stop("Stopped")]

        case .actionCompleted:
            guard case .executing = status else { return [] }
            if steps.count >= maxSteps {
                let message = "Stopped after \(maxSteps) steps"
                status = .stopped(message)
                return [.stop(message)]
            }
            status = .thinking
            return [.askModel]

        case let .modelFailed(reason):
            status = .stopped(reason)
            return [.stop(reason)]
        }
    }

    private mutating func propose(_ action: AgentAction, risk: AgentRisk) -> [AgentEffect] {
        if case let .done(summary) = action {
            status = .finished(summary)
            return [.finish(summary)]
        }

        switch risk {
        case let .blocked(reason):
            // Auto mode does NOT reach here — see `.confirm` below. A blocked action
            // ends the run rather than being skipped, because the model asked to do
            // something we won't do and letting it continue blind invites a retry.
            let message = "Stopped: \(reason)"
            status = .stopped(message)
            return [.stop(message)]

        case let .confirm(reason):
            // Auto mode covers confirmations and only confirmations. `.blocked` is
            // matched above and is unreachable from here, which is the intended
            // asymmetry: the user can waive the prompts they're shown, but not the
            // one rail that exists precisely because asking wouldn't be safe.
            if autoConfirm { return run(action, confirmed: true) }
            status = .awaitingConfirmation(action, reason: reason)
            return []

        case .safe:
            return run(action, confirmed: false)
        }
    }

    private mutating func run(_ action: AgentAction, confirmed: Bool) -> [AgentEffect] {
        steps.append(AgentStepRecord(action: action, confirmed: confirmed))
        status = .executing(action)
        return [.execute(action)]
    }
}
