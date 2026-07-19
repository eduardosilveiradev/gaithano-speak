import Foundation

/// A speech-to-text engine. Implementations live in the app target (they touch
/// CoreML / the Speech framework); the protocol lives here so the coordinator
/// and tests can depend on the abstraction.
public protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }

    /// Whether models are downloaded and loaded, ready to transcribe.
    var isReady: Bool { get async }

    /// Download / load whatever the engine needs. `progress` is called on an
    /// arbitrary thread with a value in 0...1.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws

    /// Transcribe mono Float32 PCM samples at the given sample rate.
    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> Transcript
}

/// Turns a raw transcript into polished text.
public protocol TextFormatter: Sendable {
    var id: FormatterID { get }
    func format(_ raw: String, hints: FormattingHints) async throws -> FormattedResult
}

/// Inserts text into the frontmost application.
public protocol TextInserter {
    @MainActor func insert(_ text: String) async throws
}

/// Errors that formatters may throw; the coordinator treats any formatter failure
/// as non-fatal and falls back to deterministic cleanup.
public enum FormattingError: Error, Equatable, Sendable {
    case unavailable
    case guardrailViolation
    case timedOut
    case underlying(String)
}
