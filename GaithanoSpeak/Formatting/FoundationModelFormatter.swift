import Foundation
import SpeakCore
import FoundationModels

/// Formats transcripts with Apple's on-device Foundation Model. Falls back to
/// deterministic cleanup at the coordinator level if this throws (Apple
/// Intelligence disabled, guardrail refusal, or timeout).
///
/// Latency notes (measured on macOS 26): the on-device model takes ~5–9s COLD and
/// ~0.5–3s once its weights are warm in the ANE. So two things matter enormously:
///   1. `prewarm()` — call it when recording STARTS, so the model loads while the
///      user is still speaking and is hot by the time we have a transcript.
///   2. A realistic timeout — the old 2.5s cap fired on literally every call, which
///      is why formatting silently degraded to deterministic cleanup (no grammar
///      fixing). 10s virtually never trips once warm.
/// We use plain-string generation (not guided `@Generable`): guided/constrained
/// decoding measured ~7s even warm, plain-string ~0.5s warm — same quality here
/// because `PromptBuilder.instructions` already pins the output to cleaned text.
@MainActor
final class FoundationModelFormatter {
    let id: FormatterID = .foundationModel
    /// Generous cap: better a slightly slow correct result than a spurious timeout
    /// that drops us to grammar-blind deterministic cleanup.
    let timeout: TimeInterval = 10

    /// Long-lived session used ONLY to keep the shared model weights resident in the
    /// ANE (weights are process-global, so warming any session warms them all). The
    /// actual formatting uses a fresh session each call so prior dictations never
    /// bleed into the context.
    private var keepWarm: LanguageModelSession?

    static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Load the model into memory ahead of time. Cheap to call repeatedly; ideal to
    /// fire the moment recording begins so generation is warm when speech ends.
    func prewarm() {
        guard Self.isAvailable() else { return }
        if keepWarm == nil {
            keepWarm = LanguageModelSession(instructions: PromptBuilder.instructions)
        }
        keepWarm?.prewarm()
    }

    func format(_ raw: String, hints: FormattingHints) async throws -> FormattedResult {
        guard Self.isAvailable() else { throw FormattingError.unavailable }

        let signpost = Log.signposter
        let state = signpost.beginInterval("format")
        defer { signpost.endInterval("format", state) }

        let prompt = PromptBuilder.prompt(for: raw, hints: hints)
        let instructions = PromptBuilder.instructions
        do {
            let text = try await withTimeout(seconds: timeout) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                return response.content
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw FormattingError.underlying("empty result") }
            return FormattedResult(text: cleaned, formatter: .foundationModel)
        } catch is TimeoutError {
            throw FormattingError.timedOut
        } catch let e as FormattingError {
            throw e
        } catch {
            // Guardrail refusals and other generation errors land here.
            Log.format.error("FM format failed: \(error.localizedDescription, privacy: .public)")
            throw FormattingError.underlying(String(describing: error))
        }
    }
}

struct TimeoutError: Error {}

/// Race an async operation against a timeout.
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}
