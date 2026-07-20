import Foundation

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
