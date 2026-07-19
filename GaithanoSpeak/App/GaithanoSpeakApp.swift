import SwiftUI
import AppKit
import SpeakCore

@main
struct GaithanoSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(environment: delegate.environment)
        } label: {
            menuLabel
        }
        .menuBarExtraStyle(.menu)
    }

    /// The Gaithano mark normally; a recording/processing cue while active.
    @ViewBuilder private var menuLabel: some View {
        switch delegate.environment.coordinator.state {
        case .recording:
            Image(systemName: "mic.fill")
        case .processing:
            Image(systemName: "waveform")
        default:
            if let img = Self.menuLogo {
                Image(nsImage: img)
            } else {
                Image(systemName: "mic")
            }
        }
    }

    /// Menu-bar logo, loaded once as a TEMPLATE image so macOS tints it for the
    /// light/dark menu bar. Sized to the standard status-item glyph height.
    private static let menuLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo-menubar", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

/// The menu shown from the status item.
struct MenuContent: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        Group {
            Text(statusLine)

            Divider()

            Button("Settings…") {
                WindowManager.present(id: "settings", title: "Gaithano Speak — Settings",
                                      size: NSSize(width: 460, height: 420)) {
                    SettingsView(environment: environment)
                }
            }
            Button("History…") {
                environment.refreshHistory()
                WindowManager.present(id: "history", title: "Gaithano Speak — History",
                                      size: NSSize(width: 560, height: 520)) {
                    HistoryView(environment: environment)
                }
            }
            Button("Personal Dictionary…") {
                environment.refreshDictionary()
                WindowManager.present(id: "dictionary", title: "Gaithano Speak — Dictionary",
                                      size: NSSize(width: 460, height: 440)) {
                    DictionaryEditorView(environment: environment)
                }
            }

            Divider()

            if environment.needsOnboarding {
                Button("Finish Setup…") {
                    OnboardingWindow.show(environment: environment)
                }
            }

            Button("About Gaithano Speak") {
                WindowManager.present(id: "about", title: "About",
                                      size: NSSize(width: 380, height: 260)) {
                    AboutView()
                }
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var statusLine: String {
        switch environment.modelManager.status {
        case .ready: return "Hold \(environment.settings.hotkey.displayName) to talk"
        case .downloading(let mb): return "Downloading model… \(mb) MB"
        case .loading: return "Loading model…"
        case .failed: return "Model failed to load"
        case .notLoaded: return "Preparing…"
        }
    }
}
