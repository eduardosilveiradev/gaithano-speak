import Foundation

/// Which physical key(s) arm dictation.
///
/// Adding Control to whichever choice is active upgrades the utterance to Talk, so
/// no option here may itself require Control — that gesture is spoken for.
public enum HotkeyChoice: String, Codable, Sendable, CaseIterable {
    case rightControlRightOption
    case eitherOption
    case leftOption
    case rightOption
    case fn

    /// Legacy values remain decodable so existing preferences do not reset unrelated
    /// settings, but the only selectable shortcut is the new fixed chord.
    public static let allCases: [HotkeyChoice] = [.rightControlRightOption]

    public var displayName: String {
        switch self {
        case .rightControlRightOption: return "Right Control + Right Option (⌃⌥)"
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

    /// Model passed to `claude --model` for the `.claude` formatter. Separate from
    /// `talkModel` so the two can be tuned independently.
    ///
    /// Sonnet, not Haiku, and the reason is instruction-following rather than prose
    /// quality. With thinking disabled — which is what makes this formatter usable at
    /// all — Haiku broke two of the prompt's subtler rules in one sitting: it refused a
    /// transcript that read as a command instead of punctuating it, and it trimmed the
    /// opening words off dictations that continue existing text. Sonnet handles both,
    /// plus the stutter-across-a-pause dedup Haiku still misses, for about 0.8s more.
    /// Running on a subscription, the extra tokens are plan usage rather than money.
    /// Set it to `haiku` if latency ever matters more than the edges.
    public var formatterClaudeModel: String
    /// Explicit path to the `claude` binary. Blank auto-detects the usual install
    /// locations, which is the whole point: a GUI app launched by launchd inherits a
    /// bare PATH, so `claude` is never simply "on the path" the way it is in a shell.
    public var formatterClaudePath: String

    // MARK: Dictionary learning

    /// Watch what the formatter corrects and build dictionary entries from it.
    ///
    /// On by default: the observations are drawn from text that already went through
    /// the formatter, so nothing new leaves the machine, and the promotion rules are
    /// narrow enough that a wrong entry is rare. Off stops both the counting and the
    /// suggestions — it does not remove what was already learned.
    public var dictionaryLearningEnabled: Bool
    /// Let spelling substitutions in without asking.
    ///
    /// Off by default, and the one setting here worth being careful with. A casing
    /// fix can only recapitalise a word the user already said; a spelling fix swaps
    /// one word for another on every future dictation, and a wrong one reads as
    /// correct to the person who meant to say it.
    public var dictionaryLearningAutoAccept: Bool

    // MARK: Talk

    /// Whether holding Control alongside the dictation key asks a model instead of
    /// inserting text. Off sends every utterance down the normal dictation path.
    public var talkEnabled: Bool
    /// Point ⌃⌥ at a running Claude Code session instead of a model of ours: the
    /// utterance is typed into the terminal hosting it rather than answered.
    ///
    /// With this on there is no way to reach a plain question — one gesture, one
    /// destination. On by default because it's the
    /// gesture's owner who asked for it, and because it is the only ⌃⌥ path that keeps
    /// working when Vertex doesn't. There is deliberately no fallback: if no Claude
    /// Code session can be found the utterance fails with a notice rather than quietly
    /// going to a model the user didn't choose.
    public var claudeCodeHandoffEnabled: Bool
    /// Press Return after typing, so the prompt is submitted rather than left sitting
    /// in the composer.
    ///
    /// On by default — "paste it and let me look at it" is a different feature from
    /// "say it and it runs", and the second is what the gesture is for. Turn it off to
    /// get a chance to read the transcript before Claude Code acts on it.
    public var claudeCodeSubmitOnPaste: Bool
    /// Bundle id of the app hosting the session, e.g. `dev.warp.Warp-Stable`. Blank
    /// auto-detects by walking up from a running `claude` process to whichever GUI app
    /// launched it, which is right often enough that this is an escape hatch, not a
    /// setup step.
    public var claudeCodeAppBundleID: String
    public var talkProvider: TalkProviderID
    /// Model id for the Talk provider. Vertex default is `gemini-3.6-flash`.
    public var talkModel: String
    /// Model passed to `claude --model` for the `.claudeCode` Talk provider. Separate
    /// from `formatterClaudeModel` because the two jobs pull in opposite directions:
    /// the formatter is on the latency path of every dictation and wants the fastest
    /// model that follows instructions, while an answer is read rather than typed and
    /// is worth waiting an extra second for.
    public var talkClaudeModel: String
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

    // MARK: Speech

    /// Read Talk answers out loud when they arrive.
    ///
    /// Off by default, and deliberately so. This app's whole gesture is *press, speak,
    /// get text* — it is used in meetings, in shared offices, and next to sleeping
    /// people, and a setting that makes the machine talk back is not one to switch on
    /// for someone. It also only ever applies to answers: dictation is never spoken,
    /// because reading a user's own words back at them as they're typed into a document
    /// is noise, not a feature.
    public var speechEnabled: Bool
    public var speechEngine: SpeechEngineID
    /// Qwen3-TTS speaker. Ignored by the system engine, which uses the voice chosen in
    /// macOS Settings.
    public var speechVoice: SpeechVoice
    /// Interpreter with `mlx-audio` importable. Blank searches the usual places — see
    /// `SpeechConfig.candidateInterpreters`. Needed because Qwen3-TTS is a Python model
    /// and there is no MLX Swift port of it to link against.
    public var speechPythonPath: String
    /// Words per minute for the system voice. Qwen paces itself and ignores this.
    public var speechRate: Double
    /// Stop speaking past this many characters. Qwen synthesises at roughly 1×
    /// realtime, so an unclamped six-paragraph answer means a minute of talking with
    /// only Esc to stop it.
    public var speechMaxCharacters: Int

    public init(hotkey: HotkeyChoice = .rightControlRightOption,
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
                formatterClaudeModel: String = "sonnet",
                formatterClaudePath: String = "",
                dictionaryLearningEnabled: Bool = true,
                dictionaryLearningAutoAccept: Bool = false,
                talkEnabled: Bool = true,
                claudeCodeHandoffEnabled: Bool = true,
                claudeCodeSubmitOnPaste: Bool = true,
                claudeCodeAppBundleID: String = "",
                talkProvider: TalkProviderID = .vertexGemini,
                talkModel: String = "gemini-3.6-flash",
                talkClaudeModel: String = "sonnet",
                vertexProjectID: String = "",
                vertexRegion: String = "global",
                talkVisionEnabled: Bool = false,
                talkThinkingBudget: Int = 0,
                speechEnabled: Bool = false,
                speechEngine: SpeechEngineID = .qwen3,
                speechVoice: SpeechVoice = .ryan,
                speechPythonPath: String = "",
                speechRate: Double = 175,
                speechMaxCharacters: Int = 600) {
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
        self.formatterClaudeModel = formatterClaudeModel
        self.formatterClaudePath = formatterClaudePath
        self.dictionaryLearningEnabled = dictionaryLearningEnabled
        self.dictionaryLearningAutoAccept = dictionaryLearningAutoAccept
        self.talkEnabled = talkEnabled
        self.claudeCodeHandoffEnabled = claudeCodeHandoffEnabled
        self.claudeCodeSubmitOnPaste = claudeCodeSubmitOnPaste
        self.claudeCodeAppBundleID = claudeCodeAppBundleID
        self.talkProvider = talkProvider
        self.talkModel = talkModel
        self.talkClaudeModel = talkClaudeModel
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.talkVisionEnabled = talkVisionEnabled
        self.talkThinkingBudget = talkThinkingBudget
        self.speechEnabled = speechEnabled
        self.speechEngine = speechEngine
        self.speechVoice = speechVoice
        self.speechPythonPath = speechPythonPath
        self.speechRate = speechRate
        self.speechMaxCharacters = speechMaxCharacters
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
        formatterClaudeModel = try c.decodeIfPresent(String.self, forKey: .formatterClaudeModel) ?? d.formatterClaudeModel
        formatterClaudePath = try c.decodeIfPresent(String.self, forKey: .formatterClaudePath) ?? d.formatterClaudePath
        dictionaryLearningEnabled = try c.decodeIfPresent(Bool.self, forKey: .dictionaryLearningEnabled) ?? d.dictionaryLearningEnabled
        dictionaryLearningAutoAccept = try c.decodeIfPresent(Bool.self, forKey: .dictionaryLearningAutoAccept) ?? d.dictionaryLearningAutoAccept
        talkEnabled = try c.decodeIfPresent(Bool.self, forKey: .talkEnabled) ?? d.talkEnabled
        claudeCodeHandoffEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeCodeHandoffEnabled) ?? d.claudeCodeHandoffEnabled
        claudeCodeSubmitOnPaste = try c.decodeIfPresent(Bool.self, forKey: .claudeCodeSubmitOnPaste) ?? d.claudeCodeSubmitOnPaste
        claudeCodeAppBundleID = try c.decodeIfPresent(String.self, forKey: .claudeCodeAppBundleID) ?? d.claudeCodeAppBundleID
        talkProvider = (try? c.decodeIfPresent(TalkProviderID.self, forKey: .talkProvider)) ?? d.talkProvider
        talkModel = try c.decodeIfPresent(String.self, forKey: .talkModel) ?? d.talkModel
        talkClaudeModel = try c.decodeIfPresent(String.self, forKey: .talkClaudeModel) ?? d.talkClaudeModel
        vertexProjectID = try c.decodeIfPresent(String.self, forKey: .vertexProjectID) ?? d.vertexProjectID
        vertexRegion = try c.decodeIfPresent(String.self, forKey: .vertexRegion) ?? d.vertexRegion
        talkVisionEnabled = try c.decodeIfPresent(Bool.self, forKey: .talkVisionEnabled) ?? d.talkVisionEnabled
        talkThinkingBudget = try c.decodeIfPresent(Int.self, forKey: .talkThinkingBudget) ?? d.talkThinkingBudget
        speechEnabled = try c.decodeIfPresent(Bool.self, forKey: .speechEnabled) ?? d.speechEnabled
        speechEngine = (try? c.decodeIfPresent(SpeechEngineID.self, forKey: .speechEngine)) ?? d.speechEngine
        speechVoice = (try? c.decodeIfPresent(SpeechVoice.self, forKey: .speechVoice)) ?? d.speechVoice
        speechPythonPath = try c.decodeIfPresent(String.self, forKey: .speechPythonPath) ?? d.speechPythonPath
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        speechMaxCharacters = try c.decodeIfPresent(Int.self, forKey: .speechMaxCharacters) ?? d.speechMaxCharacters
    }
}

extension AppSettings {
    /// The learning thresholds, with the user's auto-accept choice folded in.
    public var learningPolicy: LearningPolicy {
        LearningPolicy(autoAcceptSpelling: dictionaryLearningAutoAccept)
    }

    /// Resolve the Talk settings into the provider-facing config. Local-server
    /// fields double as the fallback target when a cloud provider is unusable, so
    /// they're always populated regardless of which provider is selected.
    public var talkConfig: TalkConfig {
        let model: String
        switch talkProvider {
        case .vertexGemini: model = talkModel
        case .claudeCode: model = talkClaudeModel
        case .localServer: model = localServerModel
        }
        return TalkConfig(
            provider: talkProvider,
            model: model,
            endpoint: localServerURL,
            // The same binary the `.claude` formatter uses; there is only one on the
            // machine, so there is only one place to configure it.
            executablePath: formatterClaudePath,
            projectID: vertexProjectID.isEmpty ? nil : vertexProjectID,
            region: vertexRegion.isEmpty ? "global" : vertexRegion,
            thinkingBudget: talkThinkingBudget
        )
    }

    /// Resolve the speech settings into the config the synthesiser layer takes.
    public var speechConfig: SpeechConfig {
        SpeechConfig(enabled: speechEnabled,
                     engine: speechEngine,
                     voice: speechVoice,
                     pythonPath: speechPythonPath,
                     rate: speechRate,
                     maxCharacters: speechMaxCharacters)
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

    /// Vertex model ids that a previous build shipped as the default, mapped to what
    /// replaces them. Bumping the default in `init` alone changes nothing for anyone
    /// who has ever opened Settings — the whole struct is persisted, so the old
    /// default is sitting in their saved JSON. Only a value that still matches the
    /// superseded default is rewritten; anything the user typed themselves is left
    /// exactly as they typed it.
    static let supersededVertexModels = ["gemini-3.5-flash": "gemini-3.6-flash"]

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        if let newer = Self.supersededVertexModels[decoded.talkModel] {
            decoded.talkModel = newer
        }
        // The Vertex formatter was replaced by the Claude CLI. Anyone who had it
        // selected wanted a cloud model doing their grammar, so move them to the one
        // that still exists rather than dropping them back to the on-device default —
        // which is exactly the formatter they'd already rejected.
        if decoded.preferredFormatter == .vertexGemini {
            decoded.preferredFormatter = .claude
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
