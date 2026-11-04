import Foundation
import SpeakCore

/// Formats transcripts through the Anthropic Messages API directly.
///
/// The fast path that `ClaudeCLIFormatter` describes as out of reach without a key:
/// no Node startup, and no 29 Claude Code tool definitions riding along on every
/// request, just our system prompt and the utterance. Same privacy trade as the CLI.
/// Every dictated word goes to Anthropic. The difference is that nothing lands in
/// `~/.claude`.
///
/// The key comes from `ANTHROPIC_API_KEY` in the process environment or in
/// `~/Library/Application Support/GaithanoSpeak/.env`. A launchd-started GUI app
/// never sees a shell's exports, so the file is the route that actually works. It is
/// re-read on every call so adding a key takes effect without a relaunch.
struct AnthropicAPIFormatter {
    /// Same reasoning as the CLI: a timeout silently degrades to grammar-blind cleanup.
    var timeout: TimeInterval = 20

    static let envFile: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GaithanoSpeak/.env")

    /// The key, or nil. Nil means the coordinator stays on the CLI.
    static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return key
        }
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "ANTHROPIC_API_KEY" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `formatterClaudeModel` holds CLI aliases ("haiku", "sonnet"). The API needs ids.
    static func modelID(for alias: String) -> String {
        switch alias.lowercased() {
        case "", "haiku": "claude-haiku-5-5"
        case "sonnet": "claude-sonnet-5-5"
        case "opus": "claude-opus-5-5"
        default: alias
        }
    }

    /// The API equivalent of `MAX_THINKING_TOKENS=0`. Thinking was 8 of every 9 seconds
    /// on the CLI path. Each model turns it off differently, and the wrong one is a 400:
    /// Haiku 5.5 takes `disabled`, Sonnet 5.5 rejects that and takes `between_tools`,
    /// Opus 5.5 can't turn it off at all, so low effort is the closest it gets.
    static func thinkingFields(for model: String) -> [String: Any] {
        switch model {
        case "claude-haiku-5-5": ["thinking": ["type": "disabled"]]
        case "claude-sonnet-5-5": ["thinking": ["type": "between_tools"]]
        case "claude-opus-5-5": ["output_config": ["effort": "low"]]
        default: [:]
        }
    }

    func format(_ raw: String, hints: FormattingHints, model alias: String, apiKey: String) async throws -> FormattedResult {
        let model = Self.modelID(for: alias)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": PromptBuilder.instructions,
            "messages": [["role": "user", "content": PromptBuilder.prompt(for: raw, hints: hints)]],
        ]
        body.merge(Self.thinkingFields(for: model)) { $1 }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let signpost = Log.signposter
        let state = signpost.beginInterval("format")
        defer { signpost.endInterval("format", state) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // The body is the API's error JSON. It never echoes the key.
            let detail = String(decoding: data.prefix(500), as: UTF8.self)
            Log.format.error("Anthropic API \(status, privacy: .public): \(detail, privacy: .public)")
            throw FormattingError.underlying("Anthropic API \(status)")
        }

        let message = try JSONDecoder().decode(Message.self, from: data)
        // A refusal is HTTP 200. Its content is an apology, not the dictation.
        guard message.stop_reason != "refusal" else {
            throw FormattingError.underlying("Anthropic API refused")
        }
        let text = message.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FormattingError.underlying("empty result") }
        // Same backstop as the CLI: 3× the input means the model broke character.
        guard text.count <= max(120, raw.count * 3) else {
            Log.format.error("Anthropic API returned \(text.count, privacy: .public) chars for \(raw.count, privacy: .public), discarding")
            throw FormattingError.underlying("implausible formatter output")
        }
        return FormattedResult(text: text, formatter: .claude)
    }

    private struct Message: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
        let stop_reason: String?
    }
}
