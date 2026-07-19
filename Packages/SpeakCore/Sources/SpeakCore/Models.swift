import Foundation

/// Identifies a speech-to-text engine implementation.
public enum EngineID: String, Codable, Sendable, CaseIterable {
    case parakeet
    case appleSpeech

    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (on-device)"
        case .appleSpeech: return "Apple Speech (on-device)"
        }
    }
}

/// Identifies a text-formatting implementation.
public enum FormatterID: String, Codable, Sendable, CaseIterable {
    case foundationModel
    case deterministic
    case claude
    case localServer

    public var displayName: String {
        switch self {
        case .foundationModel: return "On-device (Apple Intelligence)"
        case .deterministic: return "Basic cleanup"
        case .claude: return "Claude (cloud)"
        case .localServer: return "Local LLM (LM Studio / Ollama)"
        }
    }
}

/// A raw transcription result from a `TranscriptionEngine`.
public struct Transcript: Equatable, Sendable {
    public var text: String
    /// Wall-clock duration of the captured audio, in seconds.
    public var audioDuration: TimeInterval
    /// Detected language code (BCP-47), if the engine reports one.
    public var language: String?

    public init(text: String, audioDuration: TimeInterval, language: String? = nil) {
        self.text = text
        self.audioDuration = audioDuration
        self.language = language
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The final formatted result ready for insertion.
public struct FormattedResult: Equatable, Sendable {
    public var text: String
    /// Which formatter actually produced this (may differ from the requested one
    /// if a fallback kicked in).
    public var formatter: FormatterID

    public init(text: String, formatter: FormatterID) {
        self.text = text
        self.formatter = formatter
    }
}

/// Context passed to a formatter to guide cleanup (tone, vocabulary, target app).
public struct FormattingHints: Equatable, Sendable {
    /// User dictionary terms to preserve/prefer (proper nouns, jargon).
    public var vocabulary: [String]
    /// Bundle identifier of the frontmost app, if known (for future tone matching).
    public var targetBundleID: String?
    /// Whether the model may reformat into lists / structure.
    public var allowStructure: Bool
    /// Text already in the focused field immediately BEFORE the cursor. Lets the
    /// model merge the new dictation cleanly (capitalization, spacing) instead of
    /// blindly capitalizing and prepending.
    public var precedingText: String?
    /// Text immediately AFTER the cursor, if any.
    public var followingText: String?

    public init(vocabulary: [String] = [],
                targetBundleID: String? = nil,
                allowStructure: Bool = true,
                precedingText: String? = nil,
                followingText: String? = nil) {
        self.vocabulary = vocabulary
        self.targetBundleID = targetBundleID
        self.allowStructure = allowStructure
        self.precedingText = precedingText
        self.followingText = followingText
    }

    public static let none = FormattingHints()
}
