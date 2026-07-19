import Foundation
import AVFoundation
import SpeakCore
import FluidAudio

/// Best-effort live "ghost text" transcriber that drives the overlay's live
/// transcription bubble while the user is still speaking.
///
/// This wraps FluidAudio's cache-aware streaming Parakeet-EOU model, which is a
/// SEPARATE, lighter model from the offline TDT v3 engine that produces the final,
/// inserted text. We deliberately keep the two apart: the streaming model is only
/// a low-latency preview, while the offline engine still owns the high-quality
/// transcript that actually lands in the target app.
///
/// Every method is a safe no-op until the model has finished loading, and all
/// failures are swallowed — if the preview model never downloads, the bubble just
/// stays empty and nothing else is affected.
actor StreamingTranscriber {
    private let manager: any StreamingAsrManager
    private var loaded = false
    private var loading = false

    /// 16 kHz mono Float32 — exactly what `AudioRecorder` emits.
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: false)!

    init() {
        // 160 ms chunks: the lowest-latency EOU variant, ideal for a live preview.
        manager = StreamingModelVariant.parakeetEou160ms.createManager()
    }

    var isReady: Bool { loaded }

    /// Download + load the streaming model. Idempotent; a failure leaves the
    /// preview permanently off without disturbing the main pipeline.
    func prepare() async {
        guard !loaded, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            try await manager.loadModels()
            loaded = true
            Log.engine.info("Live preview model ready")
        } catch {
            Log.engine.error("Live preview model failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start a fresh utterance and wire the partial-text callback. No-op until loaded.
    func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        guard loaded else { return }
        try? await manager.reset()
        await manager.setPartialTranscriptCallback(onPartial)
    }

    /// Feed one 16 kHz mono chunk and decode any now-complete streaming chunks.
    func append(_ samples: [Float]) async {
        guard loaded, !samples.isEmpty,
              let buffer = Self.makeBuffer(samples, format: format) else { return }
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            // Non-fatal: drop this chunk from the preview.
        }
    }

    /// Flush and end the utterance, releasing buffered state for the next one.
    func end() async {
        guard loaded else { return }
        _ = try? await manager.finish()
    }

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}
