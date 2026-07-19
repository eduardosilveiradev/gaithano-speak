import Foundation

/// Lightweight energy-based voice-activity check used to (a) decide whether a hold
/// captured any speech and (b) trim leading/trailing silence before transcription.
///
/// This intentionally avoids pulling in a second CoreML model on first run.
/// FluidAudio ships a Silero VAD (`VadManager`) that can be swapped in later for
/// higher accuracy; the interface here is deliberately small so that's a drop-in.
enum VoiceActivity {
    /// RMS threshold below which a frame is considered silence.
    static let energyThreshold: Float = 0.006
    /// Minimum total voiced duration to count as real speech.
    static let minVoicedSeconds: Double = 0.15

    struct Result {
        var hasSpeech: Bool
        var trimmed: [Float]
    }

    static func analyze(_ samples: [Float], sampleRate: Int = 16_000) -> Result {
        guard !samples.isEmpty else { return Result(hasSpeech: false, trimmed: []) }

        let frameSize = max(1, sampleRate / 100) // 10 ms frames
        var firstVoiced = -1
        var lastVoiced = -1
        var voicedFrames = 0
        var idx = 0
        var frame = 0
        while idx < samples.count {
            let end = min(idx + frameSize, samples.count)
            var sum: Float = 0
            for i in idx..<end { sum += samples[i] * samples[i] }
            let count = Float(end - idx)
            let rms = count > 0 ? (sum / count).squareRoot() : 0
            if rms >= energyThreshold {
                if firstVoiced < 0 { firstVoiced = idx }
                lastVoiced = end
                voicedFrames += 1
            }
            idx = end
            frame += 1
        }

        let voicedSeconds = Double(voicedFrames * frameSize) / Double(sampleRate)
        guard firstVoiced >= 0, voicedSeconds >= minVoicedSeconds else {
            return Result(hasSpeech: false, trimmed: [])
        }

        // Pad the trim by 100 ms on each side so we don't clip consonants.
        let pad = sampleRate / 10
        let start = max(0, firstVoiced - pad)
        let stop = min(samples.count, lastVoiced + pad)
        return Result(hasSpeech: true, trimmed: Array(samples[start..<stop]))
    }
}
