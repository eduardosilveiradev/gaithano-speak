import Foundation

// Whether Agent Mode can run, answered as data rather than a boolean.
//
// The spec makes four things hard requirements — microphone, Accessibility, Screen
// Recording, Claude Code — and three things soft: Chrome, SmartThings, and which
// models the plan actually carries. The difference is the whole reason this is a
// type and not a `Bool`. A user with no Chrome extension still gets desktop control
// and lights; collapsing that to "unavailable" would take away six working
// capabilities because a seventh is missing.
//
// Everything here is pure so the rules can be tested. The checks themselves — TCC
// grants, `claude --version`, looking for a CLI on disk — live in `AgentPreflight`
// in the app target, which is also where the rule about never prompting lives.

// MARK: - Versions

/// A `major.minor.patch` version, compared numerically.
///
/// It exists because the obvious comparison is wrong in precisely the case that
/// matters here: as strings, `"2.1.255" < "2.1.9"`. A string compare therefore
/// reports the build that *does* have Fable 5.1 as older than the floor and hides
/// Agent Mode from every user who is correctly up to date. That single inversion is
/// what `PreflightTests` pins.
public struct CLIVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Semver pre-release identifiers, if the version carried any. Kept rather than
    /// discarded because `2.1.255-beta.1` is *older* than `2.1.255`: someone on a
    /// pre-release of the floor build has to be told to update, not waved through
    /// into a Fable escalation the CLI can't serve.
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parse the first version-looking token out of arbitrary CLI output.
    ///
    /// `claude --version` answers `2.1.255 (Claude Code)`, so this can't be a whole-
    /// string parse. Build metadata after `+` is dropped on purpose — semver says it
    /// takes no part in precedence, and two builds of 2.1.255 have the same models.
    public init?(parsing raw: String) {
        guard let token = raw.range(of: #"\d+(\.\d+){0,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?"#,
                                    options: .regularExpression) else { return nil }
        var body = String(raw[token])
        var pre: String?
        if let dash = body.firstIndex(of: "-") {
            pre = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
        }
        let parts = body.split(separator: ".").map { Int($0) ?? 0 }
        guard let first = parts.first else { return nil }
        self.init(first,
                  parts.count > 1 ? parts[1] : 0,
                  parts.count > 2 ? parts[2] : 0,
                  prerelease: pre)
    }

    /// The floor the spec names. Below it `claude --model claude-fable-5-1` is not a
    /// model the CLI knows, so the top rung of the escalation ladder does not exist.
    public static let minimumClaudeCode = CLIVersion(2, 1, 255)

    public static func < (a: CLIVersion, b: CLIVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        // A pre-release sorts below the release it leads up to.
        case (.some, nil): return true
        case (nil, .some): return false
        case let (left?, right?): return left < right
        }
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }
}

// MARK: - Capabilities

/// What a failed check actually costs the user.
///
/// The spec's rule — "Chrome and SmartThings may report separate unavailable states
/// without disabling unrelated desktop control" — is enforced by this mapping rather
/// than by every call site remembering it.
public enum AgentCapability: String, Sendable, CaseIterable, Codable {
    /// Hearing the request, driving the desktop, seeing the result, and having a
    /// runtime to think with. Nothing works without all four, which is why they are
    /// one capability and not four.
    case core
    case browser
    case smartThings
    /// Climbing the model ladder. Losing this leaves the run on whatever tier the
    /// plan does carry rather than stopping it.
    case escalation

    public var displayName: String {
        switch self {
        case .core: return "Desktop control"
        case .browser: return "Chrome control"
        case .smartThings: return "SmartThings"
        case .escalation: return "Model escalation"
        }
    }
}

// MARK: - Checks

public enum PreflightCheck: String, Sendable, CaseIterable, Codable {
    case microphone
    case accessibility
    case screenRecording
    case claudeCode
    case chromeExtension
    case smartThings
    case models

    public var capability: AgentCapability {
        switch self {
        case .microphone, .accessibility, .screenRecording, .claudeCode: return .core
        case .chromeExtension: return .browser
        case .smartThings: return .smartThings
        case .models: return .escalation
        }
    }

    /// Whether failing this check makes Agent Mode unavailable outright.
    public var isRequired: Bool { capability == .core }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .claudeCode: return "Claude Code"
        case .chromeExtension: return "Chrome extension"
        case .smartThings: return "SmartThings CLI"
        case .models: return "Models on your plan"
        }
    }
}

/// How a check came out. Distinct cases rather than a message string because the
/// remedy differs per case and the spec asks for all three of Claude Code's:
/// "show how to install, update, or authenticate it".
public enum PreflightFinding: Equatable, Sendable {
    case satisfied
    /// A TCC grant the user has not given. Never "not yet asked" — see
    /// `AgentPreflight`, which is forbidden from asking.
    case permissionNotGranted
    case notInstalled
    case outdated(found: String)
    case notAuthenticated
    /// Installed, signed in, but not currently reachable — the Chrome extension.
    case notConnected
    case unavailableOnPlan([AgentModelTier])
    /// The check itself could not be carried out. Distinct from a failed check: the
    /// remedy is "try again", not "go and install something".
    case checkFailed(String)

    public var isSatisfied: Bool { self == .satisfied }
}

// MARK: - Remedies

/// What the app offers to do about a failure. The spec requires every error to carry
/// "a concrete recovery action", so this is non-optional for every non-satisfied
/// finding by construction — `remedy(for:finding:)` is total.
public struct PreflightRemedy: Equatable, Sendable {
    /// One sentence naming what is wrong and what it costs.
    public var problem: String
    /// Button title.
    public var actionLabel: String
    public var action: PreflightAction

    public init(problem: String, actionLabel: String, action: PreflightAction) {
        self.problem = problem
        self.actionLabel = actionLabel
        self.action = action
    }
}

public enum PreflightAction: Equatable, Sendable {
    /// An `x-apple.systempreferences:` URL. Deep-linking rather than requesting the
    /// grant, because a preflight that raises three system dialogs the moment
    /// Settings opens is worse than one that reports the truth with a button.
    case openSystemSettings(String)
    case openURL(String)
    /// A command for the user to run themselves. The app shows it to copy and never
    /// executes it — `smartthings` reauthentication opens a browser login, which is
    /// exactly the side effect a check is not allowed to have, and the spec says not
    /// to ask Claude to run it either.
    case runInTerminal(String)
    /// Nothing to fix; the check didn't complete.
    case retryCheck
}

public struct PreflightCheckResult: Equatable, Sendable, Identifiable {
    public var id: PreflightCheck { check }
    public let check: PreflightCheck
    public let finding: PreflightFinding

    public init(_ check: PreflightCheck, _ finding: PreflightFinding) {
        self.check = check
        self.finding = finding
    }

    public var isSatisfied: Bool { finding.isSatisfied }

    public var remedy: PreflightRemedy? {
        finding.isSatisfied ? nil : Self.remedy(for: check, finding: finding)
    }

    /// Total by design: any check crossed with any finding yields something the user
    /// can act on. A failure with no next step is the one outcome the panel must
    /// never be able to render.
    public static func remedy(for check: PreflightCheck,
                              finding: PreflightFinding) -> PreflightRemedy {
        switch (check, finding) {
        // First, so every check below can use a bare `_` for "however it failed"
        // without shadowing this one.
        case let (_, .checkFailed(detail)):
            return PreflightRemedy(problem: "\(check.title) couldn't be checked: \(detail)",
                                   actionLabel: "Check again",
                                   action: .retryCheck)

        case (.microphone, _):
            return PreflightRemedy(
                problem: "Agent Mode can't hear you — Microphone access is off.",
                actionLabel: "Open Microphone Settings",
                action: .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))

        case (.accessibility, _):
            return PreflightRemedy(
                problem: "Agent Mode can't click, type, or read the controls on screen — Accessibility access is off.",
                actionLabel: "Open Accessibility Settings",
                action: .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))

        case (.screenRecording, _):
            // The grant only takes effect after a relaunch, so saying so here saves a
            // support round trip with someone who has already granted it and is
            // looking at an unchanged red dot.
            return PreflightRemedy(
                problem: "Agent Mode can't see the screen, so it can't verify what its actions did — Screen Recording access is off. macOS applies this grant after the app restarts.",
                actionLabel: "Open Screen Recording Settings",
                action: .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))

        case (.claudeCode, .notInstalled):
            return PreflightRemedy(
                problem: "Claude Code isn't installed. Agent Mode runs on it — there is no fallback runtime.",
                actionLabel: "Copy install command",
                action: .runInTerminal("curl -fsSL https://claude.ai/install.sh | bash"))

        case let (.claudeCode, .outdated(found)):
            return PreflightRemedy(
                problem: "Claude Code \(found) is older than \(CLIVersion.minimumClaudeCode), which is the first version that offers \(AgentModelTier.fable.displayName).",
                actionLabel: "Copy update command",
                action: .runInTerminal("claude update"))

        case (.claudeCode, .notAuthenticated):
            return PreflightRemedy(
                problem: "Claude Code is installed but not signed in.",
                actionLabel: "Copy sign-in command",
                action: .runInTerminal("claude"))

        case (.claudeCode, _):
            return PreflightRemedy(
                problem: "Claude Code isn't usable. Agent Mode runs on it — there is no fallback runtime.",
                actionLabel: "Copy install command",
                action: .runInTerminal("curl -fsSL https://claude.ai/install.sh | bash"))

        case (.chromeExtension, .notInstalled):
            return PreflightRemedy(
                problem: "Chrome isn't installed, so Agent Mode can't drive the browser. Everything else still works.",
                actionLabel: "Get Chrome",
                action: .openURL("https://www.google.com/chrome/"))

        case (.chromeExtension, _):
            // Extension mode is the point: it attaches to the profile the user is
            // already signed in to, so SSO and 2FA state carry. A headless browser
            // would connect on the first try and be logged in to nothing.
            return PreflightRemedy(
                problem: "The Playwright extension isn't connected to Chrome, so Agent Mode can't use your existing tabs and sessions. Everything else still works.",
                actionLabel: "How to connect it",
                action: .openURL("https://github.com/microsoft/playwright-mcp#browser-extension"))

        case (.smartThings, .notInstalled):
            return PreflightRemedy(
                problem: "`smartthings-cli` isn't installed, so home devices aren't available. Everything else still works.",
                actionLabel: "Copy install command",
                action: .runInTerminal("npm install -g @smartthings/cli"))

        case (.smartThings, _):
            return PreflightRemedy(
                problem: "`smartthings-cli` isn't signed in, so home devices aren't available. Running this opens a browser to finish sign-in.",
                actionLabel: "Copy sign-in command",
                action: .runInTerminal("smartthings devices"))

        case let (.models, .unavailableOnPlan(tiers)):
            let names = tiers.map(\.displayName).joined(separator: " and ")
            return PreflightRemedy(
                problem: "\(names) isn't available here, so a run can't escalate past \(highestTier(excluding: tiers).displayName).",
                actionLabel: "Review your plan",
                action: .openURL("https://claude.ai/settings/usage"))

        case (.models, _):
            return PreflightRemedy(
                problem: "Couldn't work out which models your plan carries. A run will start on \(AgentModelTier.sonnet.displayName) and report any model it can't reach.",
                actionLabel: "Check again",
                action: .retryCheck)
        }
    }

    static func highestTier(excluding unavailable: [AgentModelTier]) -> AgentModelTier {
        AgentModelTier.allCases.filter { !unavailable.contains($0) }.max() ?? .sonnet
    }
}

// MARK: - Aggregate

public enum AgentAvailability: String, Sendable, Equatable, Codable {
    /// Everything passed.
    case available
    /// Every required check passed; some optional capability is missing. The gesture
    /// works and so does everything not named in `degradations`.
    case degraded
    /// A required check failed. The gesture is off.
    case unavailable
}

/// The result of one preflight pass.
public struct PreflightStatus: Equatable, Sendable {
    /// One result per check that ran. A check that did not run is not the same as a
    /// check that passed — see `result(for:)`.
    public let results: [PreflightCheckResult]

    public init(results: [PreflightCheckResult]) {
        self.results = results
    }

    /// The result for a check, or a `.checkFailed` stand-in when the pass didn't
    /// produce one.
    ///
    /// Missing means blocking, deliberately. The alternative — treating an absent
    /// result as a pass — turns a preflight that crashed halfway into a green light,
    /// which is the failure mode that ends with the agent typing into a password
    /// field because nobody checked for secure input either.
    public func result(for check: PreflightCheck) -> PreflightCheckResult {
        results.first { $0.check == check }
            ?? PreflightCheckResult(check, .checkFailed("not checked"))
    }

    public var blocking: [PreflightCheckResult] {
        PreflightCheck.allCases
            .filter(\.isRequired)
            .map(result(for:))
            .filter { !$0.isSatisfied }
    }

    public var degradations: [PreflightCheckResult] {
        PreflightCheck.allCases
            .filter { !$0.isRequired }
            .map(result(for:))
            .filter { !$0.isSatisfied }
    }

    public var availability: AgentAvailability {
        if !blocking.isEmpty { return .unavailable }
        return degradations.isEmpty ? .available : .degraded
    }

    /// Whether one capability can be used right now.
    ///
    /// Core gates everything: with no microphone there is no request to act on, so
    /// "SmartThings is fine" would be true and useless. Below that the capabilities
    /// are independent, which is the distinction the spec asks for.
    public func isAvailable(_ capability: AgentCapability) -> Bool {
        let coreOK = PreflightCheck.allCases
            .filter { $0.capability == .core }
            .allSatisfy { result(for: $0).isSatisfied }
        guard coreOK else { return false }
        guard capability != .core else { return true }
        return PreflightCheck.allCases
            .filter { $0.capability == capability }
            .allSatisfy { result(for: $0).isSatisfied }
    }

    /// The highest model a run may escalate to. The ladder stops here rather than
    /// silently substituting, which the spec forbids mid-run.
    public var escalationCeiling: AgentModelTier {
        guard case let .unavailableOnPlan(missing) = result(for: .models).finding else {
            return .fable
        }
        return PreflightCheckResult.highestTier(excluding: missing)
    }

    /// Every failure with its recovery action, blocking ones first — the order the
    /// panel should read them out in, since fixing a degradation while the gesture is
    /// still off helps nobody.
    public var remedies: [PreflightRemedy] {
        (blocking + degradations).compactMap(\.remedy)
    }

    /// One line for the panel or the Settings row.
    public var headline: String {
        switch availability {
        case .available:
            return "Agent Mode is ready."
        case .degraded:
            let names = degradations.map(\.check.title).joined(separator: ", ")
            return "Agent Mode is ready, without: \(names)."
        case .unavailable:
            let names = blocking.map(\.check.title).joined(separator: ", ")
            return "Agent Mode is unavailable until you fix: \(names)."
        }
    }
}
