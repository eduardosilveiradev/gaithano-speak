import Foundation

/// When to retry a Vertex call, and how long to wait first.
///
/// Vertex serves this project as `ON_DEMAND` traffic — a shared dynamic pool rather
/// than a reserved per-project allocation. A 429 there does not mean "you are over
/// your limit"; it means the pool was busy for that instant. It is the routine,
/// expected failure of on-demand serving, and the documented response is to back off
/// and retry, not to surface it. Raising a quota does nothing for it.
///
/// That matters most for the agent, which is the one Vertex caller with no fallback:
/// a Talk answer can degrade to the local server and a formatter can degrade to
/// `DeterministicCleanup`, but a half-finished agent run has already clicked things.
/// Losing it to a transient throttle costs the user the whole task.
///
/// Pure and here rather than inline in `AgentModel` so the delay schedule is actually
/// tested — retry code is exactly the kind that looks right and never runs.
public struct VertexRetryPolicy: Sendable, Equatable {
    /// Total attempts including the first. 3 means "try, then retry twice".
    public var maxAttempts: Int
    /// Delay after the first failure; doubles from there.
    public var baseDelay: TimeInterval
    /// Ceiling on any single wait. The agent is interactive — a user watching a step
    /// list will abandon a run long before a minute-long sleep pays off.
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3,
                baseDelay: TimeInterval = 1,
                maxDelay: TimeInterval = 8) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = VertexRetryPolicy()

    /// Whether a status code is worth trying again.
    ///
    /// Deliberately narrow. 429 and 503 are the two the shared pool actually emits
    /// under load; retrying a 400 or a 404 just spends the user's time re-sending a
    /// request that was malformed the first time. 500 is excluded on purpose — from
    /// Vertex it usually means the request itself broke the model, and repeating it
    /// reproduces the break.
    public static func isTransient(_ status: Int) -> Bool {
        status == 429 || status == 503
    }

    /// How long to wait before the next attempt, or `nil` when there are none left.
    ///
    /// - Parameters:
    ///   - attempt: 1-based number of the attempt that just failed.
    ///   - serverHint: `Retry-After`, in seconds, if the response carried one.
    ///
    /// The server's hint wins when it's present and not absurd: Vertex knows the
    /// state of its own pool, and guessing shorter just burns another rejected call.
    /// It's still clamped, because an honest hint we can't sit through is no more
    /// useful than a wrong one.
    public func delay(afterAttempt attempt: Int, serverHint: TimeInterval? = nil) -> TimeInterval? {
        guard attempt >= 1, attempt < maxAttempts else { return nil }
        if let serverHint, serverHint > 0 {
            return min(serverHint, maxDelay)
        }
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        return min(exponential, maxDelay)
    }

    /// Seconds from a `Retry-After` header value.
    ///
    /// Only the delta-seconds form is honoured. The HTTP-date form is legal but Vertex
    /// does not send it, and parsing a date we'd then have to diff against a clock
    /// would drag a clock into a type that is otherwise pure.
    public static func retryAfterSeconds(_ header: String?) -> TimeInterval? {
        guard let trimmed = header?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(trimmed),
              seconds > 0 else { return nil }
        return seconds
    }
}
