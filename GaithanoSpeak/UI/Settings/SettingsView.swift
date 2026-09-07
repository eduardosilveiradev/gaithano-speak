import SwiftUI
import SpeakCore

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var serverTest: String?
    @State private var needsScreenRecording = false
    @State private var speechTestRunning = false

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
                    Text(FormatterID.claude.displayName).tag(FormatterID.claude)
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
                if environment.settings.preferredFormatter == .claude {
                    claudeFormatterFields
                }
            }

            Section("Dictionary") {
                Toggle("Learn terms from corrections", isOn: bind(\.dictionaryLearningEnabled))
                Text("When the formatter fixes the same name or acronym a few times, it becomes a dictionary entry — so the fix happens instantly next time, even on short utterances and when the model isn’t running.")
                    .font(.caption).foregroundStyle(.secondary)

                if environment.settings.dictionaryLearningEnabled {
                    Toggle("Add new spellings without asking", isOn: bind(\.dictionaryLearningAutoAccept))
                    // The honest version of what this trades away. Capitalisation is
                    // visible when it's wrong; a swapped word reads as correct to the
                    // person who meant to say it.
                    Text(environment.settings.dictionaryLearningAutoAccept
                         ? "Words that change spelling — “gee are dee bee” → “GRDB” — are added on their own. A wrong one will keep replacing that word until you delete it in Dictionary."
                         : "Capitalisation fixes are added on their own. Anything that changes a word’s spelling waits for you in Dictionary.")
                        .font(.caption).foregroundStyle(.secondary)

                    if !environment.learnedSuggestions.isEmpty {
                        Text("^[\(environment.learnedSuggestions.count) suggestion](inflect: true) waiting in Dictionary.")
                            .font(.caption)
                    }

                    Button("Forget everything learned") {
                        environment.forgetLearnedTerms()
                    }
                    .help("Removes learned entries and starts counting from scratch. Entries you added yourself are kept.")
                }
            }

            speechSection

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

    /// Reading answers aloud.
    ///
    /// Scoped to answers on purpose, and the caption says so: the obvious reading of
    /// "speak responses" in a dictation app is that it will start reciting your
    /// dictation, and someone who switched this on in an open-plan office to find that
    /// out would not switch it on again.
    @ViewBuilder private var speechSection: some View {
        Section("Speech") {
            Toggle("Read answers out loud", isOn: bind(\.speechEnabled))
            Text("Talk answers are spoken when they arrive. Dictation is never spoken, and neither is anything sent to Claude Code — this only covers replies you'd otherwise read in the answer panel. esc stops it.")
                .font(.caption).foregroundStyle(.secondary)

            if environment.settings.speechEnabled {
                Picker("Voice engine", selection: bind(\.speechEngine)) {
                    ForEach(SpeechEngineID.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                switch environment.settings.speechEngine {
                case .system:
                    Text("Uses the voice from System Settings › Accessibility › Spoken Content. Starts instantly and needs nothing installed.")
                        .font(.caption).foregroundStyle(.secondary)

                case .qwen3:
                    Picker("Voice", selection: bind(\.speechVoice)) {
                        ForEach(SpeechVoice.allCases, id: \.self) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    Text("Runs Qwen3-TTS locally through MLX — nothing leaves the machine. It needs a Python with `mlx-audio` installed and holds about 4 GB of weights in memory while enabled. The model loads when you start speaking, which takes around 13 seconds the first time; answers before then fall silent rather than waiting.")
                        .font(.caption).foregroundStyle(.secondary)

                    if let found = QwenSpeechOutput.resolveInterpreter(
                        explicit: environment.settings.speechPythonPath) {
                        Label("Using \(found.path)", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("No Python with mlx-audio found. Name one below, or answers stay silent.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Python path (blank = find it automatically)",
                              text: bind(\.speechPythonPath))
                        .textFieldStyle(.roundedBorder)
                }

                // Speech otherwise can only be tested by producing a real answer, which
                // is a slow way to find out that a Python path is wrong — and makes a
                // silent voice indistinguishable from a failed answer.
                HStack {
                    Button(speechTestRunning ? "Speaking…" : "Test voice") {
                        speechTestRunning = true
                        environment.speakSample()
                        // Qwen's first utterance includes the ~13s model load.
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            speechTestRunning = false
                        }
                    }
                    .disabled(speechTestRunning)
                    Text(environment.settings.speechEngine == .qwen3
                         ? "The first one waits for the model to load (~13s)."
                         : "Should be immediate.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Shown for both engines. Qwen has no speaking-rate control of its
                // own, so this drives playback speed there instead — previously the
                // slider was system-only and a slow Qwen voice had no remedy at all.
                // 100–300 wpm: below 100 is unpleasant, above 300 is past what most
                // people can follow on an unfamiliar sentence.
                Slider(value: bind(\.speechRate), in: 100...300, step: 5) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text("Slow").font(.caption)
                } maximumValueLabel: {
                    Text("Fast").font(.caption)
                }
                Text(environment.settings.speechEngine == .qwen3
                     ? "\(String(format: "%.2f", environment.settings.speechRate / 175.0))× playback speed. 175 is the voice's natural pace."
                     : "\(Int(environment.settings.speechRate)) words per minute.")
                    .font(.caption).foregroundStyle(.secondary)

                Stepper(value: bind(\.speechMaxCharacters), in: 100...4000, step: 100) {
                    Text("Stop after \(environment.settings.speechMaxCharacters) characters")
                }
                Text("A long answer clipped at the nearest sentence. Qwen speaks at about real time, so an unclipped essay is a minute of talking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Handoff settings. The session is found by walking up from a running `claude`
    /// process, so the normal case needs no configuration — the bundle id is the
    /// escape hatch for when the wrong session wins.
    @ViewBuilder private var claudeCodeFields: some View {
        Toggle("Press Return to send it", isOn: bind(\.claudeCodeSubmitOnPaste))
        Text(environment.settings.claudeCodeSubmitOnPaste
             ? "Your words are submitted as soon as they land, so Claude Code starts working without you touching the keyboard. Turn this off to leave them in the composer to read first."
             : "Your words are typed in and left there — you press Return yourself.")
            .font(.caption).foregroundStyle(.secondary)

        if let app = ClaudeCodeHandoff.hostApplication(preferredBundleID: environment.settings.claudeCodeAppBundleID) {
            Label("Found a session in \(app.localizedName ?? app.bundleIdentifier ?? "an app").",
                  systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("No running Claude Code session found. Start one, or name the app below. Until then ⌃⌥ leaves your words on the clipboard and says so.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        TextField("App bundle id (blank = find it automatically)", text: bind(\.claudeCodeAppBundleID))
            .textFieldStyle(.roundedBorder)
    }

    /// The one formatter that uploads dictation. The warning is deliberately blunt
    /// and deliberately not collapsible — a user picking this from a dropdown has no
    /// other cue that the app just stopped being local-first.
    @ViewBuilder private var claudeFormatterFields: some View {
        TextField("Model", text: bind(\.formatterClaudeModel))
            .textFieldStyle(.roundedBorder)
        Label("Everything you dictate — in every app, not just this one — is sent to Anthropic to be punctuated. That includes anything you'd never paste into a chatbot, and the CLI keeps a copy of each one on disk under ~/.claude. The other formatters never leave your Mac.",
              systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        Label("Expect two to five seconds before your text appears, and every dictation counts against your Claude plan's usage. Set the model to “haiku” to roughly halve the wait, at the price of occasionally mangling long dictations that continue existing text.",
              systemImage: "clock")
            .font(.caption).foregroundStyle(.orange)
        if let path = ClaudeCLIFormatter.discoveredPath, environment.settings.formatterClaudePath.isEmpty {
            Text("Using \(path).")
                .font(.caption).foregroundStyle(.secondary)
        } else if environment.settings.formatterClaudePath.isEmpty {
            Text("Can't find the `claude` command — install it, or type its full path below (`which claude` in Terminal). Until then this falls back to basic cleanup on every utterance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        TextField("CLI path (blank = find it automatically)", text: bind(\.formatterClaudePath))
            .textFieldStyle(.roundedBorder)
    }

    /// Talk on the `claude` CLI. Same binary and same path setting as the `.claude`
    /// formatter — there's one on the machine, so there's one place to point at it.
    @ViewBuilder private var claudeTalkFields: some View {
        TextField("Model", text: bind(\.talkClaudeModel))
            .textFieldStyle(.roundedBorder)
        Label("Your question, anything you had selected, and any screenshot go to Anthropic on your Claude plan, and the CLI keeps a copy of each one on disk under ~/.claude.",
              systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        Text("Expect a couple of seconds before the answer starts, and a couple more when a screenshot is attached — it gets saved to a scratch folder and read, which the other providers don't have to do. Set the model to “haiku” for faster, shallower answers.")
            .font(.caption).foregroundStyle(.secondary)
        if ClaudeCLIFormatter.resolveExecutable(explicitPath: environment.settings.formatterClaudePath) == nil {
            Label("Can't find the `claude` command — install it, or type its full path below (`which claude` in Terminal). Until then questions fall through to your local server.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if let path = ClaudeCLIFormatter.discoveredPath,
                  environment.settings.formatterClaudePath.isEmpty {
            Text("Using \(path).")
                .font(.caption).foregroundStyle(.secondary)
        }
        TextField("CLI path (blank = find it automatically)", text: bind(\.formatterClaudePath))
            .textFieldStyle(.roundedBorder)
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
        let provider = environment.settings.talkProvider
        let destination = provider.isCloud
            ? "uploaded to \(provider.destinationPhrase)"
            : "sent to \(provider.destinationPhrase)"
        let staging = provider == .claudeCode
            ? " It's written to a scratch folder on disk first, and deleted once the answer arrives."
            : ""
        return "An image of your whole screen — every window on it, not just the one you're in — is \(destination) with each new question.\(staging) Requires the Screen Recording permission."
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
