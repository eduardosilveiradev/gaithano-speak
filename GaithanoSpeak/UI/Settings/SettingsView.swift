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

            Section("Talk") {
                Toggle("Hold Control while speaking to ask a model", isOn: bind(\.talkEnabled))
                Text("⌃⌥ instead of ⌥: your words go to a model and the answer appears in a panel instead of being typed. ⌘C copies it, ⌘↩ inserts it, esc closes.")
                    .font(.caption).foregroundStyle(.secondary)

                if environment.settings.talkEnabled {
                    Toggle("Send it to Claude Code instead of answering", isOn: bind(\.claudeCodeHandoffEnabled))
                    Text("⌃⌥ types what you said straight into the terminal running Claude Code and brings it to the front. Nothing goes to a model of ours, so there's no answer panel — and while this is on, the agent and the provider below are unreachable, which is why they're hidden.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if environment.settings.talkEnabled && environment.settings.claudeCodeHandoffEnabled {
                    claudeCodeFields
                } else if environment.settings.talkEnabled {
                    Picker("Provider", selection: bind(\.talkProvider)) {
                        ForEach(TalkProviderID.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    if environment.settings.talkProvider == .vertexGemini {
                        vertexFields
                    }
                    Toggle("Send a screenshot of your screen", isOn: bind(\.talkVisionEnabled))
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

                    Divider()

                    Toggle("Let the model use your computer", isOn: bind(\.agentEnabled))
                        .onChange(of: environment.settings.agentEnabled) { _, enabled in
                            // The agent can't work blind, so it needs the same grant
                            // vision does — ask now rather than failing mid-run.
                            if enabled && !PermissionsService.requestScreenRecording() {
                                needsScreenRecording = true
                            }
                        }
                    Text("On, ⌃⌥ runs the agent rather than answering: the model reads your screen and can click and type for you. Turn this off to go back to plain answers. It runs on its own for ordinary steps, and stops for your approval before anything that sends, deletes, buys, or touches a terminal or password manager — ↩ allows one step, A allows the rest of that run, esc stops it. Anything written on your screen is treated as text to read, never as instructions to follow.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Always start in auto mode", isOn: bind(\.agentAutoConfirm))
                    Text("Skips every approval prompt from the first step, so the model sends, deletes, and buys without stopping to ask. Typing while a password field has focus is still refused — that rail isn't a prompt. esc still stops a run.")
                        .font(.caption)
                        .foregroundStyle(environment.settings.agentAutoConfirm ? .orange : .secondary)

                    if !environment.settings.talkVisionEnabled {
                        // The agent cannot work blind, so it screenshots whatever the
                        // setting above says. Saying so is better than a toggle that
                        // quietly doesn't hold for one of the two gestures.
                        Text("Note: this sends screenshots every step even with the setting above off — the model can't act on a screen it can't see. Turn this off to stop it.")
                            .font(.caption).foregroundStyle(.orange)
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
        return "An image of your whole screen — every window on it, not just the one you're in — is \(destination) with each new question. Requires the Screen Recording permission."
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
