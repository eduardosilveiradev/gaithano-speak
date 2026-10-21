import Testing
@testable import SpeakCore

@Suite("Dictation state machine")
struct DictationStateMachineTests {

    // MARK: - Hold-to-talk happy path

    @Test("Clean hold-and-release runs the full pipeline")
    func holdRelease() {
        var m = DictationStateMachine()

        var effects = m.handle(.optionDown)
        #expect(m.state == .recording(.hold, minHoldPassed: false))
        #expect(effects.contains(.startCapture))
        #expect(effects.contains(.scheduleMinHoldTimer))

        effects = m.handle(.minHoldElapsed)
        #expect(m.state == .recording(.hold, minHoldPassed: true))

        effects = m.handle(.optionUp)
        #expect(m.state == .processing(.transcribing))
        #expect(effects.contains(.stopCapture))

        effects = m.handle(.captureFinished(hasSpeech: true))
        #expect(effects == [.transcribe])
        #expect(m.state == .processing(.transcribing))

        effects = m.handle(.transcriptReady("hello world this is a test"))
        #expect(m.state == .processing(.formatting))
        // `.endTalkThread` rides along on every dictate-mode transcript: it is how a
        // Talk thread gets dropped when the user's next utterance is plain dictation.
        #expect(effects == [.format("hello world this is a test"), .endTalkThread])

        effects = m.handle(.formatReady("Hello world, this is a test."))
        #expect(m.state == .processing(.inserting))
        #expect(effects == [.insert("Hello world, this is a test.", viaClipboard: false)])

        effects = m.handle(.insertFinished)
        #expect(m.state == .idle)
        #expect(effects == [.persist])
    }

    // MARK: - Double-tap hands-free lock

    @Test("Quick tap then press locks hands-free")
    func doubleTapLocks() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        // Release before minHold → awaiting the second tap.
        let up = m.handle(.optionUp)
        #expect(m.state == .awaitingLockTap)
        #expect(up == [.scheduleLockWindowTimer])

        let down = m.handle(.optionDown)
        #expect(m.state == .recording(.locked, minHoldPassed: true))
        #expect(down.contains(.cancelLockWindowTimer))
        #expect(down.contains(.playStartSound)) // lock is a commit point

        // A subsequent press stops locked recording.
        let stop = m.handle(.optionDown)
        #expect(m.state == .processing(.transcribing))
        #expect(stop.contains(.stopCapture))
    }

    @Test("Lone quick tap with no second press transcribes what it has")
    func loneTapTranscribes() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        m.handle(.optionUp)
        let elapsed = m.handle(.lockWindowElapsed)
        #expect(m.state == .processing(.transcribing))
        #expect(elapsed == [.stopCapture])
    }

    @Test("Esc stops a locked hands-free session")
    func escStopsLocked() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        m.handle(.optionUp)
        m.handle(.optionDown) // locked
        let esc = m.handle(.escPressed)
        #expect(m.state == .idle)
        #expect(esc == [.stopCaptureDiscard])
    }

    // MARK: - Option-as-modifier passthrough (the critical rule)

    @Test("A key pressed within the grace window silently cancels and passes through")
    func optionModifierPassthrough() {
        var m = DictationStateMachine()
        let down = m.handle(.optionDown)
        // No sound/overlay yet — provisional and silent.
        #expect(!down.contains(.playStartSound))
        let other = m.handle(.otherKeyWhileOptionHeld)
        #expect(m.state == .idle)
        #expect(other.contains(.passThroughModifier))
        #expect(other.contains(.stopCaptureDiscard))
        #expect(!other.contains(.playStopSound)) // silent — nothing "happened"
    }

    @Test("After the grace window commits, stray keys are ignored (don't kill dictation)")
    func modifierAfterCommitIgnored() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        let commit = m.handle(.minHoldElapsed)
        #expect(commit.contains(.playStartSound)) // feedback happens at commit
        #expect(m.state == .recording(.hold, minHoldPassed: true))
        let other = m.handle(.otherKeyWhileOptionHeld)
        #expect(other.isEmpty)
        #expect(m.state == .recording(.hold, minHoldPassed: true)) // still recording
    }

    @Test("Overlay and commit state track the grace window")
    func overlayGating() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        #expect(m.state.showsOverlay == true)   // provisional: shows the arming bar
        #expect(m.state.isArming == true)
        #expect(m.state.isCommitted == false)
        m.handle(.minHoldElapsed)
        #expect(m.state.showsOverlay == true)   // committed: waveform
        #expect(m.state.isArming == false)
        #expect(m.state.isCommitted == true)
    }

    // MARK: - Cancel & escape

    @Test("Esc cancels an active hold")
    func escCancelsHold() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        m.handle(.minHoldElapsed)
        let esc = m.handle(.escPressed)
        #expect(m.state == .idle)
        #expect(esc == [.stopCaptureDiscard])
    }

    @Test("Esc cancels in-flight processing")
    func escCancelsProcessing() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("some words here to format"))
        #expect(m.state == .processing(.formatting))
        let esc = m.handle(.escPressed)
        #expect(m.state == .idle)
        #expect(esc == [.cancelWork])
    }

    // MARK: - No speech

    @Test("VAD-empty capture shows a no-speech notice")
    func noSpeechFromVAD() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        let fin = m.handle(.captureFinished(hasSpeech: false))
        #expect(m.state == .notice(.noSpeech))
        #expect(fin == [.scheduleNoticeDismiss])
        m.handle(.noticeExpired)
        #expect(m.state == .idle)
    }

    @Test("Blank transcript shows a no-speech notice")
    func blankTranscript() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("   \n  "))
        #expect(m.state == .notice(.noSpeech))
    }

    // MARK: - Max duration

    @Test("Max duration auto-stops and transcribes")
    func maxDuration() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed)
        let cut = m.handle(.maxDurationReached)
        #expect(m.state == .processing(.transcribing))
        #expect(cut.contains(.stopCapture))
    }

    // MARK: - Secure input

    @Test("Secure input at idle disarms, clearing re-arms")
    func secureInputIdle() {
        var m = DictationStateMachine()
        m.handle(.secureInputChanged(true))
        #expect(m.state == .blockedSecureInput)
        // Hotkey does nothing while blocked.
        let down = m.handle(.optionDown)
        #expect(m.state == .blockedSecureInput)
        #expect(down.isEmpty)
        m.handle(.secureInputChanged(false))
        #expect(m.state == .idle)
    }

    @Test("Secure input during recording reroutes insertion to the clipboard")
    func secureInputRoutesToClipboard() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed)
        m.handle(.secureInputChanged(true))
        #expect(m.state == .recording(.hold, minHoldPassed: true)) // still recording
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("secret words go here now"))
        let ins = m.handle(.formatReady("Secret words go here now."))
        #expect(ins == [.insert("Secret words go here now.", viaClipboard: true)])
    }

    // MARK: - Insert failure rescue

    @Test("Insert failure copies to clipboard and notifies")
    func insertFailureRescue() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("words that will fail to insert"))
        m.handle(.formatReady("Words that will fail to insert."))
        let fail = m.handle(.insertFailed)
        #expect(fail.contains(.rescueToClipboard))
        if case .notice(.error) = m.state {} else {
            Issue.record("expected an error notice, got \(m.state)")
        }
    }

    // MARK: - Transcription failure

    @Test("Transcription failure surfaces an error notice")
    func transcriptionFailure() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        let fail = m.handle(.transcriptFailed)
        #expect(fail == [.scheduleNoticeDismiss, .endTalkThread])
        if case .notice(.error) = m.state {} else {
            Issue.record("expected an error notice, got \(m.state)")
        }
    }

    // MARK: - Notice → restart

    @Test("Starting a new dictation from a notice restarts capture")
    func restartFromNotice() {
        var m = DictationStateMachine(state: .notice(.noSpeech))
        let down = m.handle(.optionDown)
        #expect(m.state == .recording(.hold, minHoldPassed: false))
        #expect(down.contains(.startCapture))
    }

    // MARK: - Agent mode

    /// Drive a chord press through to a transcript, returning the effects that
    /// transcript produced.
    private func runToTranscript(_ m: inout DictationStateMachine,
                                 down: DictationEvent,
                                 text: String) -> [Effect] {
        m.handle(down)
        m.handle(.minHoldElapsed)
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        return m.handle(.transcriptReady(text))
    }

    @Test("The agent chord runs the whole utterance as an agent task")
    func agentChordRunsTheTask() {
        var m = DictationStateMachine()

        let down = m.handle(.agentDown)
        #expect(m.mode == .agent)
        #expect(m.state == .recording(.hold, minHoldPassed: false))
        #expect(down == [.startCapture, .scheduleMinHoldTimer])

        m.handle(.minHoldElapsed)
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))

        let effects = m.handle(.transcriptReady("open safari and search for tide times"))
        #expect(effects == [.runAgent("open safari and search for tide times")])
        #expect(m.state == .processing(.answering))
        // The panel goes up now and narrates the run, exactly as Talk does.
        #expect(m.hasAnswer)
    }

    @Test("The dictation chord is still dictation")
    func dictationChordStaysDictation() {
        var m = DictationStateMachine()
        let effects = runToTranscript(&m, down: .optionDown, text: "hello world this is a test")
        #expect(m.mode == .dictate)
        #expect(effects.contains(.format("hello world this is a test")))
    }

    /// Parakeet answers a second of room tone with its best short guess. Typing
    /// "Thank you." is fine; handing it to something that clicks is not.
    @Test("Silence artifacts never reach the agent")
    func silenceNeverStartsARun() {
        var m = DictationStateMachine()
        let effects = runToTranscript(&m, down: .agentDown, text: "Thank you.")
        #expect(!effects.contains(.runAgent("Thank you.")))
        #expect(m.state == .notice(.noSpeech))
    }

    @Test("A second agent request replaces the run in flight")
    func agentChordRestartsAnActiveRun() {
        var m = DictationStateMachine()
        _ = runToTranscript(&m, down: .agentDown, text: "open safari")
        #expect(m.state == .processing(.answering))

        let effects = m.handle(.agentDown)
        #expect(effects == [.cancelWork, .startCapture, .scheduleMinHoldTimer])
        #expect(m.state == .recording(.hold, minHoldPassed: false))
        #expect(m.mode == .agent)
        // The panel stays up: the user is correcting a run they can still see.
        #expect(m.hasAnswer)
    }

    /// Dictating into a document while the agent works is an ordinary thing to do,
    /// and it must not silently kill the run.
    @Test("The dictation chord leaves an active agent run alone")
    func dictationChordDoesNotCancelARun() {
        var m = DictationStateMachine()
        _ = runToTranscript(&m, down: .agentDown, text: "open safari")

        #expect(m.handle(.optionDown).isEmpty)
        #expect(m.state == .processing(.answering))
        #expect(m.mode == .agent)
    }

    @Test("Esc cancels an agent run and tears the panel down")
    func escCancelsAnAgentRun() {
        var m = DictationStateMachine()
        _ = runToTranscript(&m, down: .agentDown, text: "open safari")

        let effects = m.handle(.escPressed)
        #expect(effects == [.cancelWork, .hideAnswerPanel, .endTalkThread])
        #expect(m.state == .idle)
        #expect(!m.hasAnswer)
    }

    /// Control is part of the agent chord, so a stray `.talkModifierEngaged` from a
    /// future caller must not quietly turn an action run into a question.
    @Test("An agent utterance is never demoted to Talk")
    func agentIsNeverDemoted() {
        var m = DictationStateMachine()
        m.handle(.agentDown)
        m.handle(.talkModifierEngaged)
        #expect(m.mode == .agent)
    }

    @Test("The agent chord double-taps into hands-free, still as an agent task")
    func agentChordLocks() {
        var m = DictationStateMachine()
        m.handle(.agentDown)
        #expect(m.handle(.optionUp) == [.scheduleLockWindowTimer])
        let down = m.handle(.agentDown)
        #expect(m.state == .recording(.locked, minHoldPassed: true))
        #expect(down.contains(.cancelLockWindowTimer))
        #expect(m.mode == .agent)
    }

    @Test("Secure input disarms the agent chord too")
    func agentChordBlockedBySecureInput() {
        var m = DictationStateMachine()
        m.handle(.secureInputChanged(true))
        #expect(m.state == .blockedSecureInput)
        #expect(m.handle(.agentDown).isEmpty)
        #expect(m.state == .blockedSecureInput)
    }

    // MARK: - Ignored / no-op transitions

    @Test("Stray events in idle are ignored")
    func strayEventsIdle() {
        var m = DictationStateMachine()
        #expect(m.handle(.optionUp).isEmpty)
        #expect(m.handle(.transcriptReady("x")).isEmpty)
        #expect(m.handle(.insertFinished).isEmpty)
        #expect(m.state == .idle)
    }
}
