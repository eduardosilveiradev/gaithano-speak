import Testing
import Foundation
@testable import SpeakCore

// MARK: - Mode selection

@Suite("Talk mode selection")
struct TalkModeTests {
    /// Holding Control after Option upgrades the utterance already in flight rather
    /// than starting a second one — the user can't press both keys simultaneously.
    @Test("Control mid-recording upgrades the in-flight utterance to Talk")
    func upgradesInFlight() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        #expect(m.mode == .dictate)

        let effects = m.handle(.talkModifierEngaged)
        #expect(m.mode == .talk)
        // The upgrade is pure bookkeeping: capture is already running.
        #expect(effects.isEmpty)
        #expect(m.state == .recording(.hold, minHoldPassed: false))
    }

    @Test("Talk transcripts go to the model instead of the formatter")
    func talkPathAnswers() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed)
        m.handle(.talkModifierEngaged)
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))

        let effects = m.handle(.transcriptReady("what does this error mean"))
        #expect(effects == [.answer("what does this error mean")])
        #expect(m.state == .processing(.answering))
        // The panel opens with the first token, not after the full answer.
        #expect(m.hasAnswer)

        m.handle(.answerReady)
        #expect(m.state == .answerPresented)
        #expect(m.hasAnswer)
        #expect(m.state.showsOverlay)
    }

    /// Releasing Control while still speaking must not silently turn a question back
    /// into dictation — the answer would get typed into the user's document.
    @Test("The upgrade is sticky once engaged")
    func upgradeIsSticky() {
        var m = DictationStateMachine()
        m.handle(.optionDown)
        m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        #expect(m.mode == .talk)
        #expect(m.handle(.transcriptReady("hi")) == [.answer("hi")])
    }

    @Test("Dictation without Control still formats and inserts")
    func dictateUnaffected() {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        let effects = m.handle(.transcriptReady("hello"))
        #expect(effects == [.format("hello"), .endTalkThread])
        #expect(m.state == .processing(.formatting))
    }

    @Test("An empty Talk transcript notices rather than asking the model")
    func emptyTalkTranscript() {
        var m = DictationStateMachine()
        // `.minHoldElapsed` before release, or the early-release path parks the
        // machine in hands-free `.awaitingLockTap` instead of transcribing.
        m.handle(.optionDown); m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        let effects = m.handle(.transcriptReady("   "))
        #expect(effects == [.scheduleNoticeDismiss])
        #expect(m.state == .notice(.noSpeech))
    }
}

// MARK: - Threading

@Suite("Talk threading")
struct TalkThreadingTests {
    /// A follow-up keeps the conversation *and* the panel: the panel-open press must
    /// tear neither down, because at that moment we don't yet know if Control is
    /// coming — and if it is, the user is asking about what's on screen.
    @Test("Asking again from the panel preserves the thread and the answer")
    func followUpKeepsThread() {
        var m = presentedAnswer()
        let effects = m.handle(.optionDown)
        #expect(effects == [.startCapture, .scheduleMinHoldTimer])
        #expect(!effects.contains(.endTalkThread))
        #expect(!effects.contains(.hideAnswerPanel))
        #expect(m.hasAnswer)
        #expect(m.state == .recording(.hold, minHoldPassed: false))

        // Control arrives behind it → still Talk, thread intact.
        m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        #expect(m.handle(.transcriptReady("why?")) == [.answer("why?")])
    }

    /// The mirror case: dictating from an open panel drops the thread, so the next
    /// Talk question starts fresh instead of inheriting stale history.
    @Test("Dictating from the panel drops the thread")
    func dictatingDropsThread() {
        var m = presentedAnswer()
        m.handle(.optionDown)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        let effects = m.handle(.transcriptReady("some dictated text"))
        #expect(effects.contains(.endTalkThread))
        // The panel survives the question but not the answer: once we know this was
        // dictation, the text goes to the app and the panel has no reason to stay.
        #expect(effects.contains(.hideAnswerPanel))
        #expect(!m.hasAnswer)
        #expect(m.mode == .dictate)
    }

    /// Pressing the key while reading and saying nothing must not replace the answer
    /// with a "no speech" pill — the user would lose what they were looking at.
    @Test("An abandoned follow-up returns to the answer instead of a notice")
    func abandonedFollowUpKeepsAnswer() {
        var m = presentedAnswer()
        m.handle(.optionDown); m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        #expect(m.handle(.captureFinished(hasSpeech: false)).isEmpty)
        #expect(m.state == .answerPresented)
        #expect(m.hasAnswer)
    }

    @Test("Esc mid-follow-up drops the question, keeps the answer")
    func escMidFollowUpKeepsAnswer() {
        var m = presentedAnswer()
        m.handle(.optionDown); m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        #expect(m.state == .processing(.transcribing))
        let effects = m.handle(.escPressed)
        #expect(effects == [.cancelWork])
        #expect(m.state == .answerPresented)
    }

    /// Option is also a modifier. Hitting ⌥← while reading should move the caret,
    /// not tear the answer down.
    @Test("An Option shortcut while reading leaves the answer up")
    func modifierShortcutKeepsAnswer() {
        var m = presentedAnswer()
        m.handle(.optionDown)
        let effects = m.handle(.otherKeyWhileOptionHeld)
        #expect(effects == [.stopCaptureDiscard, .passThroughModifier])
        #expect(m.state == .answerPresented)
        #expect(m.hasAnswer)
    }

    @Test("Esc closes the panel and ends the thread")
    func escEndsThread() {
        var m = presentedAnswer()
        let effects = m.handle(.escPressed)
        #expect(effects == [.hideAnswerPanel, .endTalkThread])
        #expect(m.state == .idle)
    }

    @Test("A failed answer tears down the panel and the thread")
    func answerFailure() {
        var m = DictationStateMachine()
        // `.minHoldElapsed` before release, or the early-release path parks the
        // machine in hands-free `.awaitingLockTap` instead of transcribing.
        m.handle(.optionDown); m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("q"))
        let effects = m.handle(.answerFailed("model timed out"))
        #expect(effects == [.hideAnswerPanel, .scheduleNoticeDismiss, .endTalkThread])
        #expect(m.state == .notice(.error("model timed out")))
    }

    /// A machine parked in `.answerPresented`.
    private func presentedAnswer() -> DictationStateMachine {
        var m = DictationStateMachine()
        // `.minHoldElapsed` before release, or the early-release path parks the
        // machine in hands-free `.awaitingLockTap` instead of transcribing.
        m.handle(.optionDown); m.handle(.talkModifierEngaged)
        m.handle(.minHoldElapsed); m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("first question"))
        m.handle(.answerReady)
        return m
    }
}

// MARK: - Stream parsing

@Suite("Stream chunk parsing")
struct StreamChunkParserTests {
    @Test("Skips blanks, comments, and the DONE sentinel")
    func skipsNonPayload() {
        #expect(StreamChunkParser.payload(fromSSELine: "") == nil)
        #expect(StreamChunkParser.payload(fromSSELine: ": keep-alive") == nil)
        #expect(StreamChunkParser.payload(fromSSELine: "data: [DONE]") == nil)
        #expect(StreamChunkParser.payload(fromSSELine: "event: message") == nil)
        #expect(StreamChunkParser.payload(fromSSELine: #"data: {"a":1}"#) == #"{"a":1}"#)
    }

    @Test("Reads OpenAI-style deltas")
    func openAIDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        #expect(StreamChunkParser.openAIDelta(fromSSELine: line) == "Hello")
        // The opening chunk carries a role and no content.
        let roleOnly = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        #expect(StreamChunkParser.openAIDelta(fromSSELine: roleOnly) == nil)
    }

    /// This is the shape actually returned by `gemini-3.5-flash` on Vertex.
    @Test("Reads Gemini deltas")
    func geminiDelta() {
        let line = #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"pong"}]}}]}"#
        #expect(StreamChunkParser.geminiDelta(fromSSELine: line) == "pong")
    }

    /// Two thought shapes were seen live; neither may reach the answer panel.
    @Test("Drops thought parts and thought signatures")
    func dropsThoughts() {
        let tagged = #"data: {"candidates":[{"content":{"parts":[{"text":"scratch","thought":true}]}}]}"#
        #expect(StreamChunkParser.geminiDelta(fromSSELine: tagged) == nil)

        // The real trailing chunk, observed even with thinkingBudget: 0.
        let signed = #"data: {"candidates":[{"content":{"parts":[{"text":"","thoughtSignature":"AY89a1"}]},"finishReason":"STOP"}]}"#
        #expect(StreamChunkParser.geminiDelta(fromSSELine: signed) == nil)

        // A mixed chunk keeps only the answer text.
        let mixed = #"data: {"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"42"}]}}]}"#
        #expect(StreamChunkParser.geminiDelta(fromSSELine: mixed) == "42")
    }

    @Test("Extracts error messages from both Vertex body shapes")
    func errorMessages() {
        let dict = #"{"error":{"code":403,"message":"Permission denied"}}"#.data(using: .utf8)!
        #expect(StreamChunkParser.errorMessage(fromBody: dict) == "Permission denied")

        // Vertex sometimes wraps the error object in a top-level array.
        let array = #"[{"error":{"code":404,"message":"Model not found"}}]"#.data(using: .utf8)!
        #expect(StreamChunkParser.errorMessage(fromBody: array) == "Model not found")

        #expect(StreamChunkParser.errorMessage(fromBody: Data("not json".utf8)) == nil)
    }
}

// MARK: - Prompting

@Suite("Talk prompt builder")
struct TalkPromptBuilderTests {
    @Test("The vision note appears only when a screenshot rides along")
    func visionNote() {
        let textOnly = TalkPromptBuilder.systemPrompt(for: .none)
        #expect(!textOnly.contains(TalkPromptBuilder.visionNote))

        let withImage = TalkContext(screenshotJPEG: Data([0xFF, 0xD8]))
        #expect(TalkPromptBuilder.systemPrompt(for: withImage).contains(TalkPromptBuilder.visionNote))
    }

    @Test("Selected text is quoted, not inlined with the question")
    func quotesSelection() {
        let context = TalkContext(selectedText: "func foo() {}", frontmostAppName: "Xcode")
        let turn = TalkPromptBuilder.userTurn(question: "what does this do", context: context)
        #expect(turn.contains("<<<func foo() {}>>>"))
        #expect(turn.contains("Xcode"))
        #expect(turn.contains("Question: what does this do"))
    }

    @Test("A runaway selection is capped")
    func capsSelection() {
        let huge = String(repeating: "x", count: 10_000)
        let turn = TalkPromptBuilder.userTurn(question: "q", context: TalkContext(selectedText: huge))
        #expect(turn.count < TalkPromptBuilder.maxSelectedTextChars + 500)
    }

    @Test("Only the newest turn carries context")
    func threadAppends() {
        let prior = [TalkTurn(role: .user, text: "first"),
                     TalkTurn(role: .assistant, text: "answer")]
        let thread = TalkPromptBuilder.thread(priorTurns: prior,
                                              question: "follow up",
                                              context: TalkContext(selectedText: "sel"))
        #expect(thread.count == 3)
        #expect(thread[0].text == "first")
        #expect(thread[1].text == "answer")
        #expect(thread[2].text.contains("<<<sel>>>"))
    }
}

// MARK: - Settings

@Suite("Talk settings")
struct TalkSettingsTests {
    @Test("Talk settings round-trip through the store")
    func roundTrip() {
        let defaults = UserDefaults(suiteName: "talk-settings-test")!
        defaults.removePersistentDomain(forName: "talk-settings-test")
        let store = SettingsStore(defaults: defaults)

        var settings = AppSettings.default
        settings.talkProvider = .localServer
        settings.talkModel = "gemma-4-e4b-it-mlx"
        settings.vertexProjectID = "my-project"
        settings.talkVisionEnabled = true
        settings.talkThinkingBudget = 512
        store.save(settings)

        #expect(store.load() == settings)
    }

    /// A settings blob written by a build that had a since-removed enum case must not
    /// wipe every other preference — `controlOption` was exactly this case.
    @Test("An unknown enum value falls back without discarding other settings")
    func unknownEnumIsLenient() throws {
        let json = """
            {"hotkey":"controlOption","localServerModel":"custom-model","playSounds":false}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)

        #expect(decoded.hotkey == AppSettings.default.hotkey)   // fell back
        #expect(decoded.localServerModel == "custom-model")     // survived
        #expect(decoded.playSounds == false)                    // survived
    }

    @Test("Vertex config resolves an empty project to nil so ADC can supply it")
    func configResolution() {
        var settings = AppSettings.default
        settings.vertexProjectID = ""
        settings.vertexRegion = ""
        let config = settings.talkConfig
        #expect(config.projectID == nil)
        #expect(config.region == "global")
        #expect(config.model == "gemini-3.6-flash")
        #expect(config.thinkingBudget == 0)
    }

    /// Bumping the default in `init` is invisible to anyone with saved settings — the
    /// whole struct is persisted, so the old default comes back out of the store.
    /// A value the user typed themselves must survive untouched.
    @Test("A saved superseded model id is upgraded, a custom one is not")
    func supersededModelUpgrades() {
        let defaults = UserDefaults(suiteName: "superseded-model-test")!
        defaults.removePersistentDomain(forName: "superseded-model-test")
        let store = SettingsStore(defaults: defaults)

        var settings = AppSettings.default
        settings.talkModel = "gemini-3.5-flash"
        settings.localServerModel = "gemma-2-2b"   // deliberately pinned
        store.save(settings)

        let loaded = store.load()
        #expect(loaded.talkModel == "gemini-3.6-flash")
        #expect(loaded.localServerModel == "gemma-2-2b")
    }

    /// The Vertex formatter is gone, but its raw value is still sitting in the saved
    /// JSON of anyone who selected it. They chose a cloud model over the on-device
    /// one; dropping them back to `.foundationModel` would silently undo that choice.
    @Test("A saved Vertex formatter choice migrates to the Claude CLI")
    func vertexFormatterMigratesToClaude() {
        let defaults = UserDefaults(suiteName: "vertex-formatter-migration-test")!
        defaults.removePersistentDomain(forName: "vertex-formatter-migration-test")
        let store = SettingsStore(defaults: defaults)

        var settings = AppSettings.default
        settings.preferredFormatter = .vertexGemini
        store.save(settings)

        #expect(store.load().preferredFormatter == .claude)
    }

    /// Only that one value moves — a formatter the user picked for itself is theirs.
    @Test("Other formatter choices survive the migration untouched")
    func otherFormattersSurviveMigration() {
        let defaults = UserDefaults(suiteName: "formatter-migration-noop-test")!
        defaults.removePersistentDomain(forName: "formatter-migration-noop-test")
        let store = SettingsStore(defaults: defaults)

        for formatter in [FormatterID.foundationModel, .localServer, .deterministic, .claude] {
            var settings = AppSettings.default
            settings.preferredFormatter = formatter
            store.save(settings)
            #expect(store.load().preferredFormatter == formatter)
        }
    }
}
