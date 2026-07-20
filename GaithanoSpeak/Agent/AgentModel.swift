import Foundation
import SpeakCore

/// Asks Gemini what to do next, one action at a time.
///
/// Unlike `VertexTalkProvider` this does *not* stream. A function call arrives
/// fragmented across SSE chunks — name in one, arguments split across several — so
/// reassembling it would mean writing a second, subtly different parser whose only
/// job is to reconstruct what `generateContent` already returns whole. There is also
/// nothing to stream *to*: the UI shows the action, and the action doesn't exist
/// until the call is complete.
struct AgentModel: Sendable {
    let credentials: GoogleCredentials
    let config: TalkConfig

    enum ModelError: LocalizedError {
        case notConfigured(String)
        case http(Int, String)
        case noAction(String)
        case badArguments(String)

        var errorDescription: String? {
            switch self {
            case let .notConfigured(why): return why
            case let .http(code, message):
                return message.isEmpty ? "Vertex returned \(code)" : "Vertex \(code): \(message)"
            case let .noAction(text): return text
            case let .badArguments(why): return "the model sent an unusable action (\(why))"
            }
        }
    }

    /// A model turn: the action it chose, plus the raw call so the loop can append it
    /// to history verbatim. Gemini rejects a `functionResponse` that doesn't match a
    /// preceding `functionCall`, so the round trip has to carry the original.
    ///
    /// `rawParts` is the model content's ENTIRE parts array, not just the function
    /// call. Gemini 3.5 hangs a `thoughtSignature` on the part alongside the call, and
    /// rejects a follow-up turn whose history dropped it ("Function call is missing a
    /// thought_signature"). Reconstructing a part from its pieces loses whatever
    /// fields we didn't think to copy, so the whole thing is echoed back untouched.
    ///
    /// JSON bytes rather than a dictionary because this crosses an isolation boundary
    /// — `[String: Any]` is not `Sendable`, and marking it as such would be a lie
    /// about a value the network layer really does hand off.
    struct Turn: Sendable {
        var action: AgentAction
        var rawParts: Data
        var toolName: String
    }

    // MARK: - Tool schema

    /// The tools the model may call. Names and parameter names are load-bearing:
    /// `parse` reads them back, and `AgentPromptBuilder` describes them to the model.
    static var declarations: [[String: Any]] {
        [
            [
                "name": "click",
                "description": "Click something on screen. Coordinates are pixels in "
                    + "the screenshot, (0,0) at the top-left.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "x": ["type": "INTEGER", "description": "Horizontal pixel."],
                        "y": ["type": "INTEGER", "description": "Vertical pixel."],
                        "label": [
                            "type": "STRING",
                            "description": "What you are clicking, exactly as it reads "
                                + "on screen. Shown to the user for approval.",
                        ],
                        "double": [
                            "type": "BOOLEAN",
                            "description": "True for a double-click.",
                        ],
                    ],
                    "required": ["x", "y", "label"],
                ],
            ],
            [
                "name": "type",
                "description": "Type text into whatever currently has keyboard focus. "
                    + "Click the field first.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["text": ["type": "STRING"]],
                    "required": ["text"],
                ],
            ],
            [
                "name": "press",
                "description": "Press a key or chord, e.g. 'return', 'cmd+a', "
                    + "'cmd+shift+t'. Modifiers are cmd, shift, opt, ctrl.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["keys": ["type": "STRING"]],
                    "required": ["keys"],
                ],
            ],
            [
                "name": "scroll",
                "description": "Scroll at a point. Positive amount scrolls down.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "x": ["type": "INTEGER"],
                        "y": ["type": "INTEGER"],
                        "amount": [
                            "type": "INTEGER",
                            "description": "Pixels to scroll; negative scrolls up.",
                        ],
                    ],
                    "required": ["x", "y", "amount"],
                ],
            ],
            [
                "name": "switch_tab",
                "description": "Switch tabs in the frontmost app — browser, editor, "
                    + "or terminal. Prefer this over clicking a tab: the strip is "
                    + "often too crowded to hit accurately, and the tab you want may "
                    + "be scrolled out of view entirely.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "target": [
                            "type": "STRING",
                            "description": "A tab number from 1 to 9, where 9 means "
                                + "the LAST tab rather than the ninth. Or 'next' / "
                                + "'previous' to cycle, which is the only way to "
                                + "reach tabs past the ninth.",
                        ],
                    ],
                    "required": ["target"],
                ],
            ],
            [
                "name": "done",
                "description": "The task is finished, or you have stopped because you "
                    + "cannot safely continue. Explain which.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "summary": [
                            "type": "STRING",
                            "description": "What you did, or why you stopped.",
                        ],
                    ],
                    "required": ["summary"],
                ],
            ],
        ]
    }

    // MARK: - Request

    /// `contentsJSON` is the serialized conversation array, for the `Sendable` reason
    /// described on `Turn`.
    func next(contentsJSON: Data, systemPrompt: String) async throws -> Turn {
        guard let project = resolvedProject() else {
            throw ModelError.notConfigured(
                "no GCP project set — add one in Settings, or run `gcloud config set project`")
        }
        guard let contents = try? JSONSerialization.jsonObject(with: contentsJSON) as? [Any] else {
            throw ModelError.badArguments("could not encode the conversation")
        }

        let payload: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "tools": [["functionDeclarations": Self.declarations]],
            // ANY forces a tool call every turn. Without it the model narrates what it
            // intends to do instead of doing it, and the loop stalls on a text part it
            // has no way to act on.
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": config.maxOutputTokens,
                "thinkingConfig": ["thinkingBudget": config.thinkingBudget],
            ],
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            return try await send(project: project, body: body)
        } catch ModelError.http(401, _) {
            await credentials.invalidate()
            Log.talk.info("Agent got 401 from Vertex; retrying with a fresh token")
            return try await send(project: project, body: body)
        }
    }

    private func send(project: String, body: Data) async throws -> Turn {
        let token = try await credentials.accessToken()
        var request = URLRequest(url: try endpoint(project: project))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        request.timeoutInterval = config.timeout
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelError.http(0, "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelError.http(http.statusCode,
                                  StreamChunkParser.errorMessage(fromBody: data) ?? "")
        }
        return try Self.parse(responseBody: data)
    }

    private func resolvedProject() -> String? {
        if let explicit = config.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        return GoogleCredentials.defaultProjectID
    }

    private func endpoint(project: String) throws -> URL {
        let region = config.region.isEmpty ? "global" : config.region
        let host = region == "global"
            ? "aiplatform.googleapis.com"
            : "\(region)-aiplatform.googleapis.com"
        let path = "https://\(host)/v1/projects/\(project)/locations/\(region)"
            + "/publishers/google/models/\(config.model):generateContent"
        guard let url = URL(string: path) else {
            throw ModelError.notConfigured("could not build a Vertex URL for '\(config.model)'")
        }
        return url
    }

    // MARK: - Response

    static func parse(responseBody data: Data) throws -> Turn {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ModelError.noAction("the model returned nothing to act on")
        }

        // Gemini 3.5 interleaves thought parts (a `thoughtSignature`, empty text) with
        // the real one, so scan for the call rather than assuming parts[0].
        for part in parts {
            guard let call = part["functionCall"] as? [String: Any],
                  let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            return Turn(action: try action(name: name, args: args),
                        rawParts: try JSONSerialization.data(withJSONObject: parts),
                        toolName: name)
        }

        // No call, despite mode ANY. Whatever it said is the most useful thing we can
        // show, so surface it rather than a generic failure.
        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ModelError.noAction(text.isEmpty ? "the model chose no action" : text)
    }

    private static func action(name: String, args: [String: Any]) throws -> AgentAction {
        switch name {
        case "click":
            guard let x = int(args["x"]), let y = int(args["y"]) else {
                throw ModelError.badArguments("click without coordinates")
            }
            // The label drives both the confirmation prompt and the risk policy. A
            // missing one can't be defaulted to something friendly — an unreviewable
            // click must read as unreviewable.
            let label = (args["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .click(x: x, y: y,
                          label: label?.isEmpty == false ? label! : "an unlabelled target",
                          double: args["double"] as? Bool ?? false)

        case "type":
            guard let text = args["text"] as? String, !text.isEmpty else {
                throw ModelError.badArguments("type with no text")
            }
            return .type(text)

        case "press":
            guard let keys = (args["keys"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !keys.isEmpty else {
                throw ModelError.badArguments("press with no keys")
            }
            return .press(keys)

        case "scroll":
            guard let x = int(args["x"]), let y = int(args["y"]) else {
                throw ModelError.badArguments("scroll without coordinates")
            }
            return .scroll(x: x, y: y, amount: int(args["amount"]) ?? 300)

        case "switch_tab":
            guard let target = tabTarget(args["target"]) else {
                throw ModelError.badArguments("switch_tab without a usable target")
            }
            return .switchTab(target)

        case "done":
            let summary = (args["summary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .done(summary?.isEmpty == false ? summary! : "Finished.")

        default:
            throw ModelError.badArguments("unknown tool '\(name)'")
        }
    }

    /// Accepts what the schema asks for (`"3"`, `"next"`) and what models send anyway
    /// (a bare `3`, `"tab 3"`, `"right"`). An unparseable target returns nil rather
    /// than defaulting to a direction — guessing which way to move is worse than
    /// telling the model its argument was wrong and letting it retry.
    private static func tabTarget(_ value: Any?) -> TabTarget? {
        if let n = int(value) { return .index(n) }
        guard let raw = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else { return nil }

        switch raw {
        case "next", "right", "forward": return .next
        case "previous", "prev", "left", "back": return .previous
        default: break
        }
        // "tab 3" / "tab3" — pull the first run of digits out.
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        if let n = Int(digits) { return .index(n) }
        return nil
    }

    /// Gemini sends integers as `NSNumber`, but a model that writes `"x": "412"` is
    /// common enough that rejecting the string would fail runs for no good reason.
    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
