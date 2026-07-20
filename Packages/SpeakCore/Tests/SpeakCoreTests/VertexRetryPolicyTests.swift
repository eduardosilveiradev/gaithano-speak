import Testing
@testable import SpeakCore

@Suite("Vertex retry policy")
struct VertexRetryPolicyTests {
    /// 429 is what a busy ON_DEMAND pool returns. Treating it as fatal is what cost
    /// a whole agent run before this existed.
    @Test func throttlesAreTransient() {
        #expect(VertexRetryPolicy.isTransient(429))
        #expect(VertexRetryPolicy.isTransient(503))
    }

    /// Narrow on purpose: re-sending a malformed request reproduces the failure, and
    /// a Vertex 500 usually means the request itself broke the model.
    @Test func realFailuresAreNot() {
        for status in [400, 401, 403, 404, 500] {
            #expect(!VertexRetryPolicy.isTransient(status), "\(status) should not retry")
        }
    }

    @Test func backsOffExponentially() {
        let policy = VertexRetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(afterAttempt: 1) == 1)
        #expect(policy.delay(afterAttempt: 2) == 2)
        #expect(policy.delay(afterAttempt: 3) == 4)
    }

    /// The whole point of a bounded policy: it has to actually stop.
    @Test func stopsAfterMaxAttempts() {
        let policy = VertexRetryPolicy(maxAttempts: 3)
        #expect(policy.delay(afterAttempt: 3) == nil)
        #expect(policy.delay(afterAttempt: 9) == nil)
    }

    @Test func clampsToMaxDelay() {
        let policy = VertexRetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 5)
        #expect(policy.delay(afterAttempt: 6) == 5)
    }

    /// Vertex knows its own pool; guessing shorter just burns another rejected call.
    @Test func serverHintWins() {
        let policy = VertexRetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 30)
        #expect(policy.delay(afterAttempt: 1, serverHint: 7) == 7)
    }

    /// An honest hint we can't sit through is no more useful than a wrong one.
    @Test func serverHintIsStillClamped() {
        let policy = VertexRetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(afterAttempt: 1, serverHint: 600) == 8)
    }

    @Test func ignoresUnusableHints() {
        let policy = VertexRetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(afterAttempt: 1, serverHint: 0) == 1)
        #expect(policy.delay(afterAttempt: 1, serverHint: -5) == 1)
    }

    @Test func parsesRetryAfterHeader() {
        #expect(VertexRetryPolicy.retryAfterSeconds("12") == 12)
        #expect(VertexRetryPolicy.retryAfterSeconds(" 3 ") == 3)
    }

    /// The HTTP-date form is legal but Vertex doesn't send it, and parsing it would
    /// drag a clock into a pure type. It degrades to plain backoff.
    @Test func rejectsUnparseableRetryAfter() {
        #expect(VertexRetryPolicy.retryAfterSeconds(nil) == nil)
        #expect(VertexRetryPolicy.retryAfterSeconds("") == nil)
        #expect(VertexRetryPolicy.retryAfterSeconds("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(VertexRetryPolicy.retryAfterSeconds("0") == nil)
    }
}
