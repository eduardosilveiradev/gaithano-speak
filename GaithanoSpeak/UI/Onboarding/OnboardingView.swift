import SwiftUI
import SpeakCore

enum OnboardingWindow {
    @MainActor
    static func show(environment: AppEnvironment) {
        WindowManager.present(id: "onboarding", title: "Welcome to Gaithano Speak",
                              size: NSSize(width: 520, height: 560)) {
            OnboardingView(environment: environment)
        }
    }
}

struct OnboardingView: View {
    @Bindable var environment: AppEnvironment
    @State private var micGranted = PermissionsService.microphoneGranted
    @State private var axGranted = PermissionsService.accessibilityGranted
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Gaithano Speak").font(.title2.weight(.semibold))
                Text("Three permissions and one model download, then hold your key and talk.")
                    .foregroundStyle(.secondary).font(.callout)
            }

            step(number: 1, title: "Microphone", granted: micGranted,
                 detail: "So it can hear you while you hold the key.") {
                Button("Grant") {
                    Task { micGranted = await PermissionsService.requestMicrophone() }
                }
            }

            step(number: 2, title: "Accessibility", granted: axGranted,
                 detail: "So it can detect your hotkey and type text into other apps.") {
                Button("Open Settings") {
                    PermissionsService.promptAccessibility()
                    PermissionsService.openAccessibilitySettings()
                }
            }

            step(number: 3, title: "Speech model", granted: environment.modelManager.isReady,
                 detail: "One-time on-device download (Parakeet).") {
                modelControl
            }

            step(number: 4, title: "Keyboard tip", granted: nil,
                 detail: "If you pick the 🌐/Fn key, set it to “Do Nothing” so it doesn’t open emoji or Dictation.") {
                Button("Open Keyboard Settings") { PermissionsService.openKeyboardSettings() }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    environment.completeOnboarding()
                    WindowManager.close(id: "onboarding")
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(micGranted && axGranted))
            }
        }
        .padding(28)
        .frame(width: 520, height: 560)
        .onAppear(perform: startPolling)
        .onDisappear {
            pollTimer?.invalidate()
            // Closed with permissions in place (Done or the window's X) → never
            // auto-pop again. If permissions are still missing we leave it unset so
            // the essential setup can resurface on the next launch.
            if micGranted && axGranted { environment.completeOnboarding() }
        }
    }

    @ViewBuilder private var modelControl: some View {
        switch environment.modelManager.status {
        case .ready:
            EmptyView()
        case .downloading(let mb):
            HStack { ProgressView().controlSize(.small); Text("\(mb) MB") }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading…") }
        case .failed:
            Button("Retry") { environment.prepareModels() }
        case .notLoaded:
            Button("Download") { environment.prepareModels() }
        }
    }

    private func step<Control: View>(number: Int, title: String, granted: Bool?,
                                     detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(.quaternary).frame(width: 28, height: 28)
                if granted == true {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.caption.weight(.bold))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted != true { control() }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                micGranted = PermissionsService.microphoneGranted
                axGranted = PermissionsService.accessibilityGranted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
