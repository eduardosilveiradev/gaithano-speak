import Foundation

/// Turns `claude --output-format stream-json --include-partial-messages --verbose`
/// into `AgentEvent`s.
///
/// `StreamChunkParser.claudeCodeDelta` already established which chunks of this stream
/// are traps, and they are traps here too: `input_json_delta` is a tool call's
/// arguments being assembled a character at a time, and the whole-message `assistant`
/// line repeats text that already arrived as deltas. Surfacing the first puts a
/// scratchpad in the panel; surfacing the second prints the answer twice. Talk could
/// stop there because it only ever wanted prose. Agent Mode needs the rest of the
/// stream — the tool calls, their results, and the session id — which is why this
/// exists alongside that parser rather than inside it.
///
/// Stateful by necessity: a `tool_result` names a `tool_use_id` and nothing else, so
/// the call it belongs to has to be remembered from the `assistant` line that
/// announced it. That is also why this is a `struct` the caller owns rather than a
/// bag of static functions — the state is per-session, and a leftover mapping from a
/// previous conversation would attach a result to the wrong step.
///
/// **A line that will not parse is dropped, never thrown.** The CLI interleaves its
/// own diagnostics and gains message shapes between versions; a parser that fails the
/// run on one unrecognised line turns a cosmetic upgrade into an outage.
public struct ClaudeCodeStreamParser: Sendable {

    /// The session to `--resume`. Nil until the `system`/`init` line arrives.
    ///
    /// Last seen wins. A resumed print-mode turn is not guaranteed to keep the id it
    /// was resumed from, and resuming a stale id would silently continue an older
    /// branch of the conversation — the user's last three requests would vanish
    /// without anything looking broken.
    public private(set) var sessionID: String?

    /// Calls announced but not yet resolved, keyed by `tool_use_id`.
    private var pending: [String: AgentStep] = [:]

    public init() {}

    /// Parse one NDJSON line. Returns the events it implies, in order — usually zero
    /// or one, several when an assistant message carries more than one tool call.
    public mutating func parse(line: String) -> [AgentEvent] {
        guard let json = Self.object(line) else { return [] }

        // Every line carries it; the init line is just the earliest.
        if let id = json["session_id"] as? String, !id.isEmpty { sessionID = id }

        switch json["type"] as? String {
        case "stream_event":
            // Delegated so there is exactly one definition of "which delta is the
            // answer" across Talk and Agent Mode.
            if let delta = StreamChunkParser.claudeCodeDelta(fromJSONLine: line) {
                return [.responseDelta(delta)]
            }
            // `content_block_start` announces a tool_use before any of its arguments
            // exist. Drawing a step from it would show the user a click with no
            // target that then changes under them; the assistant line below is where
            // a complete call first appears.
            return []

        case "assistant":
            return assistantEvents(json)

        case "user":
            return toolResultEvents(json)

        case "result":
            switch StreamChunkParser.claudeCodeResult(fromJSONLine: line) {
            case let .answer(text): return [.responseFinished(text)]
            case let .failed(reason): return [.failed(reason)]
            case nil: return []
            }

        default:
            return []
        }
    }

    /// Convenience for tests and for replaying a buffered chunk of stream.
    public mutating func parse(lines: [String]) -> [AgentEvent] {
        lines.flatMap { parse(line: $0) }
    }

    // MARK: - Tool calls

    private mutating func assistantEvents(_ json: [String: Any]) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var events: [AgentEvent] = []
        for block in content where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String,
                  let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            let step = Self.step(id: id, toolName: name, input: input)
            pending[id] = step
            if events.isEmpty { events.append(.phase(.acting)) }
            events.append(.step(step))
        }
        // Text blocks are deliberately skipped: they are the same words that already
        // arrived as `text_delta`, and emitting both writes the answer twice.
        return events
    }

    private mutating func toolResultEvents(_ json: [String: Any]) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var events: [AgentEvent] = []
        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            // A result for a call we never saw announced — a stream we joined late, or
            // a shape this version emits differently. Nothing useful to draw, and
            // inventing a step would put a call in the transcript with no arguments.
            guard var step = pending.removeValue(forKey: id) else { continue }
            let failed = (block["is_error"] as? Bool) ?? false
            step.status = failed ? .failed : .completed
            step.result = Self.resultText(block["content"])
            events.append(.step(step))
        }
        return events
    }

    private static func step(id: String, toolName: String, input: [String: Any]) -> AgentStep {
        let arguments = displayArguments(input)
        guard let (server, tool) = mcpName(toolName) else {
            // The positive `--allowed-tools` list should make this unreachable. If it
            // ever fires, a built-in tool got past the boundary — the one thing Agent
            // Mode promises cannot happen — so it is surfaced as a refused step rather
            // than dropped, because a silent leak is the version nobody notices.
            return AgentStep(id: id,
                             note: "Refused a tool outside Agent Mode's allowlist: \(toolName)",
                             status: .denied)
        }
        return AgentStep(id: id,
                         call: AgentToolCall(id: id,
                                             server: server,
                                             tool: tool,
                                             target: target(from: input),
                                             arguments: arguments),
                         status: .running)
    }

    /// Split `mcp__<server>__<tool>`. Returns nil for a built-in name, and for an MCP
    /// server we did not configure.
    static func mcpName(_ name: String) -> (MCPServerID, String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        guard let server = MCPServerID(rawValue: String(rest[rest.startIndex..<separator.lowerBound])) else {
            return nil
        }
        let tool = String(rest[separator.upperBound...])
        return tool.isEmpty ? nil : (server, tool)
    }

    // MARK: - Making arguments and results fit in a panel

    /// The first argument that reads like what the call acts on. Order matters: MCP
    /// servers disagree about which key is the subject, and `text` is last because a
    /// typing call's subject is the field, not the sentence being typed.
    private static let targetKeys = [
        "target", "app", "application", "name", "label", "device",
        "deviceId", "device_id", "url", "element", "selector", "title", "query", "text",
    ]

    static func target(from input: [String: Any]) -> String? {
        for key in targetKeys {
            guard let value = input[key], let string = scalar(value), !string.isEmpty else { continue }
            return String(string.prefix(80))
        }
        return nil
    }

    /// Flatten to strings the panel can draw, clamped.
    ///
    /// The clamp is not cosmetic: an argument can carry a base64 image or a whole
    /// accessibility tree, and the panel is a floating strip. Redaction is not done
    /// here — the approval proxy marks sensitive values before this ever runs, because
    /// only the server knows which of its own arguments are secrets.
    static func displayArguments(_ input: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in input {
            let text = scalar(value) ?? json(value)
            out[key] = clamp(text, to: 200)
        }
        return out
    }

    /// Text from a `tool_result` body.
    ///
    /// Image blocks are named, never included. Post-action screenshots come back as
    /// MCP image content — hundreds of kilobytes of base64 — and putting that in a
    /// step's `result` would push it into the panel, into any log line that prints a
    /// step, and into memory for the life of the conversation.
    static func resultText(_ content: Any?) -> String? {
        guard let content else { return nil }
        if let text = content as? String {
            return clamp(text, to: 500)
        }
        guard let blocks = content as? [[String: Any]] else { return clamp(json(content), to: 500) }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[screenshot]"
            default: return nil
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : clamp(joined, to: 500)
    }

    private static func scalar(_ value: Any) -> String? {
        if let string = value as? String { return string }
        // `as? Bool` is not safe here: JSONSerialization hands back NSNumber for both
        // `true` and `1`, and bridging either to Bool succeeds — so an integer
        // argument would render as "true". The CoreFoundation type is the only thing
        // that tells them apart.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        // Unwrap the array the top-level-object requirement forced on us.
        return String(text.dropFirst().dropLast())
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    private static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
