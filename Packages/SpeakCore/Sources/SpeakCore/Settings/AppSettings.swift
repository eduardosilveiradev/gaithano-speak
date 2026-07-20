import Foundation

/// Which physical key(s) arm dictation.
///
/// Adding Control to whichever choice is active upgrades the utterance to Talk, so
/// no option here may itself require Control — that gesture is spoken for.
public enum HotkeyChoice: String, Codable, Sendable, CaseIterable {
    case eitherOption
    case leftOption
    case rightOption
    case fn

    public var displayName: String {
        switch self {
        case .eitherOption: return "Either Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / 🌐"
        }
    }
}

/// User-facing preferences. Codable so the whole struct round-trips through
/// `UserDefaults` as one JSON blob (simple, atomic, testable).
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: HotkeyChoice
    public var engine: EngineID
    public var formattingEnabled: Bool
    public var preferredFormatter: FormatterID
    public var playSounds: Bool
    public var launchAtLogin: Bool
    public var handsFreeEnabled: Bool
    public var pauseAudioWhileListening: Bool
    /// Set once the user finishes (or dismisses) the onboarding flow. Gates the
    /// auto-show on launch so setup only pops up on genuine first run — never again.
    public var hasCompletedOnboarding: Bool
    /// OpenAI-compatible base URL for the `.localServer` formatter (LM Studio default
    /// is :1234; Ollama is :11434). The "/v1" suffix is optional — it's normalized.
    public var localServerURL: String
    /// Model id to request from the local server. Empty = let the server use whatever
    /// model is currently loaded (LM Studio) / its default. Defaults to Gemma 4 E2B-it,
    /// a non-reasoning instruct model — reasoning variants spend hundreds of thinking
    /// tokens per format, which dominates latency for a few words of dictation.
    public var localServerModel: String

    /// Model id for the Vertex formatter. Separate from `talkModel` so the two can be
    /// tuned independently — formatting wants the cheapest model that punctuates well,
    /// while Talk answers questions and benefits from a stronger one.
    public var formatterVertexModel: String

    // MARK: Talk

    /// Whether holding Control alongside the dictation key asks a model instead of
    /// inserting text. Off sends every utterance down the normal dictation path.
    public var talkEnabled: Bool
    /// Whether adding Shift lets the model click and type on the user's behalf.
    ///
    /// On by default: this is a personal, directly-distributed tool whose owner asked
    /// for the gesture to be armed, and leaving it off made ⌃⇧⌥ silently behave like
    /// ⌃⌥ — a worse failure than the one the default was guarding against, since the
    /// user can't tell which mode they're in. What actually keeps this safe is
    /// `AgentRiskPolicy`, not the default, and that is unchanged.
    public var agentEnabled: Bool
    /// Start every agent run already in auto mode, so risky steps never stop to ask.
    ///
    /// Off by default and kept separate from `agentEnabled` because it removes the
    /// feature's only interactive rail. `.blocked` actions (typing while a password
    /// field has focus) are still refused — `AgentSession` checks those ahead of
    /// `autoConfirm`, and that ordering is not negotiable.
    public var agentAutoConfirm: Bool
    public var talkProvider: TalkProviderID
    /// Model id for the Talk provider. Vertex default is `gemini-3.5-flash`.
    public var talkModel: String
    /// GCP project for Vertex. Empty falls back to the project gcloud's Application
    /// Default Credentials were set up against, so the usual case needs no setup.
    public var vertexProjectID: String
    public var vertexRegion: String
    /// Attach a screenshot of the focused window to Talk questions. Requires the
    /// Screen Recording permission, and sends an image of the user's screen to the
    /// provider — off by default because that is not a small thing to opt into.
    public var talkVisionEnabled: Bool
    /// Gemini thinking budget. 0 by default: Talk answers short questions, and
    /// reasoning tokens dominate latency at that length.
    public var talkThinkingBudget: Int

    public init(hotkey: HotkeyChoice = .eitherOption,
                engine: EngineID = .parakeet,
                formattingEnabled: Bool = true,
                preferredFormatter: FormatterID = .foundationModel,
                playSounds: Bool = true,
                launchAtLogin: Bool = false,
                handsFreeEnabled: Bool = true,
                pauseAudioWhileListening: Bool = true,
                hasCompletedOnboarding: Bool = false,
                localServerURL: String = "http://localhost:1234/v1",
                localServerModel: String = "gemma-4-e2b-it-mlx",
                formatterVertexModel: String = "gemini-3.5-flash",
                talkEnabled: Bool = true,
                agentEnabled: Bool = true,
                agentAutoConfirm: Bool = false,
                talkProvider: TalkProviderID = .vertexGemini,
                talkModel: String = "gemini-3.5-flash",
                vertexProjectID: String = "",
                vertexRegion: String = "global",
                talkVisionEnabled: Bool = false,
                talkThinkingBudget: Int = 0) {
        self.hotkey = hotkey
        self.engine = engine
        self.formattingEnabled = formattingEnabled
        self.preferredFormatter = preferredFormatter
        self.playSounds = playSounds
        self.launchAtLogin = launchAtLogin
        self.handsFreeEnabled = handsFreeEnabled
        self.pauseAudioWhileListening = pauseAudioWhileListening
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.localServerURL = localServerURL
        self.localServerModel = localServerModel
        self.formatterVertexModel = formatterVertexModel
        self.talkEnabled = talkEnabled
        self.agentEnabled = agentEnabled
        self.agentAutoConfirm = agentAutoConfirm
        self.talkProvider = talkProvider
        self.talkModel = talkModel
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.talkVisionEnabled = talkVisionEnabled
        self.talkThinkingBudget = talkThinkingBudget
    }

    public static let `default` = AppSettings()

    // Lenient decoding: any missing key falls back to its default, so adding a
    // new setting in a future build never wipes the user's saved preferences.
    //
    // Enum fields use `try?` rather than `try`: `decodeIfPresent` THROWS on an
    // unrecognized raw value, and one removed case would otherwise fail the whole
    // decode and reset every unrelated setting the user had configured.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        hotkey = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? d.hotkey
        engine = (try? c.decodeIfPresent(EngineID.self, forKey: .engine)) ?? d.engine
        formattingEnabled = try c.decodeIfPresent(Bool.self, forKey: .formattingEnabled) ?? d.formattingEnabled
        preferredFormatter = (try? c.decodeIfPresent(FormatterID.self, forKey: .preferredFormatter)) ?? d.preferredFormatter
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        handsFreeEnabled = try c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? d.handsFreeEnabled
        pauseAudioWhileListening = try c.decodeIfPresent(Bool.self, forKey: .pauseAudioWhileListening) ?? d.pauseAudioWhileListening
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        localServerURL = try c.decodeIfPresent(String.self, forKey: .localServerURL) ?? d.localServerURL
        localServerModel = try c.decodeIfPresent(String.self, forKey: .localServerModel) ?? d.localServerModel
        formatterVertexModel = try c.decodeIfPresent(String.self, forKey: .formatterVertexModel) ?? d.formatterVertexModel
        talkEnabled = try c.decodeIfPresent(Bool.self, forKey: .talkEnabled) ?? d.talkEnabled
        agentEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentEnabled) ?? d.agentEnabled
        agentAutoConfirm = try c.decodeIfPresent(Bool.self, forKey: .agentAutoConfirm) ?? d.agentAutoConfirm
        talkProvider = (try? c.decodeIfPresent(TalkProviderID.self, forKey: .talkProvider)) ?? d.talkProvider
        talkModel = try c.decodeIfPresent(String.self, forKey: .talkModel) ?? d.talkModel
        vertexProjectID = try c.decodeIfPresent(String.self, forKey: .vertexProjectID) ?? d.vertexProjectID
        vertexRegion = try c.decodeIfPresent(String.self, forKey: .vertexRegion) ?? d.vertexRegion
        talkVisionEnabled = try c.decodeIfPresent(Bool.self, forKey: .talkVisionEnabled) ?? d.talkVisionEnabled
        talkThinkingBudget = try c.decodeIfPresent(Int.self, forKey: .talkThinkingBudget) ?? d.talkThinkingBudget
    }
}

extension AppSettings {
    /// Resolve the Talk settings into the provider-facing config. Local-server
    /// fields double as the fallback target when a cloud provider is unusable, so
    /// they're always populated regardless of which provider is selected.
    public var talkConfig: TalkConfig {
        TalkConfig(
            provider: talkProvider,
            model: talkProvider == .vertexGemini ? talkModel : localServerModel,
            endpoint: localServerURL,
            projectID: vertexProjectID.isEmpty ? nil : vertexProjectID,
            region: vertexRegion.isEmpty ? "global" : vertexRegion,
            thinkingBudget: talkThinkingBudget
        )
    }
}

/// Persists `AppSettings` as a single JSON value under one key.
/// `@unchecked Sendable`: the only stored property is `UserDefaults`, which is
/// documented as thread-safe though not formally `Sendable`.
public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.gaithano.speak.settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
