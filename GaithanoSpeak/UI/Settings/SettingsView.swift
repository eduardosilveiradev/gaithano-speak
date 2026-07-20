import SwiftUI
import SpeakCore

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var serverTest: String?
    @State private var needsScreenRecording = false

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: bind(\.hotkey)) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                if environment.settings.hotkey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, and turn off the double-press Dictation shortcut so they don’t collide.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Hands-free lock (double-tap)", isOn: bind(\.handsFreeEnabled))
                Toggle("Play start/stop sounds", isOn: bind(\.playSounds))
                Toggle("Pause other audio while listening", isOn: bind(\.pauseAudioWhileListening))
                Text("Sends the play/pause media key (needs Accessibility). Only fires when audio is actually playing, so it won’t start music when nothing was on.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Dictation starts the instant you press the key. The trade-off: Option combos like ⌥← or Raycast’s shortcuts will also start one — tap esc, or just let it transcribe nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Engine", selection: bind(\.engine)) {
                    Text(EngineID.parakeet.displayName).tag(EngineID.parakeet)
                }
                .disabled(true)
                statusRow
            }

            Section("Formatting") {
                Toggle("Clean up transcripts", isOn: bind(\.formattingEnabled))
                Picker("Formatter", selection: bind(\.preferredFormatter)) {
                    Text(FormatterID.foundationModel.displayName).tag(FormatterID.foundationModel)
                    Text(FormatterID.localServer.displayName).tag(FormatterID.localServer)
                    Text(FormatterID.deterministic.displayName).tag(FormatterID.deterministic)
                }
                .disabled(!environment.settings.formattingEnabled)
                if environment.settings.preferredFormatter == .foundationModel && !FoundationModelFormatter.isAvailable() {
                    Text("Apple Intelligence is off or unavailable — falling back to basic cleanup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if environment.settings.preferredFormatter == .localServer {
                    localServerFields
                }
            }

            Section("Talk") {
                Toggle("Hold Control while speaking to ask a model", isOn: bind(\.talkEnabled))
                Text("⌃⌥ instead of ⌥: your words go to a model and the answer appears in a panel instead of being typed. ⌘C copies it, ⌘↩ inserts it, esc closes.")
                    .font(.caption).foregroundStyle(.secondary)

                if environment.settings.talkEnabled {
                    Picker("Provider", selection: bind(\.talkProvider)) {
                        ForEach(TalkProviderID.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    if environment.settings.talkProvider == .vertexGemini {
                        vertexFields
                    }
                    Toggle("Send a screenshot of the focused window", isOn: bind(\.talkVisionEnabled))
                        .onChange(of: environment.settings.talkVisionEnabled) { _, enabled in
                            // Ask up front rather than at the moment of the first
                            // question — the prompt would otherwise interrupt speech.
                            if enabled && !PermissionsService.requestScreenRecording() {
                                needsScreenRecording = true
                            }
                        }
                    Text(visionCaption)
                        .font(.caption).foregroundStyle(.secondary)
                    if needsScreenRecording && !PermissionsService.screenRecordingGranted {
                        HStack {
                            Text("Screen Recording isn't granted yet.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Settings") { PermissionsService.openScreenRecordingSettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(newValue)
                        environment.updateSetting(\.launchAtLogin, newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }

    @ViewBuilder private var vertexFields: some View {
        TextField("Model", text: bind(\.talkModel))
            .textFieldStyle(.roundedBorder)
        TextField("GCP project (blank = your gcloud default)", text: bind(\.vertexProjectID))
            .textFieldStyle(.roundedBorder)
        if GoogleCredentials.isConfigured {
            Label(credentialsCaption, systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("No gcloud credentials found — run `gcloud auth application-default login` in Terminal. Until then, Talk falls back to your local server.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var credentialsCaption: String {
        guard let project = GoogleCredentials.defaultProjectID else {
            return "Signed in with gcloud."
        }
        return "Signed in with gcloud (project \(project))."
    }

    /// Vision is the one setting here that changes what leaves the machine, so the
    /// caption says so plainly rather than burying it.
    private var visionCaption: String {
        if !environment.settings.talkVisionEnabled {
            return "Off: only your spoken question and any selected text are sent."
        }
        let destination = environment.settings.talkProvider.isCloud
            ? "uploaded to Google"
            : "sent to your local server"
        return "An image of whatever window you're in is \(destination) with each new question. Requires the Screen Recording permission."
    }

    @ViewBuilder private var localServerFields: some View {
        TextField("Server URL", text: bind(\.localServerURL))
            .textFieldStyle(.roundedBorder)
        TextField("Model (blank = whatever’s loaded)", text: bind(\.localServerModel))
            .textFieldStyle(.roundedBorder)
        HStack {
            Button("Test connection") { testServer() }
            if let serverTest { Text(serverTest).font(.caption).foregroundStyle(.secondary) }
        }
        Text("Runs on your GPU via LM Studio (:1234) or Ollama (:11434) — fast, private, uncensored. Load a small instruct model and put its id above. Falls back to basic cleanup if the server is unreachable.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func testServer() {
        serverTest = "Checking…"
        let raw = environment.settings.localServerURL
        guard let base = TextRepair.normalizedOpenAIBase(raw),
              let url = URL(string: base + "/models") else {
            serverTest = "Invalid URL"; return
        }
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard code == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    serverTest = "Reachable, but no model list (HTTP \(code))"; return
                }
                let ids = models.compactMap { $0["id"] as? String }
                serverTest = ids.isEmpty ? "Connected — no models loaded" : "Connected — \(ids.count) model(s)"
            } catch {
                serverTest = "Unreachable — is the server running?"
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch environment.modelManager.status {
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .downloading(let mb):
            HStack { ProgressView().controlSize(.small); Text("Downloading… \(mb) MB") }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading model…") }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .notLoaded:
            Button("Download model") { environment.prepareModels() }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { environment.settings[keyPath: keyPath] },
            set: { environment.updateSetting(keyPath, $0) }
        )
    }
}
