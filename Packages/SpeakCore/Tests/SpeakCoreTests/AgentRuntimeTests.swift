import Testing
import Foundation
@testable import SpeakCore

// MARK: - Model routing

@Suite("Agent model routing")
struct AgentModelRouterTests {

    @Test("The ladder climbs one rung at a time and stops at the top")
    func climbsOneRung() {
        var router = AgentModelRouter()
        #expect(router.tier == .sonnet)

        #expect(router.escalate(reason: "lots of steps")
                == .escalated(from: .sonnet, to: .opus, reason: "lots of steps"))
        #expect(router.tier == .opus)

        #expect(router.escalate(reason: "still stuck")
                == .escalated(from: .opus, to: .fable, reason: "still stuck"))
        #expect(router.tier == .fable)

        // Nothing above Fable. The run continues where it is rather than pretending.
        #expect(router.escalate(reason: "help") == .atCeiling(.fable))
        #expect(router.tier == .fable)
    }

    /// The spec's rule, and the one that costs money if it breaks: one hard request
    /// must not leave every later "what's on my screen" running on Fable.
    @Test("A new request restarts at Sonnet however the last one ended")
    func newRequestRestartsAtSonnet() {
        var router = AgentModelRouter()
        router.escalate(reason: "hard")
        router.escalate(reason: "harder")
        #expect(router.tier == .fable)

        #expect(router.beginRequest() == .sonnet)
        #expect(router.tier == .sonnet)
    }

    @Test("nextTier walks the ladder and ends")
    func nextTier() {
        #expect(AgentModelRouter.nextTier(above: .sonnet) == .opus)
        #expect(AgentModelRouter.nextTier(above: .opus) == .fable)
        #expect(AgentModelRouter.nextTier(above: .fable) == nil)
    }

    /// Escalation is a structured signal or it is nothing. A tool with the same name
    /// on another server must not move the run — otherwise any MCP package the user
    /// installs could pick the model.
    @Test("Only the control server's escalate_model counts")
    func onlyControlServerEscalates() {
        let real = AgentToolCall(id: "t1", server: .control, tool: "escalate_model",
                                 arguments: ["reason": "the page keeps changing"])
        #expect(AgentModelRouter.escalationReason(in: real) == "the page keeps changing")

        let impostor = AgentToolCall(id: "t2", server: .macos, tool: "escalate_model",
                                     arguments: ["reason": "let me have Fable"])
        #expect(AgentModelRouter.escalationReason(in: impostor) == nil)

        let unrelated = AgentToolCall(id: "t3", server: .control, tool: "screenshot")
        #expect(AgentModelRouter.escalationReason(in: unrelated) == nil)
    }

    /// A missing reason is a worse prompt, not a reason to strand a run that has
    /// already decided it is stuck.
    @Test("A blank reason still escalates")
    func blankReasonStillEscalates() {
        let call = AgentToolCall(id: "t1", server: .control, tool: "escalate_model",
                                 arguments: ["reason": "   "])
        #expect(AgentModelRouter.escalationReason(in: call) == "no reason given")

        var router = AgentModelRouter()
        #expect(router.escalate(reason: "") == .escalated(from: .sonnet, to: .opus, reason: "no reason given"))
    }

    @Test("The tool descriptor is valid MCP JSON requiring a reason")
    func descriptorIsValidJSON() throws {
        let data = try #require(AgentModelRouter.toolDescriptorJSON.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["name"] as? String == AgentModelRouter.escalateTool)
        let schema = try #require(json["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect((schema["required"] as? [String]) == ["reason"])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["reason"] != nil)
    }

    /// The qualified name is what has to appear in `--allowed-tools`. If this drifts
    /// from what Claude Code namespaces the tool as, the model simply cannot ask.
    @Test("The qualified name matches Claude Code's mcp__server__tool shape")
    func qualifiedName() {
        #expect(AgentModelRouter.escalateToolQualifiedName == "mcp__control__escalate_model")
        #expect(ClaudeCodeStreamParser.mcpName(AgentModelRouter.escalateToolQualifiedName)?.0 == .control)
        #expect(ClaudeCodeStreamParser.mcpName(AgentModelRouter.escalateToolQualifiedName)?.1
                == AgentModelRouter.escalateTool)
    }

    /// Both acknowledgements have a job: stop, so two models don't act on one screen;
    /// or carry on, so the model doesn't wait for a handover that can't happen.
    @Test("The acknowledgement tells the model what to do next")
    func acknowledgementDirectsTheModel() {
        let up = AgentModelRouter.acknowledgement(for: .escalated(from: .sonnet, to: .opus, reason: "x"))
        #expect(up.contains("Opus"))
        #expect(up.lowercased().contains("stop"))

        let top = AgentModelRouter.acknowledgement(for: .atCeiling(.fable))
        #expect(top.contains("Fable 5.1"))
        #expect(top.lowercased().contains("continue"))
    }

    /// "Escalation must not repeat actions already completed" is enforced by resuming
    /// the session, but the new model still has to be told which parts are settled.
    @Test("The continuation prompt forbids repeating completed work")
    func continuationPromptForbidsRepeats() {
        let prompt = AgentModelRouter.continuationPrompt(reason: "the checkout page stalled")
        #expect(prompt.contains("the checkout page stalled"))
        #expect(prompt.contains("never repeat"))
        #expect(prompt.lowercased().contains("screenshot"))
    }

    @Test("The system-prompt guidance names the tool, not a phrase to say")
    func guidanceNamesTheTool() {
        #expect(AgentModelRouter.escalationGuidance.contains(AgentModelRouter.escalateTool))
    }
}

// MARK: - Stream parsing

@Suite("Claude Code stream parsing")
struct ClaudeCodeStreamParserTests {

    private func steps(_ events: [AgentEvent]) -> [AgentStep] {
        events.compactMap { if case let .step(step) = $0 { return step } else { return nil } }
    }

    private let initLine = #"{"type":"system","subtype":"init","session_id":"sess-1","model":"claude-sonnet-4-6","tools":[]}"#

    private func toolUse(id: String = "toolu_1",
                         name: String = "mcp__macos__click_element",
                         input: String = #"{"app":"Safari","element":"Sign in"}"#) -> String {
        #"{"type":"assistant","session_id":"sess-1","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func toolResult(id: String = "toolu_1",
                            content: String = #""clicked""#,
                            isError: Bool = false) -> String {
        #"{"type":"user","session_id":"sess-1","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(isError),"content":\#(content)}]}}"#
    }

    @Test("The session id is captured, and the newest one wins")
    func capturesSessionID() {
        var parser = ClaudeCodeStreamParser()
        #expect(parser.sessionID == nil)
        _ = parser.parse(line: initLine)
        #expect(parser.sessionID == "sess-1")

        // A resumed print-mode turn can be handed a fresh id; resuming the stale one
        // would silently continue an older branch of the conversation.
        _ = parser.parse(line: #"{"type":"system","subtype":"init","session_id":"sess-2"}"#)
        #expect(parser.sessionID == "sess-2")
    }

    @Test("Only text_delta reaches the panel")
    func onlyTextDeltaIsTheAnswer() {
        var parser = ClaudeCodeStreamParser()

        let text = #"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Opening Safari"}}}"#
        #expect(parser.parse(line: text) == [.responseDelta("Opening Safari")])

        // The tool call's arguments being assembled a character at a time. In the
        // panel this is a scratchpad, not an answer.
        let toolArguments = #"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"app\":\"Saf"}}}"#
        #expect(parser.parse(line: toolArguments).isEmpty)

        let thinking = #"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"maybe I should"}}}"#
        #expect(parser.parse(line: thinking).isEmpty)

        // Announced before its arguments exist — a step drawn from this shows a click
        // with no target that then changes under the user.
        let blockStart = #"{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_9","name":"mcp__macos__click_element"}}}"#
        #expect(parser.parse(line: blockStart).isEmpty)
    }

    /// The whole-message `assistant` line repeats text that already arrived as deltas.
    @Test("Assistant text blocks are not re-emitted")
    func assistantTextIsNotDoubled() {
        var parser = ClaudeCodeStreamParser()
        let line = #"{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"Opening Safari"}]}}"#
        #expect(parser.parse(line: line).isEmpty)
    }

    @Test("A tool_use becomes a running step on its MCP server")
    func toolUseBecomesStep() throws {
        var parser = ClaudeCodeStreamParser()
        let events = parser.parse(line: toolUse())
        #expect(events.first == .phase(.acting))

        let step = try #require(steps(events).first)
        #expect(step.id == "toolu_1")
        #expect(step.status == .running)
        let call = try #require(step.call)
        #expect(call.server == .macos)
        #expect(call.tool == "click_element")
        #expect(call.target == "Safari")
        #expect(call.arguments["element"] == "Sign in")
    }

    @Test("A tool_result completes the step it names")
    func toolResultCompletesStep() throws {
        var parser = ClaudeCodeStreamParser()
        _ = parser.parse(line: toolUse())
        let step = try #require(steps(parser.parse(line: toolResult())).first)
        #expect(step.id == "toolu_1")
        #expect(step.status == .completed)
        #expect(step.result == "clicked")
        // Still the same call, so the panel replaces the row rather than adding one.
        #expect(step.call?.tool == "click_element")
    }

    @Test("An errored tool_result fails the step")
    func erroredToolResultFails() throws {
        var parser = ClaudeCodeStreamParser()
        _ = parser.parse(line: toolUse())
        let step = try #require(steps(parser.parse(line: toolResult(content: #""no such element""#,
                                                                   isError: true))).first)
        #expect(step.status == .failed)
    }

    /// Inventing a step for a call we never saw announced would put a row in the
    /// transcript with no arguments and no server.
    @Test("A result for an unknown call is dropped")
    func unknownToolResultDropped() {
        var parser = ClaudeCodeStreamParser()
        #expect(parser.parse(line: toolResult(id: "toolu_never")).isEmpty)
    }

    /// Post-action screenshots come back as MCP image content. Hundreds of kilobytes
    /// of base64 in a step's `result` would reach the panel, the logs, and memory for
    /// the life of the conversation.
    @Test("Image results are named, never inlined")
    func imageResultsAreNotInlined() throws {
        var parser = ClaudeCodeStreamParser()
        _ = parser.parse(line: toolUse())
        let content = #"[{"type":"text","text":"clicked"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUg"}}]"#
        let step = try #require(steps(parser.parse(line: toolResult(content: content))).first)
        let result = try #require(step.result)
        #expect(result.contains("clicked"))
        #expect(result.contains("[screenshot]"))
        #expect(!result.contains("iVBORw0KGgo"))
    }

    /// A whole accessibility tree can arrive as one argument, and the panel is a
    /// floating strip.
    @Test("Long arguments are clamped")
    func longArgumentsClamped() throws {
        var parser = ClaudeCodeStreamParser()
        let long = String(repeating: "a", count: 5_000)
        let step = try #require(steps(parser.parse(line: toolUse(input: #"{"tree":"\#(long)"}"#))).first)
        let value = try #require(step.call?.arguments["tree"])
        #expect(value.count < 300)
        #expect(value.hasSuffix("…"))
    }

    @Test("Non-string arguments survive as text, and 1 is not true")
    func nonStringArguments() throws {
        var parser = ClaudeCodeStreamParser()
        let step = try #require(steps(parser.parse(
            line: toolUse(input: #"{"x":1,"quiet":true,"path":[1,2]}"#))).first)
        let arguments = try #require(step.call?.arguments)
        #expect(arguments["x"] == "1")
        #expect(arguments["quiet"] == "true")
        #expect(arguments["path"] == "[1,2]")
    }

    /// The positive allowlist should make this unreachable. If it ever fires, a
    /// built-in got past the boundary — the one thing Agent Mode promises can't
    /// happen — so it has to be visible rather than dropped.
    @Test("A tool outside the allowlist surfaces as a refused step")
    func unlistedToolIsVisible() throws {
        var parser = ClaudeCodeStreamParser()
        let builtIn = try #require(steps(parser.parse(line: toolUse(name: "Bash"))).first)
        #expect(builtIn.status == .denied)
        #expect(builtIn.call == nil)
        #expect(builtIn.note?.contains("Bash") == true)

        var other = ClaudeCodeStreamParser()
        let unknownServer = try #require(steps(other.parse(line: toolUse(name: "mcp__filesystem__read"))).first)
        #expect(unknownServer.status == .denied)
    }

    @Test("The result line ends the turn, and a failed turn is not an answer")
    func resultLineEndsTheTurn() {
        var parser = ClaudeCodeStreamParser()
        let ok = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"Safari is open."}"#
        #expect(parser.parse(line: ok) == [.responseFinished("Safari is open.")])

        // The CLI exits 0 on a failed turn and reports it in the body.
        let bad = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s","result":"usage limit reached"}"#
        #expect(parser.parse(line: bad) == [.failed("usage limit reached")])
    }

    /// A parser that throws on one odd line turns a cosmetic CLI change into an
    /// outage. Dropping the line is strictly better than dying on it.
    @Test("Unparseable lines are skipped, and the stream keeps working")
    func unparseableLinesAreSkipped() {
        var parser = ClaudeCodeStreamParser()
        for line in ["", "   ", "not json at all", "{", #"{"type":"unknown_future_shape"}"#,
                     #"{"type":"assistant","message":{}}"#] {
            #expect(parser.parse(line: line).isEmpty)
        }
        _ = parser.parse(line: initLine)
        #expect(parser.sessionID == "sess-1")
    }

    /// End to end: the events a real turn produces, folded by the type the panel
    /// actually draws.
    @Test("A whole turn folds into the transcript the panel draws")
    func wholeTurnFolds() {
        var parser = ClaudeCodeStreamParser()
        var transcript = AgentTranscript()
        transcript.apply(.requestStarted("open safari"))

        let stream = [
            initLine,
            #"{"type":"stream_event","session_id":"sess-1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Opening Safari"}}}"#,
            toolUse(),
            toolResult(),
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"sess-1","result":"Safari is open."}"#,
        ]
        for event in parser.parse(lines: stream) { transcript.apply(event) }

        #expect(transcript.steps.count == 1)
        #expect(transcript.steps[0].status == .completed)
        #expect(transcript.phase == .finished)
        // The deltas fill the panel live; the result line replaces them, so what gets
        // spoken is the final answer rather than the running narration.
        #expect(transcript.response == "Safari is open.")
    }

    /// The escalation path as the runtime sees it: a normal-looking tool call that the
    /// router recognises structurally.
    @Test("An escalation arrives as an ordinary control-server tool call")
    func escalationArrivesAsAToolCall() throws {
        var parser = ClaudeCodeStreamParser()
        let line = toolUse(id: "toolu_esc",
                           name: AgentModelRouter.escalateToolQualifiedName,
                           input: #"{"reason":"the site keeps re-rendering"}"#)
        let call = try #require(steps(parser.parse(line: line)).first?.call)
        #expect(call.server == .control)
        #expect(AgentModelRouter.escalationReason(in: call) == "the site keeps re-rendering")
    }
}
