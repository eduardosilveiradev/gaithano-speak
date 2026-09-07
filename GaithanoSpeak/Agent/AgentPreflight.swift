import Foundation
import AppKit
import os
import SpeakCore

private let agentLog = Logger(subsystem: Log.subsystem, category: "agent")

/// Runs the seven availability checks and reports what Agent Mode can and can't do.
///
/// **Nothing here asks for anything.** Every permission check uses the non-prompting
/// variant — `AVCaptureDevice.authorizationStatus`, `AXIsProcessTrusted()`,
/// `CGPreflightScreenCaptureAccess()` — never `requestAccess`,
/// `AXIsProcessTrustedWithOptions(prompt: true)`, or
/// `CGRequestScreenCaptureAccess()`. A preflight that raises three system dialogs the
/// moment someone opens Settings is worse than one that reports "not granted" next to
/// a button, and worse again when it runs on a timer: macOS shows the Screen Recording
/// prompt once per app, so spending it on a background refresh means the user never
/// sees it at the moment they were trying to turn the feature on. The remedies in
/// `PreflightStatus` deep-link into the right Settings pane instead.
///
/// The same rule holds for the CLIs. `claude --version` is a local read that returns
/// in ~70ms and costs nothing; `smartthings devices` would open a browser login when
/// the token has expired, which is a side effect a *check* is not allowed to have —
/// so the CLI's credential file is read instead and the sign-in command is offered as
/// a remedy the user runs.
///
/// The pure part — comparing versions, folding results into available / degraded /
/// unavailable, and the remedy for each failure — is `PreflightStatus` in SpeakCore,
/// under test. This file is only the I/O.
@MainActor
struct AgentPreflight: Sendable {
    /// `AppSettings.formatterClaudePath`. Blank means "go and look": a launchd-started
    /// GUI app inherits a bare PATH, so `claude` is never simply on it.
    var claudePath: String = ""
    /// `AppSettings.agentSmartThingsPath`, same bargain.
    var smartThingsPath: String = ""

    /// Whether the Playwright MCP extension is currently attached to Chrome.
    ///
    /// Injected rather than probed, because only the process holding the MCP
    /// connection knows the answer — the extension talks to the server, not to us, and
    /// anything this file could measure (a port that happens to be listening, a
    /// directory that happens to exist in a Chrome profile) would report "connected"
    /// for a bridge that has been down since the last Chrome restart. Defaults to
    /// `false` so an unwired caller reports the honest "not connected" with a remedy
    /// rather than a green light for a capability that isn't there.
    var chromeBridgeConnected: @Sendable () async -> Bool = { false }

    // MARK: - The pass

    func run() async -> PreflightStatus {
        let (claudeFinding, version) = await claudeCode()
        let results = [
            PreflightCheckResult(.microphone, microphone()),
            PreflightCheckResult(.accessibility, accessibility()),
            PreflightCheckResult(.screenRecording, screenRecording()),
            PreflightCheckResult(.claudeCode, claudeFinding),
            PreflightCheckResult(.chromeExtension, await chrome()),
            PreflightCheckResult(.smartThings, smartThings()),
            PreflightCheckResult(.models, models(claudeVersion: version)),
        ]
        let status = PreflightStatus(results: results)
        agentLog.info("Agent preflight: \(status.headline, privacy: .public)")
        return status
    }

    // MARK: - Permissions

    private func microphone() -> PreflightFinding {
        PermissionsService.microphoneGranted ? .satisfied : .permissionNotGranted
    }

    private func accessibility() -> PreflightFinding {
        PermissionsService.accessibilityGranted ? .satisfied : .permissionNotGranted
    }

    private func screenRecording() -> PreflightFinding {
        PermissionsService.screenRecordingGranted ? .satisfied : .permissionNotGranted
    }

    // MARK: - Claude Code

    /// Installed, new enough, signed in — in that order, because each answer only
    /// means anything if the one before it was yes.
    ///
    /// The version comes back alongside the finding so the models check can use it
    /// without paying for a second process launch.
    private func claudeCode() async -> (PreflightFinding, CLIVersion?) {
        guard let executable = ClaudeCLIFormatter.resolveExecutable(explicitPath: claudePath) else {
            return (.notInstalled, nil)
        }
        guard let output = await Self.output(of: executable, arguments: ["--version"]) else {
            return (.checkFailed("`claude --version` didn't answer"), nil)
        }
        guard let version = CLIVersion(parsing: output) else {
            return (.checkFailed("couldn't read a version out of \"\(output)\""), nil)
        }
        guard version >= CLIVersion.minimumClaudeCode else {
            // Blocking, following the spec's own list of what must pass. It is a
            // sharper rule than it first looks — Sonnet and Opus work fine on an older
            // CLI, so this takes the whole feature away over a missing top rung. Left
            // as written because the alternative is a user who never learns why
            // escalation stops at Opus, and the fix is one `claude update`.
            return (.outdated(found: version.description), version)
        }
        guard isClaudeAuthenticated() else {
            return (.notAuthenticated, version)
        }
        return (.satisfied, version)
    }

    /// Whether the CLI has credentials, inferred from disk.
    ///
    /// A heuristic, and knowingly so. The definitive check is a request, which costs a
    /// round trip and plan usage every time Settings opens. The other candidate — the
    /// Keychain item the native installer writes — is worse: a `SecItemCopyMatching`
    /// from a different app hits that item's ACL and puts a "Gaithano Speak wants to
    /// use your keychain" dialog in front of someone who was reading a checklist,
    /// which is the exact side effect this whole file is written to avoid. So: the API
    /// key if one is set, the npm install's credential file, or the `oauthAccount`
    /// record the CLI writes into `~/.claude.json` after a sign-in.
    ///
    /// A false "not signed in" is a visible warning with a one-line fix. A real auth
    /// failure at run time is reported by the runtime, which is the layer that gets a
    /// definitive answer for free.
    private func isClaudeAuthenticated() -> Bool {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return true
        }
        let home = NSHomeDirectory()
        if FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json") {
            return true
        }
        // Mapped rather than read: `~/.claude.json` accumulates per-project history and
        // is routinely megabytes.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json"),
                                   options: [.mappedIfSafe]) else { return false }
        return data.range(of: Data("oauthAccount".utf8)) != nil
    }

    // MARK: - Models

    /// Which of the three tiers the plan carries.
    ///
    /// The one entitlement fact available for free is the CLI version, and the spec
    /// ties Fable 5.1 to it directly. Actually enumerating plan access would mean one
    /// real request per tier every time this runs — three round trips and three
    /// charges against the user's plan to populate a checklist — so it isn't done
    /// here. The spec's other half covers the rest: "if a model is unavailable, report
    /// it, do not silently substitute", which is the runtime's job at the moment a
    /// model actually refuses.
    private func models(claudeVersion: CLIVersion?) -> PreflightFinding {
        guard let version = claudeVersion else {
            return .checkFailed("no Claude Code version to check against")
        }
        return version >= CLIVersion.minimumClaudeCode ? .satisfied : .unavailableOnPlan([.fable])
    }

    // MARK: - Chrome

    private func chrome() async -> PreflightFinding {
        // Chrome specifically, not "a browser": extension mode attaches to the user's
        // existing profile, which is what keeps cookies, SSO, and 2FA state available.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        else { return .notInstalled }
        return await chromeBridgeConnected() ? .satisfied : .notConnected
    }

    // MARK: - SmartThings

    /// Where npm, bun, and homebrew put `smartthings`, in the order they're used.
    private static let smartThingsPaths = [
        "\(NSHomeDirectory())/.local/bin/smartthings",
        "\(NSHomeDirectory())/.bun/bin/smartthings",
        "\(NSHomeDirectory())/.npm-global/bin/smartthings",
        "/opt/homebrew/bin/smartthings",
        "/usr/local/bin/smartthings",
    ]

    /// The CLI's path, for the SmartThings MCP adapter to spawn. Resolved the same way
    /// as `claude` and for the same reason — a GUI app's PATH doesn't have it.
    static func smartThingsExecutable(explicitPath: String = "") -> URL? {
        let explicit = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: explicit) else { return nil }
            return URL(fileURLWithPath: explicit)
        }
        return smartThingsPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func smartThings() -> PreflightFinding {
        guard Self.smartThingsExecutable(explicitPath: smartThingsPath) != nil else {
            return .notInstalled
        }
        // `smartthings-cli` is an oclif program, so its config lives under
        // `~/Library/Preferences/@smartthings/cli/` on macOS. Reading for the token
        // file rather than running a command: any real command re-runs the OAuth flow
        // when the token has expired, which opens a browser — and the spec is explicit
        // that reauthentication is a setup action in the app, never something a check
        // or Claude sets off.
        let credentials = "\(NSHomeDirectory())/Library/Preferences/@smartthings/cli/credentials.json"
        return FileManager.default.fileExists(atPath: credentials) ? .satisfied : .notAuthenticated
    }

    // MARK: - Running a CLI for its version

    /// Capture a short command's stdout, or nil if it failed or hung.
    ///
    /// `ClaudeCLIFormatter` runs the same binary with the same environment — that's
    /// where `MAX_THINKING_TOKENS=0`, the PATH repair, and the empty cwd come from, in
    /// one place rather than copied. The timeout is short because `--version` is a
    /// local read measured at ~70ms; anything slower than five seconds is a wedged
    /// process, not a slow one, and the preflight must not hang Settings waiting for it.
    private static func output(of executable: URL,
                               arguments: [String],
                               timeout: TimeInterval = 5) async -> String? {
        let probe = Probe(executable: executable,
                          arguments: arguments,
                          environment: ClaudeCLIFormatter.childEnvironment(),
                          workingDirectory: ClaudeCLIFormatter.workingDirectory)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe.run(timeout: timeout))
            }
        }
    }

    /// Owns one short-lived process. `Process` and its pipes aren't `Sendable`, so
    /// they're confined to this class and never handed across an isolation boundary —
    /// the same shape, and the same reason, as `ClaudeCLIFormatter.ProcessRun`.
    private final class Probe: @unchecked Sendable {
        private let process = Process()
        private let out = Pipe()

        init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            // Nothing to say, and an inherited stdin leaves the CLI waiting out its 3s
            // idle timer before it does anything.
            process.standardInput = FileHandle.nullDevice
        }

        func run(timeout: TimeInterval) -> String? {
            do {
                try process.run()
            } catch {
                agentLog.error("Preflight probe failed to launch: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let killer = DispatchWorkItem { [self] in
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
