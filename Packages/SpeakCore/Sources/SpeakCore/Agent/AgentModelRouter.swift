import Foundation

/// Owns the `Sonnet → Opus → Fable 5.1` ladder and the one legitimate way to climb it.
///
/// Two rules the spec states and this type is the only place that enforces:
///
/// **A run climbs, a request restarts.** `beginRequest()` drops back to Sonnet even
/// if the previous request finished on Fable. Without that reset, one hard question
/// would silently make every later question — "what's on my screen" — cost Fable
/// prices for the rest of the conversation.
///
/// **Escalation is a tool call, never a phrase.** The model asks by calling
/// `mcp__control__escalate_model` on the app's own MCP server. Pattern-matching prose
/// like "this is hard" was the obvious cheap alternative and it is the wrong one twice
/// over: the model says that sort of thing while narrating a task it is handling fine,
/// and a model that genuinely needs help has no reliable way to say so. A tool call is
/// unambiguous in both directions, and it carries a reason the panel can show.
public struct AgentModelRouter: Equatable, Sendable {

    /// Where the run currently sits on the ladder.
    public private(set) var tier: AgentModelTier

    public init(tier: AgentModelTier = .sonnet) {
        self.tier = tier
    }

    // MARK: - The ladder

    /// The tier immediately above `tier`, or nil at the top.
    public static func nextTier(above tier: AgentModelTier) -> AgentModelTier? {
        guard let i = AgentModelTier.allCases.firstIndex(of: tier),
              i + 1 < AgentModelTier.allCases.count else { return nil }
        return AgentModelTier.allCases[i + 1]
    }

    /// Return to Sonnet for a new user request. The conversation and its session
    /// survive this; only the routing does not.
    @discardableResult
    public mutating func beginRequest() -> AgentModelTier {
        tier = .sonnet
        return tier
    }

    public enum Outcome: Equatable, Sendable {
        case escalated(from: AgentModelTier, to: AgentModelTier, reason: String)
        /// Asked to escalate from the top of the ladder. Not an error — the model
        /// judged the task hard and it was right — but there is nothing above Fable,
        /// so the run continues where it is and the model is told so plainly rather
        /// than left waiting for a handover that will never arrive.
        case atCeiling(AgentModelTier)
    }

    /// Move up one rung. Never more than one: the ladder exists so a task that only
    /// needed Opus doesn't get billed at Fable, and jumping the queue on a single
    /// request throws that away.
    public mutating func escalate(reason: String) -> Outcome {
        let cleaned = Self.normalise(reason)
        guard let next = Self.nextTier(above: tier) else { return .atCeiling(tier) }
        let from = tier
        tier = next
        return .escalated(from: from, to: next, reason: cleaned)
    }

    /// A blank reason is accepted rather than refused. The reason exists so the panel
    /// can say *why* the run got more expensive; refusing the escalation over a
    /// missing string would strand a run that has already decided it is stuck.
    static func normalise(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no reason given" : trimmed
    }

    // MARK: - The tool

    public static let escalateTool = "escalate_model"

    /// What the name looks like on the wire. Claude Code namespaces every MCP tool as
    /// `mcp__<server>__<tool>`, and this exact string has to appear in the positive
    /// `--allowed-tools` list or the model cannot ask at all.
    public static let escalateToolQualifiedName =
        "mcp__\(MCPServerID.control.rawValue)__\(escalateTool)"

    /// The MCP tool descriptor the control server advertises, as JSON.
    ///
    /// Kept here rather than in the server so the name, the schema, the allowlist
    /// entry, and the sentence in the system prompt cannot drift apart — they are all
    /// derived from this file and pinned by its tests.
    public static let toolDescriptorJSON = """
    {
      "name": "\(escalateTool)",
      "description": "Hand this request to a more capable model. Call this when the \
    task is harder, more uncertain, or longer-running than you can handle well. \
    Finish your current thought and stop; the stronger model continues this same \
    conversation with everything you have already done. Do not call it merely because \
    a task is tedious.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "reason": {
            "type": "string",
            "description": "One sentence, shown to the user, saying why a stronger model is needed."
          }
        },
        "required": ["reason"],
        "additionalProperties": false
      }
    }
    """

    /// The reason carried by `call`, if it is an escalation request — nil for every
    /// other tool call. The server check matters: a `macos` server that one day ships
    /// its own `escalate_model` must not be able to move the run up the ladder.
    public static func escalationReason(in call: AgentToolCall) -> String? {
        guard call.server == .control, call.tool == escalateTool else { return nil }
        return normalise(call.arguments["reason"] ?? "")
    }

    /// What the control server returns as the tool result.
    ///
    /// The wording is doing real work in both cases. On success the model has to stop
    /// rather than keep going — it is about to be replaced mid-conversation, and two
    /// models acting on the same screen is worse than either alone. At the ceiling it
    /// has to keep going, because the alternative is a model that politely waits for
    /// help that does not exist.
    public static func acknowledgement(for outcome: Outcome) -> String {
        switch outcome {
        case let .escalated(_, to, _):
            return "Escalation accepted. \(to.displayName) will continue this conversation. "
                + "Stop now: do not call any more tools and do not answer the user."
        case let .atCeiling(tier):
            return "Already on \(tier.displayName), the most capable model available. "
                + "There is nothing to escalate to — continue the request yourself."
        }
    }

    /// The prompt that opens the escalated turn.
    ///
    /// The resumed session already contains every prior tool call *and its result*, so
    /// the new model can see what happened. What it cannot see is which of those were
    /// finished versus abandoned mid-flight, and the failure mode is expensive: the
    /// spec's "escalation must not repeat actions already completed" means, in
    /// practice, not sending a second message or buying a second ticket. Hence both
    /// halves — completed work is done, anything uncertain gets looked at before it
    /// gets redone.
    public static func continuationPrompt(reason: String) -> String {
        """
        You are continuing the same request on a more capable model. \
        The reason given for escalating was: \(normalise(reason))

        Everything above already happened. Any tool call that returned a result is \
        DONE — never repeat it. If a step's outcome is unclear, take a screenshot and \
        inspect the current state before acting rather than redoing it. Then carry on \
        from where the previous model stopped and answer the user.
        """
    }

    /// The paragraph the runtime drops into its system prompt. Lives here so it names
    /// the tool by the same constant the allowlist and the descriptor use.
    public static let escalationGuidance = """
    If a request turns out to be harder, more uncertain, or longer-running than you \
    can handle well, call \(escalateTool) with a one-sentence reason and then stop. \
    A stronger model picks up this same conversation with all of your work intact. \
    Never announce in prose that you need a better model — that does nothing; the \
    tool call is the only thing that moves the request.
    """
}
