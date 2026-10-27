import AppKit
import SwiftUI

/// AppKit-side lifecycle. Owns the environment and starts monitors once the app
/// finishes launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon; menu bar only (also set via LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        environment.startMonitoring()
        environment.prepareModels()

        if environment.shouldAutoShowOnboarding {
            OnboardingWindow.show(environment: environment)
        }
    }

    /// Normal termination takes the conversation's screenshots and tool log with it.
    /// A crash can't, which is why `startMonitoring` also purges at launch.
    func applicationWillTerminate(_ notification: Notification) {
        let scratch = environment.coordinator.agentScratch
        // Blocking on the way out is the point: after this returns the process is gone,
        // and an async cleanup would simply not happen.
        let done = DispatchSemaphore(value: 0)
        Task.detached { await scratch.purgeAll(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
