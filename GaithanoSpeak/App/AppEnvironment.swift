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
        settings = new
        settingsStore.save(new)
        coordinator.updateSettings(new)
    }

    /// Mutate one field and persist. Convenience for SwiftUI bindings.
    func updateSetting<T>(_ keyPath: WritableKeyPath<AppSettings, T>, _ value: T) {
        var copy = settings
        copy[keyPath: keyPath] = value
        applySettings(copy)
    }

    /// Recent dictations for the history view (refreshed on demand).
    var history: [DictationRecord] = []
    var dictionaryEntries: [DictionaryEntry] = []
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
    }

    private func wire() {
        hotkeyMonitor.updateChoice(settings.hotkey)
        hotkeyMonitor.onEvent = { [weak self] event in
            // `emit` already dispatches to the main queue before invoking this.
            MainActor.assumeIsolated {
                self?.coordinator.handleHotkey(event)
            }
        }
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.overlay.update(state: state, level: self.coordinator.audioLevel,
                                partial: self.coordinator.livePartial,
                                arming: self.coordinator.armingProgress,
                                levels: self.coordinator.levelHistory,
                                mode: self.coordinator.mode,
                                answerText: self.coordinator.answerText,
                                showsAnswerPanel: self.coordinator.showsAnswerPanel)
        }
        secureWatcher.onChange = { [weak self] active in
            self?.coordinator.setSecureInput(active)
        }
        coordinator.reloadDictionary()
    }

    /// Start system monitors once permissions are in place.
    func startMonitoring() {
        hotkeyMonitor.start()
        secureWatcher.start()
        // Keep the overlay's waveform live by polling the coordinator's level.
        Task { @MainActor in
            while true {
                if coordinator.state.showsOverlay {
                    // 60 fps while the overlay is visible: smooth cursor-follow,
                    // waveform, and arming bar. State transitions still drive show/
                    // hide via onStateChange, so idle can poll lazily.
                    coordinator.pushWaveformSample()
                    overlay.update(state: coordinator.state, level: coordinator.audioLevel,
                                   partial: coordinator.livePartial,
                                   arming: coordinator.armingProgress,
                                   levels: coordinator.levelHistory,
                                   mode: coordinator.mode,
                                   answerText: coordinator.answerText,
                                   showsAnswerPanel: coordinator.showsAnswerPanel)
                    try? await Task.sleep(nanoseconds: 16_666_666) // ~60 fps
                } else {
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

    func deleteDictation(id: Int64) {
        try? database.deleteDictation(id: id)
        refreshHistory()
    }
}
