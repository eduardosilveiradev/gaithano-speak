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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
