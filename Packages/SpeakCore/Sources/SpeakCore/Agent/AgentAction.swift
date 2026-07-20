import Foundation

/// One thing the agent wants to do to the machine.
///
/// Coordinates are in *image space* — the pixel grid of the screenshot the model was
/// shown, not screen points. The executor maps them back; keeping the model's frame
/// of reference here means a mapping bug can't silently look like a model mistake.
public enum AgentAction: Equatable, Sendable {
    /// `label` is the model's own description of what it believes it's clicking
    /// ("the Send button"). It drives both the confirmation UI and the risk policy,
    /// so it is required rather than optional — an unlabelled click is unreviewable.
    case click(x: Int, y: Int, label: String, double: Bool)
    case type(String)
    /// A chord such as `cmd+a` or a bare key such as `return`.
    case press(String)
    case scroll(x: Int, y: Int, amount: Int)
    /// The agent believes the task is complete. Carries what it did, for the panel.
    case done(String)

    /// A short human-readable form for the step list and confirmation prompt.
    public var summary: String {
        switch self {
        case let .click(x, y, label, double):
            return "\(double ? "double-click" : "click") \(label) (\(x),\(y))"
        case let .type(text):
            let clipped = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "type \"\(clipped)\""
        case let .press(keys):
            return "press \(keys)"
        case let .scroll(_, _, amount):
            return "scroll \(amount > 0 ? "down" : "up")"
        case let .done(summary):
            return summary
        }
    }
}

/// What the runner is allowed to do with an action.
public enum AgentRisk: Equatable, Sendable {
    /// Execute without asking.
    case safe
    /// Execute only after the user presses the confirm key. The string is the reason
    /// shown to them, and should say *why* rather than restate the action.
    case confirm(String)
    /// Never execute, with or without confirmation. Reserved for cases where asking
    /// would itself be dangerous — chiefly typing into a password field.
    case blocked(String)

    public var needsConfirmation: Bool {
        if case .confirm = self { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Decides which agent actions may run unattended.
///
/// This is the feature's safety boundary, so it lives here — pure, `Sendable`, and
/// unit-tested — rather than inside the runner where it would be untestable and easy
/// to bypass. It is deliberately biased toward over-confirming: a spurious prompt
/// costs a keystroke, while a missed one can send a message or empty a folder.
///
/// It classifies on the model's *stated* target label, which is not a guarantee —
/// a model that mislabels a button defeats it. That's an accepted limit, not an
/// oversight: the label is the only description of intent available before the click
/// lands, and it's strictly better than classifying on coordinates alone.
public struct AgentRiskPolicy: Sendable {
    /// Apps where every single action is confirmed regardless of label. Typing into a
    /// terminal is arbitrary code execution, and the credential managers are the
    /// obvious target of any injected instruction.
    public var alwaysConfirmApps: Set<String>
    /// Verbs that commit, spend, publish, or destroy. Matched as whole words against
    /// the click label.
    public var irreversibleWords: Set<String>
    /// Chords that commit or destroy in most apps.
    public var riskyCombos: Set<String>

    public init(alwaysConfirmApps: Set<String> = Self.defaultAlwaysConfirmApps,
                irreversibleWords: Set<String> = Self.defaultIrreversibleWords,
                riskyCombos: Set<String> = Self.defaultRiskyCombos) {
        self.alwaysConfirmApps = alwaysConfirmApps
        self.irreversibleWords = irreversibleWords
        self.riskyCombos = riskyCombos
    }

    public static let `default` = AgentRiskPolicy()

    public static let defaultAlwaysConfirmApps: Set<String> = [
        "terminal", "iterm2", "iterm", "warp", "ghostty", "alacritty", "kitty",
        "keychain access", "1password", "bitwarden", "dashlane", "lastpass",
        "system settings", "system preferences", "activity monitor", "console",
        "finder", "disk utility", "keychain",
    ]

    public static let defaultIrreversibleWords: Set<String> = [
        // Commit / transmit
        "send", "submit", "post", "publish", "tweet", "share", "invite", "reply",
        "confirm", "accept", "approve", "agree", "continue", "ok", "yes",
        // Money
        "buy", "purchase", "pay", "checkout", "order", "subscribe", "upgrade",
        "donate", "tip", "renew",
        // Destructive
        "delete", "remove", "trash", "discard", "erase", "clear", "reset", "wipe",
        "uninstall", "revoke", "unsubscribe", "leave", "archive", "block", "report",
        // Privileged / state-changing
        "allow", "grant", "enable", "disable", "install", "update", "restart",
        "shut down", "log out", "sign out", "merge", "push", "deploy", "publish",
    ]

    public static let defaultRiskyCombos: Set<String> = [
        // ⌘↩ sends in Mail, Slack, Messages, and most chat apps.
        "cmd+return", "cmd+enter",
        // Delete-to-trash and its permanent variant.
        "cmd+delete", "cmd+backspace", "cmd+shift+delete", "shift+cmd+delete",
        // Quit / close without saving, and print (spends paper, hard to undo).
        "cmd+q", "cmd+shift+q",
    ]

    /// Classify one action.
    ///
    /// - Parameters:
    ///   - action: what the agent proposes.
    ///   - app: the frontmost app's name, if known. An unknown app is treated as
    ///     unrecognised rather than trusted.
    ///   - secureInputActive: whether macOS reports a password field has focus.
    public func risk(of action: AgentAction,
                     inApp app: String?,
                     secureInputActive: Bool) -> AgentRisk {
        // Hard stop, ahead of everything else. If a password field has focus we
        // cannot know what's being captured, so there is no version of this we let
        // through — asking the user to approve it would just launder the risk.
        if secureInputActive, case .type = action {
            return .blocked("a password field has focus")
        }
        if secureInputActive, case .press = action {
            return .blocked("a password field has focus")
        }

        if let app, alwaysConfirmApps.contains(app.lowercased()) {
            // `.done` is not an action on the machine, so it never needs approval.
            if case .done = action { return .safe }
            return .confirm("every action in \(app) is confirmed")
        }

        switch action {
        case let .click(_, _, label, _):
            if let word = matchedIrreversibleWord(in: label) {
                return .confirm("“\(word)” looks irreversible")
            }
            return .safe

        case let .press(keys):
            // Both sides must be normalised. Comparing a sorted chord against the
            // raw set silently missed every three-key combo — `cmd+shift+delete`
            // sorts to `cmd+delete+shift` and matched nothing.
            if normalizedRiskyCombos.contains(normalizedCombo(keys)) {
                return .confirm("\(keys) usually sends or deletes")
            }
            return .safe

        case .type, .scroll, .done:
            // Typing is gated by where it lands, not by its content: the click that
            // commits it is the thing worth confirming, and prompting on every
            // keystroke would train the user to approve without reading.
            return .safe
        }
    }

    /// Whole-word, case-insensitive match so "resend" doesn't trip on "send" and
    /// "Sender" doesn't trip on "send", while "Send Message" does.
    func matchedIrreversibleWord(in label: String) -> String? {
        let words = label
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        // Two-word phrases first ("log out"), so the more specific reason wins.
        for pair in zip(words, words.dropFirst()) {
            let phrase = "\(pair.0) \(pair.1)"
            if irreversibleWords.contains(phrase) { return phrase }
        }
        return words.first { irreversibleWords.contains($0) }
    }

    /// Order-insensitive, case-insensitive chord normalisation, so `Shift+Cmd+Delete`
    /// and `cmd+shift+delete` classify the same.
    func normalizedCombo(_ keys: String) -> String {
        keys.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .sorted()
            .joined(separator: "+")
    }
}

extension AgentRiskPolicy {
    /// `riskyCombos` is authored in reading order for legibility; comparison needs
    /// the normalised form, so fold it once at init time.
    public var normalizedRiskyCombos: Set<String> {
        Set(riskyCombos.map(normalizedCombo))
    }
}
