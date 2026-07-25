import Foundation
import AppKit
import Observation
import SpeakCore

/// The one object that knows the whole pipeline. Owns the pure state machine and
/// executes its effects against real audio, STT, formatting, insertion, and the DB.
@MainActor
@Observable
final class RecordingCoordinator {
    // Observable surface for the overlay + menu bar.
    private(set) var state: DictationState = .idle
    private(set) var audioLevel: Float = 0
    /// Live "ghost text" from the streaming preview model, shown in the overlay's
    /// transcription bubble while the user is still speaking. Empty when idle or
    /// when the preview model isn't available.
    private(set) var livePartial: String = ""
    /// The Talk answer as it streams in, shown in the answer panel. Mirrors the
    /// `livePartial` pattern deliberately: streaming deltas must NOT go through the
    /// reducer — they'd flood it and make its transitions non-deterministic.
    private(set) var answerText: String = ""
    /// Which mode the current (or just-finished) utterance is in, for the overlay.
    private(set) var mode: UtteranceMode = .dictate
    /// Whether the overlay should draw the answer panel. Mirrors the reducer's
    /// `hasAnswer` rather than `state.showsAnswerPanel`, because during a follow-up
    /// the state is `.recording` while the panel must stay on screen.
    private(set) var showsAnswerPanel = false
    /// Earlier turns in this Talk thread, shown beneath the current answer so a
    /// follow-up has visible context. Snapshotted when a question starts rather than
    /// read from `talkThread` live — the thread gains the new answer on completion,
    /// and the panel would then show the current response twice.
    private(set) var talkHistory: [TalkTurn] = []
    /// Whether the in-flight answer has produced its first token. Until it does, the
    /// previous answer stays on screen — a follow-up shouldn't blank the panel it's
    /// asking about, and the first delta is a natural moment to swap.
    private var streamStarted = false

    // Collaborators.
    private var machine = DictationStateMachine()
    private let recorder = AudioRecorder()
    private let engine: any TranscriptionEngine
    private let formatter = FoundationModelFormatter()
    private let localServer = LocalServerFormatter()
    private let deterministic = DeterministicCleanup()
    private let inserter = SmartInserter()
    private let media = MediaPlaybackController()
    private let streaming = StreamingTranscriber()
    private let database: AppDatabase
    private let hotkeyMonitor: HotkeyMonitor
    private let timings = DictationTimings()
    private let credentials = GoogleCredentials()
    /// Computed, not stored: `@Observable` rewrites `lazy` into a computed property
    /// and then rejects it, and a stored initialiser can't reach `credentials`.
    /// Rebuilding is free — the struct holds one reference and the token cache lives
    /// in `GoogleCredentials`, not here.
    private var vertexFormatter: VertexFormatter { VertexFormatter(credentials: credentials) }
    private let localTalk = LocalServerTalkProvider()

    var settings: AppSettings
    private var dictionary = PersonalDictionary()

    // In-flight context.
    private var pendingSamples: [Float] = []
    private var currentRaw = ""
    private var currentFinal = ""
    private var currentFormatter: FormatterID = .deterministic
    /// The model's own edit, captured mid-`format` and consumed at `.persist`.
    ///
    /// It has to be taken *there* and not reconstructed later: the dictionary
    /// post-pass and `TextRepair` both run afterwards, and those are this app's
    /// edits, not the model's. Learning from them would teach the dictionary its
    /// own output.
    private var pendingLearning: (heard: String, written: String)?
    private var recordingStartedAt: Date?
    private var currentDuration: TimeInterval = 0

    // Talk state. The thread survives across questions while the answer panel is
    // open, so follow-ups have history; `.endTalkThread` clears it.
    private var talkThread: [TalkTurn] = []
    private var talkContext: TalkContext = .none
    private var contextTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?

    /// Built lazily, on the first agent run, so the ordinary dictation path never
    /// constructs it. Readable so the overlay can render its step list directly —
    /// mirroring it into a second observable would just be a way to show something
    /// other than what is actually about to happen.
    private(set) var agentRunner: AgentRunner?

    /// The step list to draw, or nil when this utterance isn't an agent one. The
    /// runner is kept between runs, so without the mode check a later Talk answer
    /// would appear underneath the previous run's steps.
    var agentSession: AgentSession? {
        mode == .agent ? agentRunner?.session : nil
    }

    // Cancellable timers / tasks.
    private var minHoldTask: Task<Void, Never>?
    private var lockWindowTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    /// Called after every state change so the UI can react.
    var onStateChange: ((DictationState) -> Void)?

    /// 0→1 progress through the pre-commit grace window, driving the overlay's
    /// "arming" progress bar. Zero outside the provisional window.
    var armingProgress: Double {
        guard case .recording(_, false) = state, let start = recordingStartedAt else { return 0 }
        // A zero grace window commits instantly, so there's no progress to show —
        // and dividing by it would hand the overlay a NaN width.
        guard timings.minHold > 0 else { return 1 }
        return min(1, max(0, Date().timeIntervalSince(start) / timings.minHold))
    }

    /// Rolling history of recent audio levels (oldest → newest) for the scrolling
    /// waveform. Sampled at the overlay's refresh rate via `pushWaveformSample()`.
    private(set) var levelHistory: [Float] = []
    private let waveformBarCount = 32
    private var lastWaveformSampleAt: Date?
    /// Sampling cadence for the waveform, independent of the 60 fps render rate — so
    /// bumping the render rate keeps the same ~2s scroll window (32 bars × ~62 ms).
    private let waveformSampleInterval: TimeInterval = 0.062

    /// Append the current level as one waveform column so the bars scroll left over
    /// time. Throttled to `waveformSampleInterval` even though it's called every
    /// render frame. Cleared whenever we're not recording.
    func pushWaveformSample() {
        guard state.isRecording else {
            if !levelHistory.isEmpty { levelHistory = [] }
            lastWaveformSampleAt = nil
            return
        }
        let now = Date()
        if let last = lastWaveformSampleAt, now.timeIntervalSince(last) < waveformSampleInterval { return }
        lastWaveformSampleAt = now
        var h = levelHistory
        h.append(audioLevel)
        if h.count > waveformBarCount { h.removeFirst(h.count - waveformBarCount) }
        levelHistory = h
    }

    init(engine: any TranscriptionEngine,
         database: AppDatabase,
         hotkeyMonitor: HotkeyMonitor,
         settings: AppSettings) {
        self.engine = engine
        self.database = database
        self.hotkeyMonitor = hotkeyMonitor
        self.settings = settings
        recorder.prewarm()
    }

    // MARK: - External inputs

    func handleHotkey(_ event: HotkeyEvent) {
        switch event {
        case .optionDown: send(.optionDown)
        case .optionUp: send(.optionUp)
        case .otherKeyWhileOptionHeld: send(.otherKeyWhileOptionHeld)
        case .escPressed: send(.escPressed)
        case .talkModifierEngaged:
            guard settings.talkEnabled else { return }
            // Capture what the user is looking at NOW, while they're still speaking,
            // so a screenshot + AX read never shows up in answer latency.
            captureTalkContextIfNeeded()
            send(.talkModifierEngaged)
        case .agentModifierEngaged:
            // Requires both consents: Talk off means the gesture never got as far as
            // a model, and agent off means it stays a question rather than an action —
            // which is the only way to reach plain Talk now that ⌃⌥ arms the agent.
            guard settings.talkEnabled, settings.agentEnabled else { return }
            send(.agentModifierEngaged)
        case .agentConfirm:
            agentRunner?.confirm()
        case .agentAuto:
            agentRunner?.enableAuto()
        case .copyAnswer:
            SmartInserter.copyToClipboard(answerText)
        case .insertAnswer:
            insertAnswerAtCursor()
        }
    }

    func setSecureInput(_ active: Bool) {
        send(.secureInputChanged(active))
    }

    func updateSettings(_ new: AppSettings) {
        settings = new
        hotkeyMonitor.updateChoice(new.hotkey)
    }

    func reloadDictionary() {
        dictionary = (try? database.personalDictionary()) ?? PersonalDictionary()
    }

    /// Kick off the (best-effort) download/load of the streaming preview model.
    /// Safe to call repeatedly; failures leave the live bubble silently disabled.
    func prepareLivePreview() {
        Task { await streaming.prepare() }
    }

    // MARK: - Reducer driver

    private func send(_ event: DictationEvent) {
        let effects = machine.handle(event)
        mode = machine.mode
        showsAnswerPanel = machine.hasAnswer
        let newState = machine.state
        if newState != state {
            let wasCommitted = state.isCommitted
            state = newState
            hotkeyMonitor.setActive(newState.isRecording || newState.isProcessing)
            // While an answer is up, ⌘C / ⌘⏎ / Esc belong to the panel, not to
            // whatever app is underneath.
            hotkeyMonitor.setAnswerPanelPresented(machine.hasAnswer)
            updateMediaPlayback(wasCommitted: wasCommitted, isCommitted: newState.isCommitted)
            // Once we leave the active window (idle/notice/blocked), drop the live
            // preview text so a stale transcript doesn't linger in the bubble, and
            // tear down the output-level tap until the next dictation.
            if !newState.isRecording && !newState.isProcessing {
                livePartial = ""
                media.endMonitoring()
            }
            onStateChange?(newState)
        }
        for effect in effects { run(effect) }
    }

    /// Pause other apps' audio when dictation commits; resume when it ends.
    private func updateMediaPlayback(wasCommitted: Bool, isCommitted: Bool) {
        guard settings.pauseAudioWhileListening else {
            // If the user turned it off mid-session, make sure nothing stays paused.
            media.resumeIfPaused()
            return
        }
        if isCommitted && !wasCommitted {
            media.pauseIfPlaying()
        } else if !isCommitted && wasCommitted {
            media.resumeIfPaused()
        }
    }

    // MARK: - Effect executor

    private func run(_ effect: Effect) {
        switch effect {
        case .startCapture:
            startCapture()
        case .stopCapture:
            stopCapture(discard: false)
        case .stopCaptureDiscard:
            stopCapture(discard: true)
        case .scheduleMinHoldTimer:
            minHoldTask = delay(timings.minHold) { [weak self] in self?.send(.minHoldElapsed) }
        case .scheduleLockWindowTimer:
            lockWindowTask = delay(timings.lockWindow) { [weak self] in self?.send(.lockWindowElapsed) }
        case .cancelLockWindowTimer:
            lockWindowTask?.cancel(); lockWindowTask = nil
        case .transcribe:
            transcribe()
        case let .format(raw):
            // Transcription is done; nothing downstream needs the mic. Resume other
            // apps' audio now rather than making them wait through formatting +
            // insertion. (Idempotent — the leaving-committed resume is a no-op after.)
            media.resumeIfPaused()
            currentRaw = raw
            format(raw)
        case let .insert(text, viaClipboard):
            currentFinal = text
            insert(text, viaClipboard: viaClipboard)
        case .cancelWork:
            workTask?.cancel(); workTask = nil
        case .rescueToClipboard:
            SmartInserter.copyToClipboard(currentFinal.isEmpty ? currentRaw : currentFinal)
        case .persist:
            persist()
        case .scheduleNoticeDismiss:
            noticeTask = delay(timings.noticeDuration) { [weak self] in self?.send(.noticeExpired) }
        case .passThroughModifier:
            break // we never consumed it
        case .playStartSound:
            if settings.playSounds { NSSound(named: "Tink")?.play() }
        case .playStopSound:
            if settings.playSounds { NSSound(named: "Pop")?.play() }
        case let .answer(question):
            // Deliberately *not* resuming here, unlike `.format`. Asking is a thing you
            // wait through and then read; handing the music back the instant the mic
            // closes means it returns while the model is still thinking, and on a short
            // question the quiet window is brief enough to read as "it never paused".
            // The `.answering` → `.answerPresented` transition resumes it instead, so
            // the window covers the whole ask and still can't outlive it.
            currentRaw = question
            answer(question)
        case let .runAgent(task):
            // The agent does resume now, and for the opposite reason: its
            // `.answerPresented` doesn't arrive until the entire run ends — many steps,
            // possibly parked on a confirmation the user hasn't answered. Waiting for
            // that would leave the music off for minutes.
            media.resumeIfPaused()
            currentRaw = task
            runAgent(task)
        case .hideAnswerPanel:
            answerTask?.cancel(); answerTask = nil
            // Taking the panel down ends the run: the step list was the only place the
            // user could see what was happening, so leaving it clicking away behind a
            // closed panel is exactly the thing this feature must never do.
            stopAgent()
            answerText = ""
            streamStarted = false
        case .endTalkThread:
            talkThread = []
            talkHistory = []
            talkContext = .none
            contextTask?.cancel(); contextTask = nil
        }
    }

    // MARK: - Effect implementations

    private func startCapture() {
        cancelTimers()
        pendingSamples = []
        currentRaw = ""; currentFinal = ""
        pendingLearning = nil
        livePartial = ""
        // Pre-fill the waveform buffer so it spans the pill immediately instead of
        // visibly "filling up" like a progress bar.
        levelHistory = Array(repeating: 0, count: waveformBarCount)
        recordingStartedAt = Date()
        // Warm the formatting model NOW, while the user is still speaking, so the
        // on-device LLM is hot (sub-second) by the time we have a transcript instead
        // of paying its ~5–9s cold start after.
        if settings.formattingEnabled && settings.preferredFormatter == .foundationModel {
            formatter.prewarm()
        }
        // Start the output-level tap as early as possible. With `minHold` at 0 the
        // pause decision lands on the very next hop, well before the tap's first
        // buffer, so `MediaPlaybackController` waits for a real reading rather than
        // deciding on a cold 0 — this call only gives it a head start. Prompts for
        // the audio-capture permission on first use.
        if settings.pauseAudioWhileListening {
            media.beginMonitoring()
        }
        do {
            try recorder.start()
        } catch {
            Log.audio.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            send(.transcriptFailed)
            return
        }
        // Pump audio levels into the observable for the waveform.
        let stream = recorder.levels
        levelTask = Task { @MainActor [weak self] in
            for await level in stream {
                self?.audioLevel = level
            }
            self?.audioLevel = 0
        }
        startLivePreview()
        maxDurationTask = delay(timings.maxDuration) { [weak self] in self?.send(.maxDurationReached) }
    }

    /// Feed the recorder's live chunks into the streaming preview model and mirror
    /// its partial transcripts into `livePartial`. The chunk stream finishes when
    /// `recorder.stop()` is called, which ends the loop and flushes the session.
    private func startLivePreview() {
        let chunks = recorder.sampleChunks
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.streaming.begin { [weak self] partial in
                Task { @MainActor in self?.setLivePartial(partial) }
            }
            for await chunk in chunks {
                await self.streaming.append(chunk)
            }
            await self.streaming.end()
        }
    }

    /// Only surface preview text while this utterance is still active; late
    /// callbacks arriving after we've gone idle are dropped.
    private func setLivePartial(_ text: String) {
        guard state.isRecording || state.isProcessing else { return }
        livePartial = text
    }

    private func stopCapture(discard: Bool) {
        minHoldTask?.cancel(); maxDurationTask?.cancel()
        let raw = recorder.stop()
        levelTask?.cancel(); audioLevel = 0
        if let start = recordingStartedAt {
            currentDuration = Date().timeIntervalSince(start)
        }
        if discard {
            pendingSamples = []
            return
        }
        // Energy-based VAD: decide speech + trim silence.
        let vad = VoiceActivity.analyze(raw)
        pendingSamples = vad.trimmed
        send(.captureFinished(hasSpeech: vad.hasSpeech))
    }

    private func transcribe() {
        let samples = pendingSamples
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.engine.transcribe(samples, sampleRate: 16_000)
                if Task.isCancelled { return }
                self.send(.transcriptReady(transcript.text))
            } catch {
                if Task.isCancelled { return }
                Log.engine.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                self.send(.transcriptFailed)
            }
        }
    }

    private func format(_ raw: String) {
        // Read the text around the cursor so the model can merge cleanly.
        let context = AccessibilityContext.focusedTextContext()
        let hints = FormattingHints(vocabulary: dictionary.vocabularyHints,
                                    targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                    precedingText: context.precedingText,
                                    followingText: context.followingText)
        // If the field already contains text, force the model to run (even for tiny
        // utterances that would normally skip it) so the merge/casing is correct.
        let hasSurroundingText = [context.precedingText, context.followingText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty }
        let settings = self.settings
        let dictionary = self.dictionary
        let formatter = self.formatter
        let localServer = self.localServer
        let vertexFormatter = self.vertexFormatter
        let deterministic = self.deterministic

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1. Deterministic dictionary pre-pass.
            var text = dictionary.apply(raw)
            var used: FormatterID = .deterministic

            // Both the Apple on-device model and a local OpenAI-compatible server
            // (LM Studio / Ollama) are "model" formatters that go through the same gate.
            let usesModel = settings.preferredFormatter == .foundationModel
                || settings.preferredFormatter == .localServer
                || settings.preferredFormatter == .vertexGemini

            if settings.formattingEnabled
                && usesModel
                && PromptBuilder.shouldUseModel(for: text, hasSurroundingText: hasSurroundingText)
                && text.count <= PromptBuilder.maxCharsForModel {
                do {
                    let result: FormattedResult
                    if settings.preferredFormatter == .localServer {
                        let config = LocalServerFormatter.Config(endpoint: settings.localServerURL,
                                                                 model: settings.localServerModel)
                        result = try await localServer.format(text, hints: hints, config: config)
                    } else if settings.preferredFormatter == .vertexGemini {
                        let config = VertexFormatter.Config(
                            model: settings.formatterVertexModel,
                            projectID: settings.vertexProjectID.isEmpty ? nil : settings.vertexProjectID,
                            region: settings.vertexRegion)
                        result = try await vertexFormatter.format(text, hints: hints, config: config)
                    } else {
                        result = try await formatter.format(text, hints: hints)
                    }
                    // Snapshot the pair before anything else touches it. `text` here
                    // is still exactly what the model was handed.
                    if settings.dictionaryLearningEnabled {
                        self.pendingLearning = (heard: text, written: result.text)
                    }
                    text = result.text
                    used = result.formatter
                } catch {
                    text = DeterministicCleanup.clean(text)
                    used = .deterministic
                }
            } else if settings.formattingEnabled {
                let result = (try? await deterministic.format(text, hints: hints))
                text = result?.text ?? DeterministicCleanup.clean(text)
                used = .deterministic
            }

            // 2. Dictionary post-pass (the model may re-break replaced terms).
            text = dictionary.apply(text)
            // 3. Safety net: collapse accidental doubled words the model missed.
            text = TextRepair.removeAccidentalDuplicates(text)
            // 4. Spacing at the insertion point.
            if hasSurroundingText {
                // The field is readable and already has text: on the deterministic/
                // short path the model never saw the context, so fix casing here
                // (mid-sentence continuations shouldn't capitalize), then compute the
                // exact leading seam — one space, or none before punctuation.
                if settings.formattingEnabled && used == .deterministic {
                    text = TextRepair.lowercaseContinuationIfMidSentence(text, precedingText: hints.precedingText)
                }
                text = TextRepair.joinAtCursor(text, precedingText: hints.precedingText)
            } else {
                // Can't see the field (empty, or an Electron/web app like Claude
                // Desktop that hides its text): append a trailing space so back-to-
                // back dictations stay separated.
                text = TextRepair.appendSeparatorSpace(text)
            }
            if Task.isCancelled { return }
            self.currentFormatter = used
            self.send(.formatReady(text))
        }
    }

    private func insert(_ text: String, viaClipboard: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if viaClipboard {
                    SmartInserter.copyToClipboard(text)
                } else {
                    try await self.inserter.insert(text)
                }
                self.send(.insertFinished)
            } catch {
                Log.insert.error("Insert failed: \(error.localizedDescription, privacy: .public)")
                self.send(.insertFailed)
            }
        }
    }

    // MARK: - Talk

    /// Read the ambient context — selection, app name, optional screenshot — once per
    /// Talk thread. Follow-ups reuse it: the user is looking at the same thing, and
    /// re-capturing on every question would re-send the image cost each time.
    private func captureTalkContextIfNeeded() {
        guard talkContext == .none, contextTask == nil else { return }
        let wantsVision = settings.talkVisionEnabled
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let selected = AccessibilityContext.selectedText()

        contextTask = Task { @MainActor [weak self] in
            let shot = wantsVision ? await ScreenCapture.screenJPEG() : nil
            guard let self, !Task.isCancelled else { return }
            self.talkContext = TalkContext(selectedText: selected,
                                           frontmostAppName: appName,
                                           screenshotJPEG: shot)
        }
    }

    private func answer(_ question: String) {
        // `answerText` is deliberately left alone — a follow-up keeps the previous
        // answer visible until its own first token arrives.
        streamStarted = false
        talkHistory = talkThread
        // If the screenshot is still being captured, wait for it — but never let a
        // stuck capture hold the answer hostage.
        let pendingContext = contextTask
        let thread = TalkPromptBuilder.thread(priorTurns: talkThread,
                                              question: question,
                                              context: talkContext)
        let settings = self.settings
        let credentials = self.credentials
        let localTalk = self.localTalk

        answerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await pendingContext?.value
            if Task.isCancelled { return }

            // Re-read: the capture task may have landed since `thread` was built.
            let context = self.talkContext
            let request = TalkRequest(thread: thread,
                                      context: context,
                                      systemPrompt: TalkPromptBuilder.systemPrompt(for: context))
            let config = settings.talkConfig

            do {
                let full = try await self.runProvider(request, config: config,
                                                      credentials: credentials,
                                                      local: localTalk)
                if Task.isCancelled { return }
                self.talkThread = thread + [TalkTurn(role: .assistant, text: full)]
                self.answerText = full
                self.send(.answerReady)
            } catch {
                if Task.isCancelled { return }
                let reason = Self.describe(error)
                Log.talk.error("Talk failed: \(reason, privacy: .public)")
                self.send(.answerFailed(reason))
            }
        }
    }

    // MARK: - Agent

    /// Hand the transcript to the agent and let it drive.
    ///
    /// Unlike `answer`, this has no local fallback. The local server has no function
    /// calling, and an agent that can't call tools is not a degraded agent — it's a
    /// model narrating clicks it will never make, at the price of a real run.
    private func runAgent(_ task: String) {
        let runner = agentRunner ?? {
            let created = AgentRunner(model: AgentModel(credentials: credentials,
                                                        config: settings.talkConfig))
            created.onConfirmationChanged = { [weak self] awaiting in
                self?.hotkeyMonitor.setAgentAwaitingConfirmation(awaiting)
            }
            created.onEnded = { [weak self] summary in
                guard let self else { return }
                self.hotkeyMonitor.setAgentAwaitingConfirmation(false)
                self.answerText = summary
                self.send(.answerReady)
            }
            agentRunner = created
            return created
        }()

        answerText = ""
        streamStarted = true   // the panel is showing steps, not a stream to swap in
        runner.start(task: task, autoConfirm: settings.agentAutoConfirm)
    }

    /// Idempotent, and safe to call when nothing is running — every panel-dismissal
    /// path goes through it.
    private func stopAgent() {
        guard let agentRunner else { return }
        agentRunner.stop()
        hotkeyMonitor.setAgentAwaitingConfirmation(false)
    }

    /// Run the configured provider, falling back to the local server when a cloud
    /// provider is unusable — an unconfigured or offline Vertex shouldn't mean no
    /// answer at all, and the local path keeps everything on the machine.
    private func runProvider(_ request: TalkRequest,
                             config: TalkConfig,
                             credentials: GoogleCredentials,
                             local: LocalServerTalkProvider) async throws -> String {
        let onDelta: @Sendable (String) -> Void = { [weak self] delta in
            Task { @MainActor in self?.appendAnswerDelta(delta) }
        }

        guard config.provider == .vertexGemini else {
            return try await local.answer(request, config: config, onDelta: onDelta)
        }

        let vertex = VertexTalkProvider(credentials: credentials)
        do {
            return try await vertex.answer(request, config: config, onDelta: onDelta)
        } catch let error as TalkError where error.isFallbackWorthy {
            Log.talk.notice("Vertex unusable (\(Self.describe(error), privacy: .public)); falling back to the local server")
            // Drop anything the failed attempt streamed so the two don't concatenate.
            streamStarted = false
            var localConfig = config
            localConfig.provider = .localServer
            localConfig.model = settings.localServerModel
            localConfig.endpoint = settings.localServerURL
            return try await local.answer(request, config: localConfig, onDelta: onDelta)
        }
    }

    /// Only surface deltas while this answer is still the live one; late callbacks
    /// from a cancelled request are dropped.
    private func appendAnswerDelta(_ delta: String) {
        guard case .processing(.answering) = state else { return }
        // The first token of a new answer replaces the old one; everything after
        // appends to it.
        if !streamStarted { answerText = ""; streamStarted = true }
        answerText += delta
    }

    /// Insert the answer at the cursor (⌘⏎), then dismiss the panel.
    private func insertAnswerAtCursor() {
        let text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.inserter.insert(text)
            } catch {
                Log.insert.error("Answer insert failed: \(error.localizedDescription, privacy: .public)")
                SmartInserter.copyToClipboard(text)
            }
            self.send(.escPressed)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let talk = error as? TalkError else { return error.localizedDescription }
        switch talk {
        case let .notConfigured(reason): return reason
        case let .unreachable(reason): return "Can't reach the model: \(reason)"
        case let .http(code, message):
            return message.isEmpty ? "Model returned HTTP \(code)" : message
        case .emptyResponse: return "The model returned nothing"
        case .timedOut: return "The model timed out"
        case let .underlying(reason): return reason
        }
    }

    private func persist() {
        let record = DictationRecord(
            createdAt: Date(),
            rawText: currentRaw,
            formattedText: currentFinal,
            durationSec: currentDuration,
            wordCount: DictationStats.wordCount(currentFinal),
            engineID: engine.id.rawValue,
            formatterID: currentFormatter.rawValue
        )
        do { try database.save(record) }
        catch { Log.coordinator.error("Persist failed: \(error.localizedDescription, privacy: .public)") }

        learnFromLastFormat()
    }

    /// Turn the model's corrections into dictionary candidates.
    ///
    /// Deliberately after insertion: the text is already on screen, so the diff, the
    /// write, and the dictionary reload all happen on time the user isn't waiting on.
    private func learnFromLastFormat() {
        guard settings.dictionaryLearningEnabled, let pair = pendingLearning else { return }
        pendingLearning = nil

        let observations = DictionaryLearner.observe(heard: pair.heard, written: pair.written)
        guard !observations.isEmpty else { return }

        let database = self.database
        let policy = settings.learningPolicy
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> LearningOutcome? in
                try? database.learn(from: observations, policy: policy)
            }.value

            guard let self, let outcome, !outcome.isEmpty else { return }
            for entry in outcome.accepted {
                Log.coordinator.info("Learned \(entry.phrase, privacy: .private) → \(entry.replacement, privacy: .private)")
            }
            // A newly promoted entry has to be live for the *next* dictation, so
            // reload here rather than waiting for someone to open Settings.
            if !outcome.accepted.isEmpty { self.reloadDictionary() }
            self.onLearningChanged?(outcome)
        }
    }

    /// Set by `AppEnvironment` so Settings can show what was learned or is waiting.
    var onLearningChanged: ((LearningOutcome) -> Void)?

    // MARK: - Helpers

    private func cancelTimers() {
        minHoldTask?.cancel(); lockWindowTask?.cancel()
        maxDurationTask?.cancel(); noticeTask?.cancel()
    }

    private func delay(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            action()
        }
    }
}
