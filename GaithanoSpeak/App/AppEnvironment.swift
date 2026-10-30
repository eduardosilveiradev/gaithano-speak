import Foundation
import AppKit
import Observation
import SpeakCore

/// Owns the long-lived objects and wires them together. One instance for the app.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let engine: FluidAudioEngine
    let modelManager: ModelManager
    let coordinator: RecordingCoordinator

    private let settingsStore = SettingsStore()
    private let hotkeyMonitor = HotkeyMonitor()
    private let secureWatcher = SecureInputWatcher()
    private let overlay = OverlayPanelController()

    // NOTE: no `didSet` here — under the @Observable macro, a stored property's
    // didSet does not reliably fire, so persistence is done explicitly through
    // `applySettings(_:)`. All setting mutations must go through that.
    var settings: AppSettings

    /// The single write path for settings: updates state, persists to disk, and
    /// pushes the change to the coordinator/hotkey.
    func applySettings(_ new: AppSettings) {
        let wasAutoAccepting = settings.dictionaryLearningAutoAccept
        settings = new
        settingsStore.save(new)
        coordinator.updateSettings(new)

        // Turning auto-accept on has to act on the terms already waiting. Otherwise
        // the policy change just filters them out of the suggestion list and they sit
        // there accepted-by-nobody — the user asked for them to be let in.
        if new.dictionaryLearningAutoAccept && !wasAutoAccepting {
            for term in (try? database.pendingLearnedTerms(policy: LearningPolicy(autoAcceptSpelling: false))) ?? [] {
                guard let id = term.id else { continue }
                try? database.acceptLearnedTerm(id: id)
            }
            coordinator.reloadDictionary()
            refreshDictionary()
        }
        refreshLearnedTerms()
    }

    /// Mutate one field and persist. Convenience for SwiftUI bindings.
    func updateSetting<T>(_ keyPath: WritableKeyPath<AppSettings, T>, _ value: T) {
        var copy = settings
        copy[keyPath: keyPath] = value
        applySettings(copy)
    }

    /// Say a sample line with the current voice settings.
    ///
    /// Without this the only way to find out that the Python path is wrong is to ask a
    /// question and notice nothing happened — and a silent voice is indistinguishable
    /// from an answer that failed, which is the worst way to debug either.
    func speakSample() {
        coordinator.speakSample()
    }

    /// Recent dictations for the history view (refreshed on demand).
    var history: [DictationRecord] = []
    var dictionaryEntries: [DictionaryEntry] = []
    /// Terms the learner wants a decision on. Spelling substitutions only —
    /// casing fixes promote themselves and never appear here.
    var learnedSuggestions: [LearnedTerm] = []
    var stats = AggregateStats()

    /// Auto-show the onboarding window only on a genuine first run. Deliberately
    /// NOT gated on `modelManager.isReady` — the model loads asynchronously and is
    /// always "not ready" at cold start, which used to re-pop onboarding every launch.
    var shouldAutoShowOnboarding: Bool {
        !settings.hasCompletedOnboarding
    }

    /// Whether setup is genuinely incomplete (a required permission is missing).
    /// Drives the manual "Finish Setup…" menu item so the flow stays reachable.
    var needsOnboarding: Bool {
        !PermissionsService.allEssentialGranted
    }

    /// Mark onboarding done so it never auto-pops again.
    func completeOnboarding() {
        updateSetting(\.hasCompletedOnboarding, true)
    }

    init() {
        // Database (fall back to in-memory if the disk store can't open).
        let db = (try? AppDatabase.onDisk()) ?? (try! AppDatabase.inMemory())
        self.database = db

        let engine = FluidAudioEngine()
        self.engine = engine
        self.modelManager = ModelManager(engine: engine)

        let loaded = settingsStore.load()
        self.settings = loaded

        self.coordinator = RecordingCoordinator(
            engine: engine,
            database: db,
            hotkeyMonitor: hotkeyMonitor,
            settings: loaded
        )

        wire()
        // The Otto keyboard's dictations arrive here by way of the Otto server.
        DictationSocket.start(coordinator: coordinator)
    }

    private func wire() {
        hotkeyMonitor.onEvent = { [weak self] event in
            // `emit` already dispatches to the main queue before invoking this.
            MainActor.assumeIsolated {
                self?.coordinator.handleHotkey(event)
            }
        }
        hotkeyMonitor.onApprovalEvent = { [weak self] event in
            MainActor.assumeIsolated {
                self?.coordinator.resolveApproval(decision: event.decision)
            }
        }
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.updateAgentPanel()
            self.overlay.update(state: state, level: self.coordinator.audioLevel,
                                partial: self.coordinator.livePartial,
                                arming: self.coordinator.armingProgress,
                                levels: self.coordinator.levelHistory,
                                mode: self.coordinator.mode,
                                answerText: self.coordinator.answerText,
                                showsAnswerPanel: self.coordinator.showsAnswerPanel,
                                history: self.coordinator.talkHistory)
        }
        secureWatcher.onChange = { [weak self] active in
            self?.coordinator.setSecureInput(active)
        }
        coordinator.onLearningChanged = { [weak self] _ in
            guard let self else { return }
            self.refreshDictionary()
            self.refreshLearnedTerms()
        }
        coordinator.reloadDictionary()
        refreshLearnedTerms()
    }

    /// Cheap when nothing changed: the controller compares the transcript it last drew
    /// (`AgentTranscript` is `Equatable`) and only rebuilds the SwiftUI tree on a real
    /// difference, so this is safe to call from the render loop.
    private func updateAgentPanel() {
        overlay.updateAgent(transcript: coordinator.agentTranscript) { [weak self] id, decision in
            self?.coordinator.resolveApproval(id: id, decision: decision)
        }
    }

    /// Start system monitors once permissions are in place.
    func startMonitoring() {
        hotkeyMonitor.start()
        secureWatcher.start()
        // The spec's "delete expired data on the next launch if an earlier shutdown
        // couldn't". A crash mid-run is exactly when screenshots get left on disk, and
        // it is also the case where nothing else will ever come back for them.
        Task { await coordinator.agentScratch.purgeStale() }
        // The conversation's 15-minute clock. One tick a minute is plenty for a
        // fifteen-minute window, and it costs nothing when no agent has ever run.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(60))
                await coordinator.expireAgentConversationIfIdle()
            }
        }
        // Keep the overlay's waveform live by polling the coordinator's level.
        Task { @MainActor in
            while true {
                if coordinator.state.showsOverlay {
                    // 60 fps while the overlay is visible: smooth cursor-follow,
                    // waveform, and arming bar. State transitions still drive show/
                    // hide via onStateChange, so idle can poll lazily.
                    coordinator.pushWaveformSample()
                    updateAgentPanel()
                    overlay.update(state: coordinator.state, level: coordinator.audioLevel,
                                   partial: coordinator.livePartial,
                                   arming: coordinator.armingProgress,
                                   levels: coordinator.levelHistory,
                                   mode: coordinator.mode,
                                   answerText: coordinator.answerText,
                                   showsAnswerPanel: coordinator.showsAnswerPanel,
                                   history: coordinator.talkHistory)
                    try? await Task.sleep(nanoseconds: 16_666_666) // ~60 fps
                } else {
                    // The agent panel outlives the Flow Bar: it stays up through a
                    // finished result and a follow-up, both of which are "idle" here.
                    updateAgentPanel()
                    try? await Task.sleep(nanoseconds: 100_000_000) // idle: light poll
                }
            }
        }
    }

    func prepareModels() {
        Task { await modelManager.prepareIfNeeded() }
        // Best-effort: warm up the separate streaming preview model in the
        // background so the live transcription bubble has ghost text ready.
        coordinator.prepareLivePreview()
    }

    // MARK: - Data actions

    func refreshHistory() {
        history = (try? database.recentDictations()) ?? []
        stats = (try? database.aggregateStats()) ?? AggregateStats()
    }

    func refreshDictionary() {
        dictionaryEntries = (try? database.allDictionaryEntries()) ?? []
    }

    func saveDictionaryEntry(_ entry: DictionaryEntry) {
        try? database.upsert(entry)
        coordinator.reloadDictionary()
        refreshDictionary()
    }

    func deleteDictionaryEntry(id: Int64) {
        try? database.deleteDictionaryEntry(id: id)
        coordinator.reloadDictionary()
        refreshDictionary()
    }

    // MARK: - Learned terms

    func refreshLearnedTerms() {
        learnedSuggestions = (try? database.pendingLearnedTerms(policy: settings.learningPolicy)) ?? []
    }

    func acceptLearnedTerm(id: Int64) {
        try? database.acceptLearnedTerm(id: id)
        coordinator.reloadDictionary()
        refreshDictionary()
        refreshLearnedTerms()
    }

    func dismissLearnedTerm(id: Int64) {
        try? database.dismissLearnedTerm(id: id)
        refreshLearnedTerms()
    }

    /// Throw away everything learning has built, including the entries it promoted.
    /// The user's own dictionary entries are untouched.
    func forgetLearnedTerms() {
        try? database.forgetLearnedTerms()
        coordinator.reloadDictionary()
        refreshDictionary()
        refreshLearnedTerms()
    }

    func deleteDictation(id: Int64) {
        try? database.deleteDictation(id: id)
        refreshHistory()
    }
}
