import Foundation
import Observation
import SpeakCore

/// Tracks model readiness/download progress for the UI (onboarding + menu).
///
/// FluidAudio's `downloadAndLoad` doesn't surface byte-level progress, so instead
/// of a fake percentage we poll the on-disk model cache and report megabytes
/// downloaded — an honest, always-moving signal.
@MainActor
@Observable
final class ModelManager {
    enum Status: Equatable {
        case notLoaded
        case downloading(megabytes: Int)
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .notLoaded
    let engine: any TranscriptionEngine

    /// Where FluidAudio caches the Parakeet v3 model files.
    private static let modelCacheDir: URL? = {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }()

    init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// Kick off preparation. Safe to call repeatedly; no-op once ready/in-flight.
    func prepareIfNeeded() async {
        switch status {
        case .ready, .downloading, .loading: return
        default: break
        }
        status = .downloading(megabytes: diskMegabytes())

        // Poll disk usage so the UI shows real, moving progress during download,
        // then flip to "loading" for the (lengthy, ~30s) first-run CoreML/ANE
        // compile that happens after the bytes are all on disk.
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .downloading = self.status {
                    let mb = self.diskMegabytes()
                    if mb > 50 && !self.hasPartialFiles() {
                        self.status = .loading   // download done; CoreML compiling
                    } else {
                        self.status = .downloading(megabytes: mb)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        do {
            try await engine.prepare { _ in }
            poller.cancel()
            status = .ready
        } catch {
            poller.cancel()
            Log.engine.error("Model prepare failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Current size of the model cache directory, in megabytes.
    private func diskMegabytes() -> Int {
        guard let dir = Self.modelCacheDir,
              let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total / 1_000_000
    }

    /// True while any file is still mid-download (FluidAudio uses `.partial`).
    private func hasPartialFiles() -> Bool {
        guard let dir = Self.modelCacheDir,
              let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in e where url.pathExtension == "partial" {
            return true
        }
        return false
    }
}

