import Foundation

/// Which physical key(s) arm dictation.
public enum HotkeyChoice: String, Codable, Sendable, CaseIterable {
    /// Control + Option held together. Far less likely to collide with a normal
    /// keystroke than bare Option, so the grace window rarely has to abandon.
    case controlOption
    case eitherOption
    case leftOption
    case rightOption
    case fn

    public var displayName: String {
        switch self {
        case .controlOption: return "Control + Option (⌃⌥)"
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

    public init(hotkey: HotkeyChoice = .controlOption,
                engine: EngineID = .parakeet,
                formattingEnabled: Bool = true,
                preferredFormatter: FormatterID = .foundationModel,
                playSounds: Bool = true,
                launchAtLogin: Bool = false,
                handsFreeEnabled: Bool = true,
                pauseAudioWhileListening: Bool = true,
                hasCompletedOnboarding: Bool = false,
                localServerURL: String = "http://localhost:1234/v1",
                localServerModel: String = "gemma-4-e2b-it-mlx") {
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
    }

    public static let `default` = AppSettings()

    // Lenient decoding: any missing key falls back to its default, so adding a
    // new setting in a future build never wipes the user's saved preferences.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        hotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey) ?? d.hotkey
        engine = try c.decodeIfPresent(EngineID.self, forKey: .engine) ?? d.engine
        formattingEnabled = try c.decodeIfPresent(Bool.self, forKey: .formattingEnabled) ?? d.formattingEnabled
        preferredFormatter = try c.decodeIfPresent(FormatterID.self, forKey: .preferredFormatter) ?? d.preferredFormatter
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        handsFreeEnabled = try c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? d.handsFreeEnabled
        pauseAudioWhileListening = try c.decodeIfPresent(Bool.self, forKey: .pauseAudioWhileListening) ?? d.pauseAudioWhileListening
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        localServerURL = try c.decodeIfPresent(String.self, forKey: .localServerURL) ?? d.localServerURL
        localServerModel = try c.decodeIfPresent(String.self, forKey: .localServerModel) ?? d.localServerModel
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
