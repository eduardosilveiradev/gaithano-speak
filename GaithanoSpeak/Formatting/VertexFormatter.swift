import Foundation
import SpeakCore

/// Formats transcripts with Gemini on Vertex AI.
///
/// This is the only formatter that sends the user's dictation off the machine, which
/// makes it the one place the app's local-first promise stops holding. Every word
/// spoken while it is selected — in any app, including ones the user would never
/// paste into a chatbot — is uploaded to Google. Settings says so in as many words;
/// don't soften that copy.
///
/// It exists because the on-device Foundation Model is grammar-blind on longer
/// utterances and Apple Intelligence silently refuses some content outright, so a
/// user who dictates prose all day has a real quality reason to want a bigger model.
/// That's a trade worth offering, not one worth defaulting to.
///
/// Non-streaming: `PromptBuilder` returns a whole rewritten utterance, and there is
/// nothing to stream it into — insertion happens once, after the text is final.
struct VertexFormatter {
    let credentials: GoogleCredentials

    struct Config: Sendable {
        var model: String
        var projectID: String?
        var region: String
    }

    /// Tighter than Talk's. A formatter sits directly in the dictation path, so its
    /// timeout is felt as lag on every utterance — and unlike Talk there's a good
    /// fallback one `catch` away, so waiting longer buys nothing.
    var timeout: TimeInterval = 8

    func format(_ raw: String,
                hints: FormattingHints,
                config: Config) async throws -> FormattedResult {
        guard let project = resolvedProject(config) else {
            throw FormattingError.underlying("no GCP project for Vertex formatting")
        }

        let payload: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": PromptBuilder.prompt(for: raw, hints: hints)]],
            ]],
            "systemInstruction": ["parts": [["text": PromptBuilder.instructions]]],
            "generationConfig": [
                // Formatting is a rewrite, not a generation: the model should be
                // reproducing the user's words, and temperature only invents.
                "temperature": 0.0,
                "maxOutputTokens": 1024,
                // Thinking on a punctuation pass is pure latency — it doubles the
                // round trip to reason about where a comma goes.
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        let signpost = Log.signposter
        let state = signpost.beginInterval("format")
        defer { signpost.endInterval("format", state) }

        do {
            return try await send(project: project, config: config, body: body)
        } catch FormattingError.underlying("unauthorized") {
            // The ADC token expired mid-session. One retry with a fresh one, matching
            // what `AgentModel` does — a 401 here is routine, not a failure.
            await credentials.invalidate()
            return try await send(project: project, config: config, body: body)
        }
    }

    private func send(project: String,
                      config: Config,
                      body: Data) async throws -> FormattedResult {
        let token: String
        do {
            token = try await credentials.accessToken()
        } catch {
            throw FormattingError.underlying("no gcloud credentials")
        }

        var request = URLRequest(url: try endpoint(project: project, config: config))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        request.timeoutInterval = timeout
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.format.error("Vertex unreachable: \(error.localizedDescription, privacy: .public)")
            throw FormattingError.underlying("Vertex unreachable")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FormattingError.underlying("no HTTP response")
        }
        if http.statusCode == 401 { throw FormattingError.underlying("unauthorized") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = StreamChunkParser.errorMessage(fromBody: data) ?? ""
            Log.format.error("Vertex HTTP \(http.statusCode): \(detail, privacy: .public)")
            throw FormattingError.underlying("Vertex HTTP \(http.statusCode)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw FormattingError.underlying("unparseable Vertex response")
        }

        // Gemini 3.5 interleaves thought parts (a `thoughtSignature`, empty text) with
        // the real one even at a zero budget, so join the text parts rather than
        // taking parts[0] — which is empty often enough to look like a dead model.
        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FormattingError.underlying("empty result") }
        return FormattedResult(text: text, formatter: .vertexGemini)
    }

    private func resolvedProject(_ config: Config) -> String? {
        if let explicit = config.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        return GoogleCredentials.defaultProjectID
    }

    private func endpoint(project: String, config: Config) throws -> URL {
        let region = config.region.isEmpty ? "global" : config.region
        let host = region == "global"
            ? "aiplatform.googleapis.com"
            : "\(region)-aiplatform.googleapis.com"
        let path = "https://\(host)/v1/projects/\(project)/locations/\(region)"
            + "/publishers/google/models/\(config.model):generateContent"
        guard let url = URL(string: path) else {
            throw FormattingError.underlying("bad Vertex URL for '\(config.model)'")
        }
        return url
    }
}
