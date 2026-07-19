import Foundation
import SpeakCore

/// Formats transcripts through an OpenAI-compatible local server — LM Studio
/// (`:1234`), Ollama (`:11434`), llama.cpp's server, etc. Compared to Apple's
/// on-device Foundation Model this runs on the Metal GPU, so it doesn't contend
/// with Parakeet transcription on the ANE, is typically much faster, and won't
/// censor the user's words. Any failure (server down, bad model, timeout) throws so
/// the coordinator can fall back to deterministic cleanup.
struct LocalServerFormatter {
    struct Config: Sendable {
        var endpoint: String
        var model: String
    }

    /// Local models can be slow to load on the very first request; generous so a
    /// cold model load doesn't spuriously fail, while a warm request is ~sub-second.
    var timeout: TimeInterval = 20

    func format(_ raw: String, hints: FormattingHints, config: Config) async throws -> FormattedResult {
        guard let base = TextRepair.normalizedOpenAIBase(config.endpoint),
              let url = URL(string: base + "/chat/completions") else {
            throw FormattingError.underlying("invalid local server URL")
        }

        var payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": PromptBuilder.instructions],
                ["role": "user", "content": PromptBuilder.prompt(for: raw, hints: hints)],
            ],
            "temperature": 0.2,
            "max_tokens": 512,
            "stream": false,
        ]
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { payload["model"] = model }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let signpost = Log.signposter
        let state = signpost.beginInterval("format")
        defer { signpost.endInterval("format", state) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.format.error("Local server unreachable: \(error.localizedDescription, privacy: .public)")
            throw FormattingError.underlying("local server unreachable")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FormattingError.underlying("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            Log.format.error("Local server HTTP \(http.statusCode): \(String(body), privacy: .public)")
            throw FormattingError.underlying("local server HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw FormattingError.underlying("unparseable local server response")
        }

        // Reasoning models (Qwen3, DeepSeek-R1) prepend a <think> scratchpad — drop it.
        let cleaned = TextRepair.stripReasoningTags(content)
        guard !cleaned.isEmpty else { throw FormattingError.underlying("empty result") }
        return FormattedResult(text: cleaned, formatter: .localServer)
    }
}
