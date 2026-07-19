import Foundation
import SpeakCore
import FluidAudio

/// On-device STT via NVIDIA Parakeet TDT v3 (CoreML/ANE) through FluidAudio.
/// Models (CC-BY-4.0) are downloaded on first use and cached by FluidAudio.
actor FluidAudioEngine: TranscriptionEngine {
    nonisolated let id: EngineID = .parakeet

    private var manager: AsrManager?
    private var loaded = false

    var isReady: Bool { loaded }

    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        if loaded { progress(1); return }
        Log.engine.info("Loading Parakeet models…")
        progress(0.05)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        progress(0.8)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.loaded = true
        progress(1)
        Log.engine.info("Parakeet ready")
    }

    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> Transcript {
        guard let manager else { throw TranscriptionEngineError.notReady }
        let signpost = Log.signposter
        let state = signpost.beginInterval("asr")
        defer { signpost.endInterval("asr", state) }

        // Fresh decoder state per utterance (non-streaming push-to-talk).
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let duration = Double(samples.count) / Double(sampleRate)
        return Transcript(text: result.text, audioDuration: duration, language: nil)
    }
}

enum TranscriptionEngineError: Error {
    case notReady
}
