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
        #expect(effects == [.format("hello world this is a test")])

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
        #expect(fail == [.scheduleNoticeDismiss])
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
