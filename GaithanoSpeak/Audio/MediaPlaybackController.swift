import Cocoa

/// Pauses other apps' media playback while we're listening, and resumes it after.
///
/// macOS 26 restricts the private MediaRemote framework's now-playing reads AND
/// commands to Apple-signed binaries, so a third-party app can neither query play
/// state nor send a targeted pause. What DOES work (with Accessibility, which we
/// already hold for text insertion) is synthesizing the hardware Play/Pause media
/// key — browsers (YouTube Music), Music.app, Spotify, etc. all respond to it.
///
/// The play/pause key is a blind toggle, so if we send it when NOTHING is playing
/// it doesn't pause — it *starts* playback (macOS happily launches Apple Music).
/// To avoid that we gate on CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// for the default output device (this read isn't restricted): only toggle if some
/// app is actually driving the speakers, and only resume if we actually paused.
@MainActor
final class MediaPlaybackController {
    private var didToggle = false
    private let monitor = SystemAudioMonitor()
    private var pendingPause: Task<Void, Never>?
    /// Bumped whenever the dictation this decision belonged to is over, so a
    /// warm-up still in flight knows to drop it rather than pause after the fact.
    private var generation = 0

    /// How long we'll keep asking the tap before concluding nothing is playing.
    ///
    /// This exists because `minHold` now defaults to 0. The pause decision used to
    /// land half a second after `beginMonitoring()`, which was plenty for a Core
    /// Audio process tap to hand over its first buffer; with instant start it lands
    /// on the very next hop, when the tap is still cold and reads a flat 0 —
    /// indistinguishable from silence, and below the threshold, so nothing ever
    /// paused. Waiting for a real reading is the fix; bounding the wait, and
    /// cancelling it when the dictation ends, is what keeps it from pausing music
    /// after the user already stopped talking.
    private static let warmUpBudget = Duration.milliseconds(700)
    private static let pollInterval = Duration.milliseconds(20)
    /// Enough buffers to trust a quiet reading. One could be a gap between tracks.
    private static let samplesToTrustSilence = 4

    /// NX_KEYTYPE_PLAY — the play/pause media key.
    private let playPauseKey: Int32 = 16

    var isAvailable: Bool { true }

    /// Start measuring system output level ahead of time (e.g. when recording
    /// begins) so the level is warm by the time we decide whether to pause. Prompts
    /// for the audio-capture permission on first call.
    func beginMonitoring() { monitor.start() }

    func endMonitoring() {
        cancelPendingPause()
        monitor.stop()
    }

    /// Pause when dictation starts — but ONLY if audio is genuinely playing. We use
    /// the real output level (Core Audio tap), not the device's "is running" flag,
    /// because a just-paused browser keeps the device warm and would fool the flag
    /// into un-pausing already-paused media. If the tap is unavailable/denied, its
    /// level stays 0 and we simply don't pause (safe).
    func pauseIfPlaying() {
        guard !didToggle, pendingPause == nil else { return }
        if toggleIfPlaying() { return }     // tap already warm (back-to-back dictation)

        let gen = generation
        pendingPause = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.warmUpBudget)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                if self.toggleIfPlaying() { break }
                // A quiet reading only means silence once the tap has actually been
                // feeding us; before that it just means "not started yet".
                if self.monitor.sampleCount >= Self.samplesToTrustSilence { break }
            }
            guard let self, self.generation == gen else { return }
            self.pendingPause = nil
            if !self.didToggle {
                Log.audio.info("""
                    No playback detected; not toggling media \
                    (level \(self.monitor.level, privacy: .public), \
                    samples \(self.monitor.sampleCount, privacy: .public))
                    """)
            }
        }
    }

    /// Toggle playback back on when dictation ends — only if we toggled it off.
    func resumeIfPaused() {
        cancelPendingPause()
        guard didToggle else { return }
        didToggle = false
        sendPlayPauseKey()
        Log.audio.info("Sent media play/pause (resume)")
    }

    /// Send the key if — and only if — the tap says something is genuinely playing.
    @discardableResult
    private func toggleIfPlaying() -> Bool {
        let lvl = monitor.level
        guard lvl > SystemAudioMonitor.playingThreshold else { return false }
        sendPlayPauseKey()
        didToggle = true
        Log.audio.info("Sent media play/pause (listening), level \(lvl, privacy: .public)")
        return true
    }

    private func cancelPendingPause() {
        generation &+= 1
        pendingPause?.cancel()
        pendingPause = nil
    }

    // MARK: - Media key synthesis

    private func sendPlayPauseKey() {
        postAux(down: true)
        postAux(down: false)
    }

    /// Post an NSSystemDefined aux-key event for the play/pause media key. This is
    /// the canonical encoding used by media-key utilities; it needs Accessibility.
    private func postAux(down: Bool) {
        let flags: UInt = down ? 0xA00 : 0xB00
        let data1 = Int((playPauseKey << 16) | ((down ? 0xA : 0xB) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,               // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
