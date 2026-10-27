import Foundation

// The vocabulary Agent Mode's four halves share: the runtime that drives a Claude
// Code session, the proxy that gates its tool calls, the panel that renders what is
// happening, and the screenshot service that proves it happened. Everything here is
// a pure value type so the reducer below can be tested without any of them.
//
// See `AGENT_MODE_SPEC.md` for the behaviour these types exist to describe.

// MARK: - Models

/// The routing ladder. A run climbs it and never descends: `Sonnet → Opus → Fable`.
///
/// Ordered so "never downgrade while active" is a comparison rather than a
/// convention someone has to remember.
public enum AgentModelTier: String, Codable, Sendable, CaseIterable, Comparable {
    case sonnet
    case opus
    case fable

    public static func < (a: AgentModelTier, b: AgentModelTier) -> Bool {
        guard let ai = allCases.firstIndex(of: a), let bi = allCases.firstIndex(of: b) else {
            return false
        }
        return ai < bi
    }

    /// What to pass to `claude --model`.
    public var claudeModelID: String {
        switch self {
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .fable: return "claude-fable-5-1"
        }
    }

    public var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .fable: return "Fable 5.1"
        }
    }
}

// MARK: - Tool calls

/// Which bounded MCP server a call is addressed to. `control` is the app's own
/// server — model escalation and anything else that has to be a structured tool
/// rather than prose the runtime has to guess at.
public enum MCPServerID: String, Codable, Sendable, CaseIterable {
    case macos
    case chrome
    case smartthings
    case control

    public var displayName: String {
        switch self {
        case .macos: return "macOS"
        case .chrome: return "Chrome"
        case .smartthings: return "SmartThings"
        case .control: return "Gaithano Speak"
        }
    }
}

/// One proposed or executed tool call, in the form the panel shows and the approval
/// gate judges.
///
/// `arguments` is display-safe by construction: the proxy redacts anything a server
/// marks sensitive before building this, so nothing downstream has to remember to.
public struct AgentToolCall: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var server: MCPServerID
    /// The MCP tool name as the server exposes it, e.g. `browser_navigate`.
    public var tool: String
    /// What the call acts on, in the user's words: "Safari", "Living Room Lamp".
    public var target: String?
    public var arguments: [String: String]

    public init(id: String,
                server: MCPServerID,
                tool: String,
                target: String? = nil,
                arguments: [String: String] = [:]) {
        self.id = id
        self.server = server
        self.tool = tool
        self.target = target
        self.arguments = arguments
    }
}

// MARK: - Approval

/// Why a call needs a human. Carried rather than recomputed so the panel shows the
/// same reason the gate acted on.
public enum ApprovalCategory: String, Codable, Sendable, CaseIterable {
    case typing
    case closingOrQuitting
    case systemSettings
    case deletion
    case purchase
    case security
    /// Classification wasn't confident. The spec makes this require approval, so
    /// an unrecognised tool fails safe instead of running.
    case unknown

    public var summary: String {
        switch self {
        case .typing: return "Type or submit text"
        case .closingOrQuitting: return "Close a window or quit an app"
        case .systemSettings: return "Change a system setting"
        case .deletion: return "Delete data"
        case .purchase: return "Make a purchase"
        case .security: return "Control a security device"
        case .unknown: return "Unrecognised action"
        }
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allow
    case deny
    /// Every remaining category, for this request only. Expires when the request
    /// finishes, fails, or is cancelled — never carries into a follow-up.
    case allowAll
}

public struct AgentApprovalRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var call: AgentToolCall
    public var category: ApprovalCategory
    /// The sentence shown above the buttons.
    public var reason: String

    public init(id: String, call: AgentToolCall, category: ApprovalCategory, reason: String) {
        self.id = id
        self.call = call
        self.category = category
        self.reason = reason
    }
}

// MARK: - Screenshots

/// A capture the app owns. The URL is deliberately app-private: the spec forbids
/// handing Claude a readable path, so images reach it as MCP image content and this
/// reference exists only so the panel can draw a thumbnail.
public struct AgentScreenshot: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var url: URL

    public init(id: UUID = UUID(), capturedAt: Date, url: URL) {
        self.id = id
        self.capturedAt = capturedAt
        self.url = url
    }
}

// MARK: - Transcript

/// How a step ended up. The panel draws each of these differently — a denied step
/// and a failed one look nothing alike to a user trying to work out what happened.
public enum AgentStepStatus: String, Codable, Sendable {
    case planned
    case awaitingApproval
    case running
    case completed
    case denied
    case failed
    case cancelled
    /// Started, outcome unknown — the run was cancelled or the server dropped
    /// mid-call. Never retried blindly: the model has to look at current state first.
    case interrupted
}

/// One line in the panel: either a tool call or a note the model wrote about what
/// it's doing. Not a reasoning trace — the spec forbids claiming to show one.
public struct AgentStep: Identifiable, Equatable, Sendable {
    public var id: String
    public var call: AgentToolCall?
    public var note: String?
    public var status: AgentStepStatus
    public var result: String?
    public var screenshot: AgentScreenshot?
    public var startedAt: Date

    public init(id: String,
                call: AgentToolCall? = nil,
                note: String? = nil,
                status: AgentStepStatus = .planned,
                result: String? = nil,
                screenshot: AgentScreenshot? = nil,
                startedAt: Date = Date()) {
        self.id = id
        self.call = call
        self.note = note
        self.status = status
        self.result = result
        self.screenshot = screenshot
        self.startedAt = startedAt
    }
}

public enum AgentPhase: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case acting
    case awaitingApproval
    case responding
    case finished
    case failed(String)
    case cancelled

    /// Whether the run is still live. Drives the panel's spinner and, more
    /// importantly, whether "allow all" is still in force.
    public var isActive: Bool {
        switch self {
        case .listening, .thinking, .acting, .awaitingApproval, .responding: return true
        case .idle, .finished, .failed, .cancelled: return false
        }
    }
}

/// Everything the panel draws, and the only thing it needs. Produced by folding
/// `AgentEvent`s — see `apply(_:)`.
public struct AgentTranscript: Equatable, Sendable {
    public var phase: AgentPhase
    public var model: AgentModelTier
    /// Live transcription while the user is still speaking.
    public var partialTranscript: String
    /// The request being worked on, once it has been transcribed.
    public var request: String
    public var steps: [AgentStep]
    public var pendingApproval: AgentApprovalRequest?
    /// Decisions already made this run, newest last — so the panel can show what
    /// the user chose next to the step it applied to.
    public var decisions: [String: ApprovalDecision]
    /// The user-facing answer. The only text that is ever spoken aloud.
    public var response: String
    /// Set when the run escalated, so the panel can say so and name the model.
    public var escalationNotice: String?
    /// True once "Allow all for this run" has been pressed. Cleared when the run
    /// ends — this flag is the whole of that promise, so nothing else may set it.
    public var allowAllForRun: Bool

    public init(phase: AgentPhase = .idle,
                model: AgentModelTier = .sonnet,
                partialTranscript: String = "",
                request: String = "",
                steps: [AgentStep] = [],
                pendingApproval: AgentApprovalRequest? = nil,
                decisions: [String: ApprovalDecision] = [:],
                response: String = "",
                escalationNotice: String? = nil,
                allowAllForRun: Bool = false) {
        self.phase = phase
        self.model = model
        self.partialTranscript = partialTranscript
        self.request = request
        self.steps = steps
        self.pendingApproval = pendingApproval
        self.decisions = decisions
        self.response = response
        self.escalationNotice = escalationNotice
        self.allowAllForRun = allowAllForRun
    }
}

// MARK: - Events

/// What the runtime reports. One-directional: the runtime emits these, the
/// transcript folds them, the panel renders the transcript. Nothing renders an
/// event directly, so there is exactly one definition of what the user is looking at.
public enum AgentEvent: Equatable, Sendable {
    /// A new request is starting. Resets everything that is per-request, including
    /// "allow all", and returns the ladder to Sonnet.
    case requestStarted(String)
    case partialTranscript(String)
    case phase(AgentPhase)
    case escalated(to: AgentModelTier, reason: String)
    /// Insert the step, or replace the one with the same id. The runtime sends the
    /// same step repeatedly as it moves `planned → running → completed`.
    case step(AgentStep)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(id: String, decision: ApprovalDecision)
    case responseDelta(String)
    case responseFinished(String)
    case failed(String)
    case cancelled
}

extension AgentTranscript {

    /// Fold one event in. Pure, total, and the single place transcript state changes.
    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case let .requestStarted(text):
            // Deliberately a full reset of the *request*, not the conversation: the
            // Claude Code session and its history live in the runtime and survive
            // this. What must not survive is `allowAll`, which the spec scopes to a
            // single request and no further.
            phase = .thinking
            model = .sonnet
            partialTranscript = ""
            request = text
            steps = []
            pendingApproval = nil
            decisions = [:]
            response = ""
            escalationNotice = nil
            allowAllForRun = false

        case let .partialTranscript(text):
            partialTranscript = text

        case let .phase(next):
            phase = next
            // A run that has stopped can no longer be spending an "allow all".
            if !next.isActive { allowAllForRun = false }

        case let .escalated(tier, reason):
            // Upward only. A downgrade mid-run is a bug upstream, and honouring it
            // would misreport which model is acting.
            guard tier > model else { return }
            model = tier
            escalationNotice = "Escalated to \(tier.displayName) — \(reason)"

        case let .step(step):
            if let i = steps.firstIndex(where: { $0.id == step.id }) {
                steps[i] = step
            } else {
                steps.append(step)
            }

        case let .approvalRequested(request):
            pendingApproval = request
            phase = .awaitingApproval

        case let .approvalResolved(id, decision):
            decisions[id] = decision
            if decision == .allowAll { allowAllForRun = true }
            if pendingApproval?.id == id { pendingApproval = nil }

        case let .responseDelta(delta):
            response += delta
            phase = .responding

        case let .responseFinished(full):
            response = full
            phase = .finished
            allowAllForRun = false
            pendingApproval = nil

        case let .failed(reason):
            phase = .failed(reason)
            allowAllForRun = false
            pendingApproval = nil
            markUnfinishedInterrupted()

        case .cancelled:
            phase = .cancelled
            allowAllForRun = false
            pendingApproval = nil
            markUnfinishedInterrupted()
        }
    }

    /// A step that was running when the run died has an unknown outcome — it may
    /// have half-happened. Recording that as `.interrupted` rather than `.failed` is
    /// what stops a later run from replaying it blindly.
    private mutating func markUnfinishedInterrupted() {
        for i in steps.indices {
            switch steps[i].status {
            case .running: steps[i].status = .interrupted
            case .planned, .awaitingApproval: steps[i].status = .cancelled
            default: break
            }
        }
    }
}

// MARK: - Conversation lifecycle

/// One Claude Code session and its expiry clock.
///
/// Expiry is measured from the last user request or agent activity, never from when
/// the session started: a conversation the user is still using must not die
/// mid-answer because fifteen minutes have passed since the first question.
public struct AgentConversation: Equatable, Sendable {
    /// The spec's window. Also how long screenshots and tool logs may live.
    public static let idleTimeout: TimeInterval = 15 * 60

    /// The Claude Code session id to resume, or nil before the first turn.
    public var sessionID: String?
    public var lastActivityAt: Date

    public init(sessionID: String? = nil, lastActivityAt: Date) {
        self.sessionID = sessionID
        self.lastActivityAt = lastActivityAt
    }

    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(lastActivityAt) >= Self.idleTimeout
    }

    public mutating func touch(at now: Date) {
        lastActivityAt = now
    }
}
