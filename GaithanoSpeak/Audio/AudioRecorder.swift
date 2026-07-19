import Foundation
import AVFoundation
import AppKit

/// Captures microphone audio via AVAudioEngine, converts to 16 kHz mono Float32
/// (what the STT engines want), accumulates samples, and publishes RMS levels for
/// the waveform overlay.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isRunning = false

    private var levelContinuation: AsyncStream<Float>.Continuation?
    /// A stream of 0...1 RMS levels for the waveform. Recreated per recording.
    private(set) var levels: AsyncStream<Float> = AsyncStream { _ in }

    private var chunkContinuation: AsyncStream<[Float]>.Continuation?
    /// A stream of 16 kHz mono Float32 sample chunks as they're captured — feeds
    /// the live streaming-preview transcriber. Recreated per recording.
    private(set) var sampleChunks: AsyncStream<[Float]> = AsyncStream { _ in }

    // MARK: - Permission

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Lifecycle

    /// Placeholder for engine warm-up. We deliberately do NOT call
    /// `engine.prepare()` here: preparing before a microphone/input device is
    /// available throws an AVFoundation exception. Warm-up happens on first
    /// `start()`, by which point mic permission has been granted.
    func prewarm() {}

    func start() throws {
        // Bail cleanly if there's no input device (e.g. no mic / permission not
        // yet granted) rather than letting AVAudioEngine assert and crash.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioError.noInputDevice
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        isRunning = true
        lock.unlock()

        levels = AsyncStream { continuation in
            self.levelContinuation = continuation
        }
        sampleChunks = AsyncStream { continuation in
            self.chunkContinuation = continuation
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            isRunning = false
            throw AudioError.noInputDevice
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        try engine.start()
        Log.audio.info("Audio engine started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    /// Stop and return the captured 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelContinuation?.finish()
        chunkContinuation?.finish()
        lock.lock()
        isRunning = false
        let captured = samples
        lock.unlock()
        Log.audio.info("Captured \(captured.count) samples (\(Double(captured.count) / 16_000.0, format: .fixed(precision: 2)) s)")
        return captured
    }

    func discard() {
        _ = stop()
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // MARK: - Tap handling

    private func handle(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.audio.error("Convert failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let channel = out.floatChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        var chunk = [Float](repeating: 0, count: frames)
        for i in 0..<frames { chunk[i] = channel[i] }

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        // Hand the freshly converted chunk to the live streaming preview.
        chunkContinuation?.yield(chunk)

        // RMS → normalized level for the waveform.
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (frames > 0) ? (sum / Float(frames)).squareRoot() : 0
        let level = min(1, rms * 12)
        levelContinuation?.yield(level)
    }
}

enum AudioError: Error {
    case noInputDevice
}
