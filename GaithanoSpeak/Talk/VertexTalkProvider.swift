import Foundation
import SpeakCore

/// Answers Talk questions with Gemini on Vertex AI, streaming over SSE.
///
/// Request/response shapes here were verified live against `gemini-3.5-flash` on the
/// `global` endpoint rather than taken from docs — including two things worth
/// knowing: the model emits a trailing part carrying `thoughtSignature` with empty
/// text even when thinking is disabled, and a 512px JPEG costs ~1090 prompt tokens.
struct VertexTalkProvider: TalkProvider {
    let id: TalkProviderID = .vertexGemini
    let credentials: GoogleCredentials

    func answer(_ request: TalkRequest,
                config: TalkConfig,
                onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let project = resolvedProject(config) else {
            throw TalkError.notConfigured("no GCP project set — add one in Settings, or run `gcloud config set project`")
        }

        let body = try JSONSerialization.data(withJSONObject: payload(request, config: config))
        let url = try endpoint(project: project, config: config)

        let signpost = Log.signposter
        let state = signpost.beginInterval("answer")
        defer { signpost.endInterval("answer", state) }

        do {
            return try await send(url: url, project: project, body: body,
                                  config: config, onDelta: onDelta)
        } catch TalkError.http(401, _) {
            // The token looked live but the server disagreed — most often a machine
            // that slept through the expiry. Re-exchange once before giving up.
            await credentials.invalidate()
            Log.talk.info("Vertex returned 401; retrying with a fresh token")
            return try await send(url: url, project: project, body: body,
                                  config: config, onDelta: onDelta)
        }
    }

    private func send(url: URL,
                      project: String,
                      body: Data,
                      config: TalkConfig,
                      onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let token = try await credentials.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Bills the request to the user's own project rather than the OAuth client's.
        req.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        req.timeoutInterval = config.timeout
        req.httpBody = body

        return try await streamSSE(req,
                                   parse: { StreamChunkParser.geminiDelta(fromSSELine: $0) },
                                   onDelta: onDelta)
    }

    /// The user's explicit project wins; otherwise fall back to whatever ADC was
    /// set up against, so the common case needs no configuration at all.
    private func resolvedProject(_ config: TalkConfig) -> String? {
        if let explicit = config.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        return GoogleCredentials.defaultProjectID
    }

    private func endpoint(project: String, config: TalkConfig) throws -> URL {
        let region = config.region.isEmpty ? "global" : config.region
        // `global` is the only region whose host is unprefixed.
        let host = region == "global"
            ? "aiplatform.googleapis.com"
            : "\(region)-aiplatform.googleapis.com"
        let path = "https://\(host)/v1/projects/\(project)/locations/\(region)"
            + "/publishers/google/models/\(config.model):streamGenerateContent?alt=sse"
        guard let url = URL(string: path) else {
            throw TalkError.notConfigured("could not build a Vertex URL for model '\(config.model)'")
        }
        return url
    }

    private func payload(_ request: TalkRequest, config: TalkConfig) -> [String: Any] {
        var contents: [[String: Any]] = []
        for (index, turn) in request.thread.enumerated() {
            var parts: [[String: Any]] = []
            // The screenshot rides on the newest user turn only — earlier turns
            // already had their context when they were asked, and re-sending images
            // would multiply the token cost of every follow-up.
            let isLatest = index == request.thread.count - 1
            if isLatest, turn.role == .user, let jpeg = request.context.screenshotJPEG {
                parts.append(["inlineData": [
                    "mimeType": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ]])
            }
            parts.append(["text": turn.text])
            contents.append([
                "role": turn.role == .user ? "user" : "model",
                "parts": parts,
            ])
        }

        return [
            "contents": contents,
            "systemInstruction": ["parts": [["text": request.systemPrompt]]],
            "generationConfig": [
                "maxOutputTokens": config.maxOutputTokens,
                "temperature": 0.2,
                "thinkingConfig": ["thinkingBudget": config.thinkingBudget],
            ],
        ]
    }
}
