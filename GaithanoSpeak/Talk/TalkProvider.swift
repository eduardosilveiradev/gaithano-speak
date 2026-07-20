import Foundation
import SpeakCore

/// A backend that can answer a Talk question, streaming the answer as it arrives.
///
/// Streaming is a callback rather than an `AsyncSequence` so providers stay free to
/// emit from wherever their transport lands, and so the coordinator can push deltas
/// straight into an `@Observable` without owning a consuming task per request.
protocol TalkProvider: Sendable {
    var id: TalkProviderID { get }

    /// Answer `request`, invoking `onDelta` for each text fragment as it streams.
    /// Returns the complete answer. Throws `TalkError` on any failure.
    func answer(_ request: TalkRequest,
                config: TalkConfig,
                onDelta: @escaping @Sendable (String) -> Void) async throws -> String
}

extension TalkProvider {
    /// Shared SSE pump: walks an HTTP byte stream line by line, feeding each through
    /// `parse` and accumulating whatever comes back. Both providers differ only in
    /// how they build the request and which line parser they hand in.
    func streamSSE(_ request: URLRequest,
                   parse: @Sendable (String) -> String?,
                   onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TalkError.timedOut
        } catch {
            throw TalkError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TalkError.underlying("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The error body arrives on the same stream; drain it for the message.
            var raw = Data()
            for try await byte in bytes where raw.count < 4096 { raw.append(byte) }
            let message = StreamChunkParser.errorMessage(fromBody: raw)
                ?? String(data: raw, encoding: .utf8)?.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            throw TalkError.http(http.statusCode, message)
        }

        var full = ""
        do {
            for try await line in bytes.lines {
                guard let delta = parse(line) else { continue }
                full += delta
                onDelta(delta)
            }
        } catch let error as URLError where error.code == .timedOut {
            // Partial answers are still useful — only fail if nothing arrived.
            if full.isEmpty { throw TalkError.timedOut }
        } catch {
            if full.isEmpty { throw TalkError.underlying(error.localizedDescription) }
        }

        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TalkError.emptyResponse }
        return trimmed
    }
}
