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

    /// Lines copied from a live `claude -p --output-format stream-json
    /// --include-partial-messages` run, trimmed to the fields read here.
    @Test("Reads claude CLI text deltas and ignores everything else on the stream")
    func claudeCodeDelta() {
        let text = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Paris."}}}"#
        #expect(StreamChunkParser.claudeCodeDelta(fromJSONLine: text) == "Paris.")

        // A tool call being assembled — the Read of the screenshot — shares the shape.
        let toolInput = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file"}}}"#
        #expect(StreamChunkParser.claudeCodeDelta(fromJSONLine: toolInput) == nil)

        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        #expect(StreamChunkParser.claudeCodeDelta(fromJSONLine: thinking) == nil)

        // The whole assistant message is repeated once the turn ends; taking it as a
        // delta too would double the answer.
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Paris."}]}}"#
        #expect(StreamChunkParser.claudeCodeDelta(fromJSONLine: assistant) == nil)

        #expect(StreamChunkParser.claudeCodeDelta(fromJSONLine: "not json") == nil)
    }

    /// The CLI exits 0 on a failed turn and says so in the body, so the result line —
    /// not the exit status — is what decides whether there's an answer.
    @Test("Reads the claude CLI result line, success and failure")
    func claudeCodeResult() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Paris.\n"}"#
        #expect(StreamChunkParser.claudeCodeResult(fromJSONLine: ok) == .answer("Paris."))

        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"5-hour limit reached"}"#
        #expect(StreamChunkParser.claudeCodeResult(fromJSONLine: failed) == .failed("5-hour limit reached"))

        let empty = #"{"type":"result","subtype":"error_max_turns","is_error":false,"result":""}"#
        #expect(StreamChunkParser.claudeCodeResult(fromJSONLine: empty) == .failed("error_max_turns"))

        let notResult = #"{"type":"system","subtype":"init"}"#
        #expect(StreamChunkParser.claudeCodeResult(fromJSONLine: notResult) == nil)
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

    /// The CLI can't be handed an image, so the note that buys it the Read tool must
    /// appear when — and only when — a screenshot has actually been staged for it.
    @Test("The file vision note tracks the screenshot path, not the vision setting")
    func fileVisionNote() {
        #expect(!TalkPromptBuilder.systemPrompt(forScreenshotAt: nil).contains(TalkPromptBuilder.fileVisionNote))
        #expect(!TalkPromptBuilder.systemPrompt(forScreenshotAt: "").contains(TalkPromptBuilder.fileVisionNote))
        #expect(TalkPromptBuilder.systemPrompt(forScreenshotAt: "/tmp/shot.jpg").contains(TalkPromptBuilder.fileVisionNote))
    }

    @Test("Flattening replays prior turns and ends with the newest question")
    func flattensThread() {
        let thread = [TalkTurn(role: .user, text: "Question: first"),
                      TalkTurn(role: .assistant, text: "an answer"),
                      TalkTurn(role: .user, text: "Question: follow up")]
        let prompt = TalkPromptBuilder.flattenedPrompt(thread: thread)

        #expect(prompt.contains("User: Question: first"))
        #expect(prompt.contains("You: an answer"))
        #expect(prompt.hasSuffix("Question: follow up"))
        // A bare prompt must not mention a screenshot that isn't there.
        #expect(!prompt.contains("Screenshot"))
    }

    @Test("A single-turn prompt is just the question, plus the screenshot path")
    func flattensSingleTurn() {
        let thread = [TalkTurn(role: .user, text: "Question: what is this")]
        #expect(TalkPromptBuilder.flattenedPrompt(thread: thread) == "Question: what is this")

        let withShot = TalkPromptBuilder.flattenedPrompt(thread: thread,
                                                         screenshotPath: "/tmp/shot.jpg")
        #expect(withShot.contains("/tmp/shot.jpg"))
        #expect(withShot.hasSuffix("Question: what is this"))
        // It's passed as a CLI argument: a leading dash would read as a flag.
        #expect(!withShot.hasPrefix("-"))
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

    /// Each provider reads its model from its own field. Handing Vertex's model id to
    /// the claude CLI (or the reverse) fails at the far end, where the only symptom is
    /// a notice and a silent fall-through to the local server.
    @Test("Each provider resolves its own model, and the CLI path travels with it")
    func modelPerProvider() {
        var settings = AppSettings.default
        settings.talkModel = "gemini-3.6-flash"
        settings.talkClaudeModel = "sonnet"
        settings.localServerModel = "gemma-4-e2b-it-mlx"
        settings.formatterClaudePath = "/opt/homebrew/bin/claude"

        settings.talkProvider = .vertexGemini
        #expect(settings.talkConfig.model == "gemini-3.6-flash")
        settings.talkProvider = .claudeCode
        #expect(settings.talkConfig.model == "sonnet")
        #expect(settings.talkConfig.executablePath == "/opt/homebrew/bin/claude")
        settings.talkProvider = .localServer
        #expect(settings.talkConfig.model == "gemma-4-e2b-it-mlx")
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
