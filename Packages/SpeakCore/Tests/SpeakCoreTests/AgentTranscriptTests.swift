import Testing
import Foundation
@testable import SpeakCore

@Suite("Agent transcript")
struct AgentTranscriptTests {

    private func call(_ id: String = "c1", tool: String = "click") -> AgentToolCall {
        AgentToolCall(id: id, server: .macos, tool: tool, target: "Safari")
    }

    @Test("The ladder only ever climbs")
    func escalationIsOneDirectional() {
        var t = AgentTranscript()
        #expect(t.model == .sonnet)

        t.apply(.escalated(to: .opus, reason: "long-running"))
        #expect(t.model == .opus)
        #expect(t.escalationNotice?.contains("Opus") == true)

        // A downgrade mid-run is a bug upstream; honouring it would misreport which
        // model is acting.
        t.apply(.escalated(to: .sonnet, reason: "cheaper"))
        #expect(t.model == .opus)

        t.apply(.escalated(to: .fable, reason: "still stuck"))
        #expect(t.model == .fable)
    }

    @Test("A new request returns to Sonnet and drops allow-all")
    func requestResetsRouting() {
        var t = AgentTranscript()
        t.apply(.escalated(to: .fable, reason: "hard"))
        t.apply(.approvalResolved(id: "a1", decision: .allowAll))
        #expect(t.allowAllForRun)

        t.apply(.requestStarted("open safari"))
        #expect(t.model == .sonnet)
        #expect(!t.allowAllForRun)
        #expect(t.request == "open safari")
        #expect(t.steps.isEmpty)
        #expect(t.escalationNotice == nil)
    }

    /// The spec scopes "allow all" to one request. Every way a run can end has to
    /// clear it, or a follow-up inherits blanket approval for purchases and locks.
    @Test("Allow-all expires however the run ends")
    func allowAllExpiresEveryWay() {
        for ending in [AgentEvent.responseFinished("done"),
                       .failed("mcp disconnected"),
                       .cancelled,
                       .phase(.finished)] {
            var t = AgentTranscript()
            t.apply(.approvalResolved(id: "a1", decision: .allowAll))
            #expect(t.allowAllForRun)
            t.apply(ending)
            #expect(!t.allowAllForRun, "\(ending) left allow-all in force")
        }
    }

    @Test("Steps are upserted by id, not appended twice")
    func stepsUpsert() {
        var t = AgentTranscript()
        let c = call()
        t.apply(.step(AgentStep(id: "s1", call: c, status: .planned)))
        t.apply(.step(AgentStep(id: "s1", call: c, status: .running)))
        t.apply(.step(AgentStep(id: "s2", call: call("c2"), status: .planned)))

        #expect(t.steps.count == 2)
        #expect(t.steps[0].status == .running)
        #expect(t.steps[1].id == "s2")
    }

    /// A step that was mid-flight when the run died may have half-happened. Marking
    /// it `.interrupted` rather than `.failed` is what stops the next run replaying
    /// it blindly — the spec requires inspecting state first.
    @Test("Cancelling marks running steps interrupted and unstarted ones cancelled")
    func cancellationPreservesUncertainty() {
        var t = AgentTranscript()
        t.apply(.step(AgentStep(id: "done", call: call(), status: .completed)))
        t.apply(.step(AgentStep(id: "mid", call: call("c2"), status: .running)))
        t.apply(.step(AgentStep(id: "next", call: call("c3"), status: .planned)))

        t.apply(.cancelled)

        #expect(t.steps[0].status == .completed)   // completed work survives
        #expect(t.steps[1].status == .interrupted)
        #expect(t.steps[2].status == .cancelled)
        #expect(t.phase == .cancelled)
    }

    @Test("A failure interrupts in the same way")
    func failureAlsoInterrupts() {
        var t = AgentTranscript()
        t.apply(.step(AgentStep(id: "mid", call: call(), status: .running)))
        t.apply(.failed("Chrome disconnected"))
        #expect(t.steps[0].status == .interrupted)
        #expect(t.phase == .failed("Chrome disconnected"))
    }

    @Test("An approval request parks the run and resolving it clears the prompt")
    func approvalLifecycle() {
        var t = AgentTranscript()
        let request = AgentApprovalRequest(id: "a1",
                                           call: call("c1", tool: "type"),
                                           category: .typing,
                                           reason: "Type into the address bar")
        t.apply(.approvalRequested(request))
        #expect(t.phase == .awaitingApproval)
        #expect(t.pendingApproval == request)

        t.apply(.approvalResolved(id: "a1", decision: .deny))
        #expect(t.pendingApproval == nil)
        #expect(t.decisions["a1"] == .deny)
        #expect(!t.allowAllForRun)
    }

    @Test("Response deltas accumulate, then the final text replaces them")
    func responseStreaming() {
        var t = AgentTranscript()
        t.apply(.responseDelta("Opened "))
        t.apply(.responseDelta("Safari."))
        #expect(t.response == "Opened Safari.")
        #expect(t.phase == .responding)

        t.apply(.responseFinished("Opened Safari."))
        #expect(t.response == "Opened Safari.")
        #expect(t.phase == .finished)
    }

    @Test("Only a live phase counts as active")
    func phaseActivity() {
        #expect(AgentPhase.acting.isActive)
        #expect(AgentPhase.awaitingApproval.isActive)
        #expect(!AgentPhase.finished.isActive)
        #expect(!AgentPhase.failed("x").isActive)
        #expect(!AgentPhase.cancelled.isActive)
        #expect(!AgentPhase.idle.isActive)
    }
}

@Suite("Agent conversation")
struct AgentConversationTests {

    @Test("Expiry is measured from the last activity, not the first")
    func expiryFollowsActivity() {
        let start = Date()
        var c = AgentConversation(sessionID: "abc", lastActivityAt: start)

        #expect(!c.isExpired(at: start.addingTimeInterval(14 * 60)))
        #expect(c.isExpired(at: start.addingTimeInterval(15 * 60)))

        // A follow-up fourteen minutes in buys another fifteen.
        c.touch(at: start.addingTimeInterval(14 * 60))
        #expect(!c.isExpired(at: start.addingTimeInterval(28 * 60)))
        #expect(c.isExpired(at: start.addingTimeInterval(29 * 60)))
    }
}

@Suite("Agent model tiers")
struct AgentModelTierTests {

    @Test("The ladder is ordered Sonnet → Opus → Fable")
    func ladderOrder() {
        #expect(AgentModelTier.sonnet < .opus)
        #expect(AgentModelTier.opus < .fable)
        #expect(AgentModelTier.allCases == [.sonnet, .opus, .fable])
    }

    @Test("Each tier names a model the CLI accepts")
    func modelIDs() {
        #expect(AgentModelTier.sonnet.claudeModelID == "sonnet")
        #expect(AgentModelTier.opus.claudeModelID == "opus")
        #expect(AgentModelTier.fable.claudeModelID == "claude-fable-5-1")
    }
}
