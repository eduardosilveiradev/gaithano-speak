import Foundation

/// How one `claude -p` run ended, as reported on its own terminal `result` line.
/// The CLI exits 0 even when the turn failed, so this — not the exit status — is
/// what says whether there is an answer.
public enum ClaudeCodeOutcome: Equatable, Sendable {
    case answer(String)
    case failed(String)
}

/// Parses server-sent-event lines from streaming chat completions into plain text
/// deltas. Kept here (pure) rather than in the providers so the fiddly shapes —
/// `[DONE]` sentinels, Gemini's thought parts, keep-alive blanks — are unit-tested
/// instead of debugged live against a model server.
public enum StreamChunkParser {
    /// Strip the `data:` prefix from an SSE line. Returns nil for blank lines,
    /// comments, and the terminal `[DONE]` sentinel.
    static func payload(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }
        let body = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body != "[DONE]" else { return nil }
        return body
    }

    /// Text delta from one OpenAI-compatible SSE line (LM Studio, Ollama, llama.cpp).
    public static func openAIDelta(fromSSELine line: String) -> String? {
        guard let body = payload(fromSSELine: line),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Text delta from one Gemini `streamGenerateContent?alt=sse` line.
    ///
    /// Gemini 3.x interleaves reasoning into the same parts array. Two shapes were
    /// seen live against `gemini-3.5-flash`, and both are dropped here:
    ///   - `"thought": true` on a part carrying reasoning text.
    ///   - a part with `"thoughtSignature"` and `"text": ""`, which arrives on the
    ///     final chunk even with `thinkingBudget: 0`.
    /// Surfacing either would dump the model's scratchpad into the answer panel.
    public static func geminiDelta(fromSSELine line: String) -> String? {
        guard let body = payload(fromSSELine: line),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }

        let text = parts.compactMap { part -> String? in
            if let isThought = part["thought"] as? Bool, isThought { return nil }
            if part["thoughtSignature"] != nil { return nil }
            return part["text"] as? String
        }.joined()

        return text.isEmpty ? nil : text
    }

    /// Text delta from one line of `claude -p --output-format stream-json
    /// --include-partial-messages`, which emits JSON objects one per line rather than
    /// SSE frames.
    ///
    /// Only `text_delta` is surfaced. The same stream also carries `input_json_delta`
    /// (a tool call being assembled — the Read of the screenshot) and `thinking_delta`,
    /// and either one in the answer panel would be the model's scratchpad rather than
    /// its answer.
    public static func claudeCodeDelta(fromJSONLine line: String) -> String? {
        guard let json = claudeCodeObject(line),
              json["type"] as? String == "stream_event",
              let event = json["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// The final answer from the terminal `result` line, or an error message if the
    /// run failed. The CLI exits 0 on a failed turn and reports it in the body, so
    /// this is the only place a model-side failure shows up.
    public static func claudeCodeResult(fromJSONLine line: String) -> ClaudeCodeOutcome? {
        guard let json = claudeCodeObject(line), json["type"] as? String == "result" else {
            return nil
        }
        let text = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failed = (json["is_error"] as? Bool) ?? false
        if failed || text.isEmpty {
            let reason = text.isEmpty ? (json["subtype"] as? String ?? "the CLI returned no answer") : text
            return .failed(reason)
        }
        return .answer(text)
    }

    private static func claudeCodeObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Extract an error message from a non-streaming JSON error body, for logging
    /// and for the notice shown to the user. Both Vertex and OpenAI-compatible
    /// servers nest the human-readable text under `error.message`.
    public static func errorMessage(fromBody data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // Vertex sometimes returns a top-level ARRAY containing one error object.
        let object: [String: Any]?
        if let dict = json as? [String: Any] {
            object = dict
        } else if let array = json as? [[String: Any]] {
            object = array.first
        } else {
            object = nil
        }
        guard let error = object?["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }
}
