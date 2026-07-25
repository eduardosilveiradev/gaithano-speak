import Foundation

/// Which backend answers a Talk question.
public enum TalkProviderID: String, Codable, Sendable, CaseIterable {
    case vertexGemini
    case localServer

    public var displayName: String {
        switch self {
        case .vertexGemini: return "Gemini (Vertex AI)"
        case .localServer: return "Local LLM (LM Studio / Ollama)"
        }
    }

    /// Whether this provider sends the question — and any screenshot — off the machine.
    public var isCloud: Bool {
        switch self {
        case .vertexGemini: return true
        case .localServer: return false
        }
    }
}

/// One turn of a Talk conversation. Threads stay short-lived: they live only as
/// long as the answer panel is open.
public struct TalkTurn: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Ambient context captured at the moment the user started speaking — what they
/// were looking at and what they had selected.
public struct TalkContext: Equatable, Sendable {
    /// Text selected in the focused app, if any (via the Accessibility API).
    public var selectedText: String?
    /// Human-readable name of the frontmost app, for grounding ("in Xcode…").
    public var frontmostAppName: String?
    /// JPEG of the focused window, already downscaled. Nil when vision is off,
    /// permission is missing, or capture failed — every path degrades to text-only.
    public var screenshotJPEG: Data?

    public init(selectedText: String? = nil,
                frontmostAppName: String? = nil,
                screenshotJPEG: Data? = nil) {
        self.selectedText = selectedText
        self.frontmostAppName = frontmostAppName
        self.screenshotJPEG = screenshotJPEG
    }

    public static let none = TalkContext()

    public var hasVision: Bool { screenshotJPEG != nil }
}

/// Everything a provider needs to answer, in a provider-neutral shape. Each
/// provider translates this at its own boundary — Gemini's `inlineData` and the
/// OpenAI `image_url` data URI never leak into the core.
public struct TalkRequest: Sendable {
    public var thread: [TalkTurn]
    public var context: TalkContext
    public var systemPrompt: String

    public init(thread: [TalkTurn], context: TalkContext, systemPrompt: String) {
        self.thread = thread
        self.context = context
        self.systemPrompt = systemPrompt
    }
}

/// Provider configuration, resolved from `AppSettings` at call time.
public struct TalkConfig: Sendable {
    public var provider: TalkProviderID
    /// Model id — `gemini-3.5-flash` on Vertex, or the local server's model name.
    public var model: String
    /// OpenAI-compatible base URL, used only by `.localServer`.
    public var endpoint: String
    /// GCP project, used only by `.vertexGemini`. Falls back to the ADC quota project.
    public var projectID: String?
    /// Vertex region. `global` matches the default used elsewhere in these projects.
    public var region: String
    /// Gemini thinking budget in tokens. Defaults to 0: Talk is a quick-answer
    /// feature, and reasoning tokens dominate latency for short questions.
    public var thinkingBudget: Int
    public var maxOutputTokens: Int
    public var timeout: TimeInterval

    public init(provider: TalkProviderID,
                model: String,
                endpoint: String = "",
                projectID: String? = nil,
                region: String = "global",
                thinkingBudget: Int = 0,
                maxOutputTokens: Int = 1024,
                timeout: TimeInterval = 30) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.projectID = projectID
        self.region = region
        self.thinkingBudget = thinkingBudget
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
    }
}

/// Errors a provider may throw. The coordinator surfaces these as a notice and,
/// for `.notConfigured`, transparently retries against the local provider.
public enum TalkError: Error, Equatable, Sendable {
    /// No usable credentials / project — the caller should fall back to local.
    case notConfigured(String)
    case unreachable(String)
    case http(Int, String)
    case emptyResponse
    case timedOut
    case underlying(String)

    /// Whether falling back to the local provider is worth attempting.
    public var isFallbackWorthy: Bool {
        switch self {
        case .notConfigured, .unreachable, .timedOut: return true
        case .http(let code, _): return code == 401 || code == 403 || code == 404
        case .emptyResponse, .underlying: return false
        }
    }
}
