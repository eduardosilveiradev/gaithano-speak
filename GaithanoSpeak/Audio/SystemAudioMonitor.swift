import CoreAudio
import AudioToolbox
import Foundation

/// Measures the *actual* output level of everything else playing on the system, via
/// a macOS 14.4+ Core Audio process tap. This is what lets us tell REAL playback
/// from a paused-but-still-warm audio device — the device's "is running" flag can't.
///
/// We read only a running RMS level; no audio is ever recorded or stored. Needs the
/// `NSAudioCaptureUsageDescription` permission (prompts on first `start()`). If the
/// user denies it the tap yields silence, so `level` stays 0 and the media-pause
/// feature simply never fires — a safe degradation, never a wrong un-pause.
final class SystemAudioMonitor: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    private let lock = NSLock()
    private var _level: Float = 0
    private var _running = false

    /// Most recent output RMS (0…~1). Thread-safe.
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }

    /// Above this RMS we consider audio to be genuinely playing. Empirically well
    /// above the noise floor of a silent-but-active device (which reads ~0).
    static let playingThreshold: Float = 0.0015

    func start() {
        lock.lock(); let already = _running; lock.unlock()
        guard !already else { return }

        // Tap everything except our own process, so our start/stop UI sounds don't
        // count as "audio playing".
        let excluded = Self.ownAudioObject().map { [$0] } ?? []
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Gaithano Speak output level"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted            // never mute the real output

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != kAudioObjectUnknown else {
            Log.audio.error("SystemAudioMonitor: tap creation failed")
            return
        }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GaithanoSpeakLevelMon",
            kAudioAggregateDeviceUIDKey: "com.gaithano.speak.levelmon",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var agg = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr, agg != 0 else {
            Log.audio.error("SystemAudioMonitor: aggregate device failed")
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            return
        }
        aggID = agg

        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil) { [weak self] _, inInput, _, _, _ in
            guard let self else { return }
            let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            var sum: Float = 0
            var count = 0
            for buf in bufs {
                guard let data = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let p = data.assumingMemoryBound(to: Float.self)
                var i = 0
                while i < n { let s = p[i]; sum += s * s; i += 1 }
                count += n
            }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            self.lock.lock()
            // Short peak-hold so momentary gaps between callbacks don't read as silence.
            self._level = max(rms, self._level * 0.7)
            self.lock.unlock()
        }
        guard status == noErr, let pid else {
            Log.audio.error("SystemAudioMonitor: IOProc failed")
            teardown()
            return
        }
        procID = pid
        AudioDeviceStart(aggID, pid)
        lock.lock(); _running = true; lock.unlock()
        Log.audio.info("SystemAudioMonitor started")
    }

    func stop() {
        teardown()
        lock.lock(); _level = 0; _running = false; lock.unlock()
    }

    private func teardown() {
        if aggID != 0, let pid = procID {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
        }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    /// Translate our own PID to its Core Audio process object so we can exclude it.
    private static func ownAudioObject() -> AudioObjectID? {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }
}
