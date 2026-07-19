import Foundation
import Carbon.HIToolbox

/// Polls `IsSecureEventInputEnabled()` (true while a password field is focused).
/// While secure input is on, key events don't reach taps and inserting into the
/// field is wrong — so we disarm and surface a "secure input" state instead.
@MainActor
final class SecureInputWatcher {
    private var timer: Timer?
    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let now = IsSecureEventInputEnabled()
        if now != isActive {
            isActive = now
            onChange?(now)
        }
    }
}
