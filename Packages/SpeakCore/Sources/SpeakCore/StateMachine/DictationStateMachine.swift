import Foundation

/// Recording mode: whether the user is holding the key or has locked hands-free.
public enum RecordingMode: Equatable, Sendable {
    case hold
    case locked
}

/// Which async stage of processing is in flight.
public enum ProcessingPhase: Equatable, Sendable {
    case transcribing
    case formatting
    case inserting
}

/// A transient, self-dismissing user notice.
public enum Notice: Equatable, Sendable {
    case noSpeech
    case copiedToClipboard(reason: String)
    case error(String)
}

/// The observable state of the dictation pipeline.
public enum DictationState: Equatable, Sendable {
    case idle
    /// A secure input field (e.g. password) has the focus; the hotkey is disarmed.
    case blockedSecureInput
    /// Actively capturing audio. `minHoldPassed` distinguishes a real hold from a
    /// quick tap that might be the first half of a double-tap lock.
    case recording(RecordingMode, minHoldPassed: Bool)
    /// A short tap just ended; waiting briefly to see if a second press locks
    /// hands-free mode. Audio keeps capturing during this window.
    case awaitingLockTap
    case processing(ProcessingPhase)
    case notice(Notice)

    public var isRecording: Bool {
        if case .recording = self { return true }
        if case .awaitingLockTap = self { return true }
        return false
    }

    public var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    /// True once dictation has "committed" (past the grace window) — i.e. we're
    /// actively recording for real or processing. Drives audio pause + overlay.
    public var isCommitted: Bool {
        switch self {
        case .recording(_, let passed): return passed
        case .processing: return true
        default: return false
        }
    }

    /// Whether the Flow Bar overlay should be visible. Now shown during the
    /// provisional window too (as an "arming" progress bar), plus committed
    /// recording, processing, and notices. Hidden only when idle/blocked.
    public var showsOverlay: Bool {
        switch self {
        case .recording, .processing, .notice: return true
        default: return false
        }
    }

    /// True during the pre-commit grace window — the overlay shows a filling
    /// progress bar here instead of the waveform.
    public var isArming: Bool {
        if case .recording(_, false) = self { return true }
        return false
    }
}

/// Inputs to the state machine. Timing-derived events (`minHoldElapsed`,
/// `lockWindowElapsed`, `maxDurationReached`, `noticeExpired`) are produced by
/// timers the coordinator schedules in response to effects, keeping the reducer
/// free of any clock.
public enum DictationEvent: Equatable, Sendable {
    case optionDown
    case optionUp
    case escPressed
    /// A non-Option key was pressed while Option was physically held — the user
    /// meant Option as a modifier (⌥←, ⌥e, ⌥⇥), not dictation.
    case otherKeyWhileOptionHeld
    case minHoldElapsed
    case lockWindowElapsed
    case maxDurationReached
    case noticeExpired
    /// Capture stopped and VAD reported whether any speech was present.
    case captureFinished(hasSpeech: Bool)
    case transcriptReady(String)
    case transcriptFailed
    case formatReady(String)
    case insertFinished
    case insertFailed
    case secureInputChanged(Bool)
}

/// Side effects for the coordinator to execute. The reducer never performs I/O.
public enum Effect: Equatable, Sendable {
    case startCapture
    /// Stop the audio engine, run VAD, then feed back `captureFinished`.
    case stopCapture
    case stopCaptureDiscard
    case scheduleMinHoldTimer
    case scheduleLockWindowTimer
    case cancelLockWindowTimer
    case transcribe
    case format(String)
    case insert(String, viaClipboard: Bool)
    case cancelWork
    case rescueToClipboard
    case persist
    case scheduleNoticeDismiss
    /// Let the triggering key event reach the frontmost app (Option-as-modifier).
    case passThroughModifier
    case playStartSound
    case playStopSound
}

/// Tunable timings; timers themselves live in the coordinator.
public struct DictationTimings: Equatable, Sendable {
    /// Grace period: Option must be held alone this long before dictation
    /// "commits" (plays a sound, shows the overlay, pauses audio). If another key
    /// is pressed within it, the whole thing is a silent no-op — this is what
    /// keeps Option-based shortcuts (e.g. Raycast) from conflicting. A release
    /// within it instead opens the double-tap window.
    public var minHold: TimeInterval
    /// How long to wait for a second press to lock hands-free.
    public var lockWindow: TimeInterval
    /// Hard cap on a single dictation.
    public var maxDuration: TimeInterval
    /// How long a notice stays on screen.
    public var noticeDuration: TimeInterval

    public init(minHold: TimeInterval = 0.5,
                lockWindow: TimeInterval = 0.30,
                maxDuration: TimeInterval = 300,
                noticeDuration: TimeInterval = 1.2) {
        self.minHold = minHold
        self.lockWindow = lockWindow
        self.maxDuration = maxDuration
        self.noticeDuration = noticeDuration
    }

    public static let `default` = DictationTimings()
}

/// The pure, deterministic dictation reducer. Holds `state` plus the small amount
/// of ambient context the transitions need (`secureInputActive`). Every branch is
/// exercised by the test suite.
public struct DictationStateMachine: Sendable {
    public private(set) var state: DictationState
    public private(set) var secureInputActive: Bool

    public init(state: DictationState = .idle, secureInputActive: Bool = false) {
        self.state = state
        self.secureInputActive = secureInputActive
    }

    /// Apply an event, mutate `state`, and return the effects to run.
    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> [Effect] {
        // Secure-input changes are handled uniformly regardless of state.
        if case let .secureInputChanged(active) = event {
            return handleSecureInputChange(active)
        }

        switch state {
        case .idle:
            return handleIdle(event)
        case .blockedSecureInput:
            return handleBlocked(event)
        case let .recording(mode, minHoldPassed):
            return handleRecording(mode: mode, minHoldPassed: minHoldPassed, event: event)
        case .awaitingLockTap:
            return handleAwaitingLockTap(event)
        case let .processing(phase):
            return handleProcessing(phase: phase, event: event)
        case .notice:
            return handleNotice(event)
        }
    }

    // MARK: - Per-state handlers

    private mutating func handleSecureInputChange(_ active: Bool) -> [Effect] {
        secureInputActive = active
        switch state {
        case .idle where active:
            state = .blockedSecureInput
            return []
        case .blockedSecureInput where !active:
            state = .idle
            return []
        default:
            // Mid-recording/processing: keep going; the flag reroutes insertion.
            return []
        }
    }

    private mutating func handleIdle(_ event: DictationEvent) -> [Effect] {
        switch event {
        case .optionDown:
            // Provisional: capture silently, no feedback yet — feedback waits for
            // the grace period so a quick Option+key combo stays a no-op.
            state = .recording(.hold, minHoldPassed: false)
            return [.startCapture, .scheduleMinHoldTimer]
        default:
            return []
        }
    }

    private mutating func handleBlocked(_ event: DictationEvent) -> [Effect] {
        // Disarmed: swallow nothing, do nothing until secure input clears.
        _ = event
        return []
    }

    private mutating func handleRecording(mode: RecordingMode, minHoldPassed: Bool, event: DictationEvent) -> [Effect] {
        switch (mode, event) {
        case (.hold, .minHoldElapsed):
            // Grace elapsed with Option still held alone → commit: now we make
            // noise, show the overlay, and pause other audio.
            state = .recording(.hold, minHoldPassed: true)
            return [.playStartSound]

        case (.hold, .optionUp):
            if minHoldPassed {
                // Genuine hold-and-release → transcribe.
                state = .processing(.transcribing)
                return [.stopCapture, .playStopSound]
            } else {
                // Quick tap → maybe the first half of a double-tap lock.
                state = .awaitingLockTap
                return [.scheduleLockWindowTimer]
            }

        case (.hold, .otherKeyWhileOptionHeld):
            if minHoldPassed {
                // Already committed to dictation — ignore stray keys so a
                // fat-finger doesn't kill a real recording.
                return []
            }
            // Within the grace window: Option was a modifier (Raycast etc.).
            // Silently abandon and let the combo through — no sound, no overlay.
            state = .idle
            return [.stopCaptureDiscard, .passThroughModifier]

        case (.locked, .optionDown):
            // A press in locked mode stops dictation.
            state = .processing(.transcribing)
            return [.stopCapture, .playStopSound]

        case (_, .escPressed):
            state = .idle
            return [.stopCaptureDiscard]

        case (_, .maxDurationReached):
            state = .processing(.transcribing)
            return [.stopCapture, .playStopSound]

        default:
            return []
        }
    }

    private mutating func handleAwaitingLockTap(_ event: DictationEvent) -> [Effect] {
        switch event {
        case .optionDown:
            // Second press within the window → lock hands-free. Audio continues.
            // This is the commit point for the double-tap gesture.
            state = .recording(.locked, minHoldPassed: true)
            return [.cancelLockWindowTimer, .playStartSound]
        case .lockWindowElapsed:
            // No second press → treat the brief hold as a dictation; VAD may say no-speech.
            state = .processing(.transcribing)
            return [.stopCapture]
        case .escPressed:
            state = .idle
            return [.stopCaptureDiscard]
        case .maxDurationReached:
            state = .processing(.transcribing)
            return [.stopCapture]
        default:
            return []
        }
    }

    private mutating func handleProcessing(phase: ProcessingPhase, event: DictationEvent) -> [Effect] {
        switch event {
        case .escPressed:
            state = .idle
            return [.cancelWork]

        case let .captureFinished(hasSpeech) where phase == .transcribing:
            if hasSpeech {
                return [.transcribe]
            } else {
                state = .notice(.noSpeech)
                return [.scheduleNoticeDismiss]
            }

        case let .transcriptReady(text) where phase == .transcribing:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .notice(.noSpeech)
                return [.scheduleNoticeDismiss]
            }
            state = .processing(.formatting)
            return [.format(trimmed)]

        case .transcriptFailed where phase == .transcribing:
            state = .notice(.error("Transcription failed"))
            return [.scheduleNoticeDismiss]

        case let .formatReady(text) where phase == .formatting:
            state = .processing(.inserting)
            return [.insert(text, viaClipboard: secureInputActive)]

        case .insertFinished where phase == .inserting:
            state = .idle
            return [.persist]

        case .insertFailed where phase == .inserting:
            state = .notice(.error("Couldn't insert — text copied to clipboard"))
            return [.rescueToClipboard, .scheduleNoticeDismiss]

        default:
            return []
        }
    }

    private mutating func handleNotice(_ event: DictationEvent) -> [Effect] {
        switch event {
        case .noticeExpired:
            state = secureInputActive ? .blockedSecureInput : .idle
            return []
        case .optionDown where !secureInputActive:
            // Start a new (provisional) dictation, dismissing the notice.
            state = .recording(.hold, minHoldPassed: false)
            return [.startCapture, .scheduleMinHoldTimer]
        default:
            return []
        }
    }
}
