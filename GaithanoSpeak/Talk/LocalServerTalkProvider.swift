import Foundation
import SpeakCore

/// Answers Talk questions with an OpenAI-compatible local server (LM Studio,
/// Ollama, llama.cpp). Doubles as the offline fallback when Vertex is
/// unconfigured or unreachable, so nothing leaves the machine.
///
/// Vision only works if the loaded model is multimodal; a text-only model will
/// either ignore the `image_url` part or reject it, which surfaces as a normal
/// error rather than anything special-cased here.
struct LocalServerTalkProvider: TalkProvider {
    let id: TalkProviderID = .localServer

    func answer(_ request: TalkRequest,
                config: TalkConfig,
                onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let base = TextRepair.normalizedOpenAIBase(config.endpoint),
              let url = URL(string: base + "/chat/completions") else {
            throw TalkError.notConfigured("invalid local server URL")
        }

        var payload: [String: Any] = [
            "messages": messages(request),
            "temperature": 0.3,
            "max_tokens": config.maxOutputTokens,
            "stream": true,
        ]
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { payload["model"] = model }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = config.timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let signpost = Log.signposter
        let state = signpost.beginInterval("answer")
        defer { signpost.endInterval("answer", state) }

        return try await streamSSE(req,
                                   parse: { StreamChunkParser.openAIDelta(fromSSELine: $0) },
                                   onDelta: onDelta)
    }

    private func messages(_ request: TalkRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.systemPrompt]
        ]
        for (index, turn) in request.thread.enumerated() {
            let isLatest = index == request.thread.count - 1
            // Same rule as Vertex: the image goes only on the newest user turn.
            if isLatest, turn.role == .user, let jpeg = request.context.screenshotJPEG {
                messages.append([
                    "role": "user",
                    "content": [
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                        ["type": "text", "text": turn.text],
                    ],
                ])
            } else {
                messages.append([
                    "role": turn.role == .user ? "user" : "assistant",
                    "content": turn.text,
                ])
            }
        }
        return messages
    }
}
