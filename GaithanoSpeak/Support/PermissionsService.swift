import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// Central view of the TCC grants the app needs and helpers to request them.
@MainActor
enum PermissionsService {

    // MARK: Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility (event tap + posting events + AX)

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility. macOS shows its own dialog and opens System
    /// Settings; we can only poll `AXIsProcessTrusted()` afterwards.
    static func promptAccessibility() {
        // Use the literal key to avoid referencing the non-concurrency-safe global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Deep-link to keyboard settings for the "Press 🌐 to: Do Nothing" guidance.
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording, needed only for Talk's optional vision context. Not part of
    /// `allEssentialGranted` — dictation works fine without it.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system prompt. Returns whether access was already granted; macOS
    /// only shows the prompt once per app, and the grant needs a relaunch to take
    /// effect, so callers should treat `false` as "ask the user to check Settings".
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static var allEssentialGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
