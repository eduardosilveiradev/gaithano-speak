import Foundation

/// Recording mode: whether the user is holding the key or has locked hands-free.
public enum RecordingMode: Equatable, Sendable {
    case hold
    case locked
}

/// What this utterance is FOR. Ambient per-utterance state rather than part of
/// `DictationState`: capture is identical either way, and the two only diverge once
/// there's a transcript. Keeping it out of the state payload means every existing
/// dictation transition stays untouched.
public enum UtteranceMode: Equatable, Sendable {
    /// Plain Option — transcribe, format, insert at the cursor.
    case dictate
    /// Control+Option — transcribe, ask a model, show the answer in a panel.
    case talk
    /// Control+Shift+Option — transcribe, then let the model act on the screen.
    ///
    /// A strict upgrade of `.talk`: same capture, same panel, but the model gets
    /// tools. It is a separate mode rather than a flag on `.talk` because the
    /// difference is not cosmetic — one reads the screen, the other changes it.
    case agent
    /// Control+Option, when the user has pointed that gesture at Claude Code —
    /// transcribe, then type the words into the terminal running a Claude Code
    /// session and (optionally) submit them.
    ///
    /// No model of ours ever sees the text, so there is no answer, no panel, and no
    /// thread: this mode's whole job is to deliver the utterance somewhere else and
    /// get out of the way. It takes the same gesture as `.talk`/`.agent` because it
    /// is the same intent — "this sentence is for a model, not for the cursor" — just
    /// with a different model on the other end.
    case handoff
}

/// Which async stage of processing is in flight.
public enum ProcessingPhase: Equatable, Sendable {
    case transcribing
    case formatting
    case inserting
    /// Talk only: a provider is streaming an answer.
    case answering
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
    /// Talk only: an answer is on screen, waiting to be read. Persists until Esc or
    /// the next utterance — deliberately NOT self-dismissing like `.notice`, since
    /// the user needs however long it takes to read it.
    case answerPresented
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
    /// recording, processing, notices, and a presented answer. Hidden only when
    /// idle/blocked.
    public var showsOverlay: Bool {
        switch self {
        case .recording, .processing, .notice, .answerPresented: return true
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
    /// The Claude Code handoff couldn't deliver. Separate from `.insertFailed` only
    /// so the reason reaches the user: "no session found" is fixable and "couldn't
    /// insert" isn't, and they arrive by the same door.
    case handoffFailed(String)
    case secureInputChanged(Bool)
    /// Control joined Option — this utterance is a Talk question, not dictation.
    /// May arrive at `optionDown` (Control already held) or mid-capture (Control
    /// pressed after Option). Sticky: releasing Control does not revert it.
    case talkModifierEngaged
    /// Shift joined Control+Option — this utterance is an agent task. Sticky in the
    /// same way, and one-directional: an utterance can be upgraded to `.agent` but
    /// never downgraded back to `.talk`, so letting go of Shift mid-sentence can't
    /// quietly turn an approved action run into something else.
    case agentModifierEngaged
    /// Control joined Option and the user has pointed that gesture at Claude Code.
    /// Sticky like the other two, and it outranks them: the coordinator only emits
    /// one of the three, but the reducer refuses the demotion anyway so an ordering
    /// change upstream can't quietly turn a handoff into an agent run.
    case handoffModifierEngaged
    /// A provider finished streaming an answer. The answer text itself never passes
    /// through the reducer — it streams onto the coordinator, like `livePartial`.
    case answerReady
    case answerFailed(String)
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
    /// Ask the configured Talk provider, streaming the answer into the panel.
    case answer(String)
    /// Hand the transcript to the agent runner, which will act on the screen.
    case runAgent(String)
    /// Type the transcript into the terminal running Claude Code. Carries the raw
    /// transcript; the coordinator cleans it on the way out — see
    /// `RecordingCoordinator.handOff(_:)` for why the model formatter is skipped.
    case handOffToClaudeCode(String)
    /// Take the answer panel off screen (visual only — the thread survives, so a
    /// follow-up question can continue the conversation).
    case hideAnswerPanel
    /// Discard the conversation thread. Emitted when a Talk session genuinely ends:
    /// Esc, a failure, or the user switching back to plain dictation.
    case endTalkThread
}

/// Tunable timings; timers themselves live in the coordinator.
public struct DictationTimings: Equatable, Sendable {
    /// Grace period: Option must be held alone this long before dictation
    /// "commits" (plays a sound, shows the overlay, pauses audio). If another key
    /// is pressed within it, the whole thing is a silent no-op — this is what
    /// keeps Option-based shortcuts (e.g. Raycast) from conflicting. A release
    /// within it instead opens the double-tap window.
    ///
    /// Zero means commit instantly, which is the current default: the half-second
    /// wait was the most-felt latency in the app. The trade is real and deliberate —
    /// at zero there is no window in which a combo can be recognised as a combo, so
    /// ⌥-shortcuts start a dictation. Raise it to restore that protection.
    public var minHold: TimeInterval
    /// How long to wait for a second press to lock hands-free.
    public var lockWindow: TimeInterval
    /// Hard cap on a single dictation.
    public var maxDuration: TimeInterval
    /// How long a notice stays on screen.
    public var noticeDuration: TimeInterval

    public init(minHold: TimeInterval = 0,
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
    /// What the in-flight (or just-finished) utterance is for. Set at capture start
    /// and upgraded by `.talkModifierEngaged`; read when the transcript lands to
    /// decide between the dictation and Talk paths.
    public private(set) var mode: UtteranceMode
    /// Whether the answer panel is on screen. Deliberately wider than
    /// `.answerPresented` at both ends: it goes up the moment we start answering (the
    /// panel shows "Thinking…" and then streams into it) and it stays up through a
    /// follow-up recording, so the user can still see what they're following up on.
    /// Kept in sync with the `.hideAnswerPanel` effect via `dismissAnswer()` — never
    /// set it directly.
    public private(set) var hasAnswer: Bool

    public init(state: DictationState = .idle,
                secureInputActive: Bool = false,
                mode: UtteranceMode = .dictate,
                hasAnswer: Bool = false) {
        self.state = state
        self.secureInputActive = secureInputActive
        self.mode = mode
        self.hasAnswer = hasAnswer
    }

    /// Tear the answer panel down. Returns the effect so the flag and the effect can
    /// never drift apart — every `.hideAnswerPanel` in this file comes from here.
    /// Empty when nothing is on screen, so plain dictation doesn't emit a no-op.
    private mutating func dismissAnswer() -> [Effect] {
        guard hasAnswer else { return [] }
        hasAnswer = false
        return [.hideAnswerPanel]
    }

    /// Apply an event, mutate `state`, and return the effects to run.
    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> [Effect] {
        // Secure-input changes are handled uniformly regardless of state.
        if case let .secureInputChanged(active) = event {
            return handleSecureInputChange(active)
        }

        // The Talk upgrade is likewise state-agnostic: it only matters that an
        // utterance is in flight, not which phase it's in.
        if case .talkModifierEngaged = event {
            // Never demote an already-upgraded utterance: Control and Shift arrive as
            // separate events, so a Control that lands after Shift must not undo it.
            if state.isRecording, mode != .agent, mode != .handoff { mode = .talk }
            return []
        }
        if case .agentModifierEngaged = event {
            // Handoff outranks the agent. The coordinator emits only one of these, so
            // this can't fire today — it's here so that stops being load-bearing.
            if state.isRecording, mode != .handoff { mode = .agent }
            return []
        }
        if case .handoffModifierEngaged = event {
            if state.isRecording { mode = .handoff }
            return []
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
        case .answerPresented:
            return handleAnswerPresented(event)
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
            // Every utterance starts as dictation; `.talkModifierEngaged` upgrades it.
            mode = .dictate
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
            // An open answer stays open; using a shortcut while reading shouldn't
            // dismiss what you're reading.
            state = hasAnswer ? .answerPresented : .idle
            return [.stopCaptureDiscard, .passThroughModifier]

        case (.locked, .optionDown):
            // A press in locked mode stops dictation.
            state = .processing(.transcribing)
            return [.stopCapture, .playStopSound]

        case (_, .escPressed):
            // Backing out of a follow-up returns to the answer rather than idle.
            state = hasAnswer ? .answerPresented : .idle
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
            state = hasAnswer ? .answerPresented : .idle
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
            // Cancelling mid-answer tears down the panel and the conversation.
            if phase == .answering {
                state = .idle
                return [.cancelWork] + dismissAnswer() + [.endTalkThread]
            }
            // Cancelling while transcribing a follow-up abandons only that question;
            // the answer the user was reading stays up.
            if hasAnswer {
                state = .answerPresented
                return [.cancelWork]
            }
            state = .idle
            return [.cancelWork]

        case let .captureFinished(hasSpeech) where phase == .transcribing:
            if hasSpeech {
                return [.transcribe]
            } else {
                return abandonUtterance(notice: .noSpeech)
            }

        case let .transcriptReady(text) where phase == .transcribing:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return abandonUtterance(notice: .noSpeech)
            }
            // An ASR model handed silence returns its best short guess, not "". Those
            // guesses are fine to type and never fine to act on, so the gate stops
            // here for the modes that hand the transcript to a model with tools —
            // see `UtteranceGate` for why dictation is exempt.
            if mode != .dictate && !UtteranceGate.isSubstantive(trimmed) {
                return abandonUtterance(notice: .noSpeech)
            }
            // The one place the two modes diverge.
            switch mode {
            case .dictate:
                state = .processing(.formatting)
                // Returning to dictation ends the conversation AND takes the panel
                // down — this utterance was text, not a follow-up.
                return [.format(trimmed)] + dismissAnswer() + [.endTalkThread]
            case .talk:
                // The panel appears now, not at `.answerReady` — it shows "Thinking…"
                // and the answer streams into it.
                hasAnswer = true
                state = .processing(.answering)
                return [.answer(trimmed)]
            case .agent:
                // Shares `.answering` and the panel with Talk: from the reducer's side
                // both are "something long is running and the panel is showing it".
                // What differs is who executes the effect.
                hasAnswer = true
                state = .processing(.answering)
                return [.runAgent(trimmed)]
            case .handoff:
                // Nothing comes back, so this ends like a dictation rather than like a
                // Talk question: `.inserting` → `.insertFinished` → `.persist`. Any
                // answer already on screen goes with it — the user just sent their
                // words somewhere else, and leaving the last one up would suggest it
                // had something to do with this.
                state = .processing(.inserting)
                return [.handOffToClaudeCode(trimmed)] + dismissAnswer() + [.endTalkThread]
            }

        case .transcriptFailed where phase == .transcribing:
            // Unlike no-speech, this is a real failure worth surfacing, so it takes
            // the panel down to show the error rather than silently returning.
            state = .notice(.error("Transcription failed"))
            return dismissAnswer() + [.scheduleNoticeDismiss, .endTalkThread]

        case .answerReady where phase == .answering:
            // Streaming already put the text on screen; just stop being "busy" and
            // let the panel persist until Esc or the next utterance.
            state = .answerPresented
            return []

        case let .answerFailed(reason) where phase == .answering:
            state = .notice(.error(reason))
            return dismissAnswer() + [.scheduleNoticeDismiss, .endTalkThread]

        case let .formatReady(text) where phase == .formatting:
            state = .processing(.inserting)
            return [.insert(text, viaClipboard: secureInputActive)]

        case .insertFinished where phase == .inserting:
            state = .idle
            return [.persist]

        case .insertFailed where phase == .inserting:
            state = .notice(.error("Couldn't insert — text copied to clipboard"))
            return [.rescueToClipboard, .scheduleNoticeDismiss]

        case let .handoffFailed(reason) where phase == .inserting:
            state = .notice(.error("\(reason) — text copied to clipboard"))
            return [.rescueToClipboard, .scheduleNoticeDismiss]

        default:
            return []
        }
    }

    /// An utterance produced nothing usable. With an answer on screen this returns
    /// to it silently — the user pressed the key while reading and said nothing, and
    /// replacing their answer with a "no speech" pill would be a worse outcome than
    /// simply not reacting. Otherwise it shows the notice as usual.
    private mutating func abandonUtterance(notice: Notice) -> [Effect] {
        if hasAnswer {
            state = .answerPresented
            return []
        }
        state = .notice(notice)
        return [.scheduleNoticeDismiss]
    }

    /// An answer is on screen. Esc closes it; a new press starts the next utterance,
    /// which becomes a follow-up if `.talkModifierEngaged` arrives behind it.
    private mutating func handleAnswerPresented(_ event: DictationEvent) -> [Effect] {
        switch event {
        case .escPressed:
            state = secureInputActive ? .blockedSecureInput : .idle
            return dismissAnswer() + [.endTalkThread]

        case .optionDown where !secureInputActive:
            // Deliberately keeps BOTH the panel and the thread: at this instant we
            // can't know whether Control is coming, and if it is, the user is asking
            // about the answer that's on screen — taking it away mid-question would
            // remove the thing they're looking at. The dictate path clears both when
            // the transcript lands instead.
            mode = .dictate
            state = .recording(.hold, minHoldPassed: false)
            return [.startCapture, .scheduleMinHoldTimer]

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
            mode = .dictate
            state = .recording(.hold, minHoldPassed: false)
            return [.startCapture, .scheduleMinHoldTimer]
        default:
            return []
        }
    }
}
