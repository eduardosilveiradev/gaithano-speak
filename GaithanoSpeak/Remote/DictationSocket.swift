import AVFoundation
import Foundation
import SpeakCore

/// Lets another program on this Mac hand Gaithano Speak a recording to dictate: the Otto
/// server does, for its iPhone keyboard. One JSON line in, one JSON line out, on a 0600
/// Unix socket next to the agent proxy's:
///
///     → {"audio": "/path/to/recording.m4a", "preceding": "text before the cursor"}
///     ← {"raw": "…", "text": "…", "formatter": "claude"}   or   {"error": "…"}
///
/// The running app answers rather than a fresh process, so Parakeet is already loaded and
/// the user's formatter, dictionary and settings are the live ones.
@MainActor
enum DictationSocket {
    static let path = MCPServerConfig.supportDirectory.appendingPathComponent("dictate.sock").path

    static func start(coordinator: RecordingCoordinator) {
        let listener: Int32
        do { listener = try UnixSocket.listen(path: path) } catch {
            Log.coordinator.error("dictation socket: \(error.localizedDescription, privacy: .public)")
            return
        }
        Task { @MainActor in
            while let fd = try? await UnixSocket.acceptAsync(listener) {
                Task { @MainActor in await serve(fd, coordinator: coordinator) }
            }
        }
    }

    private struct Request: Decodable { let audio: String; let preceding: String? }

    private static func serve(_ fd: Int32, coordinator: RecordingCoordinator) async {
        defer { close(fd) }
        let reply: [String: String]
        do {
            let line = try await readLine(fd)
            let req = try JSONDecoder().decode(Request.self, from: line)
            let samples = try decode16kMono(URL(fileURLWithPath: req.audio))
            let out = try await coordinator.dictateRemote(samples: samples, precedingText: req.preceding)
            reply = ["raw": out.raw, "text": out.text, "formatter": out.formatter.rawValue]
        } catch {
            reply = ["error": error.localizedDescription]
        }
        var data = (try? JSONEncoder().encode(reply)) ?? Data(#"{"error":"encode"}"#.utf8)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads up to the first newline, off the main thread. 64 KB is far past any request.
    private static func readLine(_ fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                var out = Data(), byte: UInt8 = 0
                while out.count < 65_536, read(fd, &byte, 1) == 1 {
                    if byte == 0x0A { break }
                    out.append(byte)
                }
                out.isEmpty ? k.resume(throwing: UnixSocket.Failure.failed("empty request")) : k.resume(returning: out)
            }
        }
    }

    /// Any file AVAudioFile reads (the phone sends m4a), as the 16 kHz mono floats Parakeet takes.
    static func decode16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw UnixSocket.Failure.failed("unreadable audio") }
        try file.read(into: input)
        let ratio = 16_000 / file.processingFormat.sampleRate
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)!
        var fed = false
        var err: NSError?
        converter.convert(to: output, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
