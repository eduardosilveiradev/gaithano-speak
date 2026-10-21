import Foundation

/// Decides which proposed tool calls stop for a human.
///
/// `classify` returning nil means "run it, don't ask" — everything else is a category
/// the panel shows and the proxy blocks on. The default is not nil. Any tool, argument,
/// or capability this file does not positively recognise comes back `.unknown`, which
/// requires approval. That single default is the difference between a gate and a
/// suggestion: the interesting failure is never the action we thought about, it's the
/// one that arrived under a name we'd never seen, and a policy whose fall-through is
/// "allow" gets that case wrong every time.
///
/// It is pure and lives here rather than in the proxy because it is the part worth
/// pinning with tests. The proxy is plumbing; this is the boundary.
public enum ActionRiskPolicy {

    /// - Returns: nil when the call may run automatically, otherwise why it needs a human.
    public static func classify(_ call: AgentToolCall) -> ApprovalCategory? {
        // Defence in depth. The proxy refuses a non-allowlisted tool long before this,
        // but a policy that quietly returned "automatic" for a tool nobody vetted would
        // make that refusal the only thing standing between a new tool and the desktop.
        guard AgentToolAllowlist.isAllowed(server: call.server, tool: call.tool) else {
            return .unknown
        }

        switch call.server {
        case .macos: return classifyMacOS(call)
        case .chrome: return classifyChrome(call)
        case .smartthings: return classifySmartThings(call)
        case .control: return classifyControl(call)
        }
    }

    /// The sentence shown above the Allow / Deny buttons.
    ///
    /// Built here, next to the judgement, so the panel shows the reason the gate
    /// actually acted on. A panel that composes its own explanation drifts from the
    /// policy the moment either changes, and the user is the one who finds out.
    public static func reason(for call: AgentToolCall, category: ApprovalCategory) -> String {
        let where_ = call.target.map { " in \($0)" } ?? ""
        switch category {
        case .typing:
            return "Enters or submits text\(where_). Text can send a message, run a search, or commit a form, so it's always confirmed."
        case .closingOrQuitting:
            return "Closes a window or quits an app\(where_). Unsaved work can't be recovered afterwards."
        case .systemSettings:
            return "Changes a system setting\(where_). Settings outlive this conversation."
        case .deletion:
            return "Deletes data\(where_). There's no undo for this one."
        case .purchase:
            return "Looks like a purchase or checkout step\(where_). Spending money always stops here."
        case .security:
            return "Controls a security device\(where_) — a lock, door, gate, or alarm."
        case .unknown:
            return "Gaithano Speak doesn't recognise `\(call.tool)`\(where_) well enough to judge whether it's reversible, so it's asking."
        }
    }

    /// The whole judgement in one call, for a proxy that needs the request or nothing.
    public static func approvalRequest(id: String, for call: AgentToolCall) -> AgentApprovalRequest? {
        guard let category = classify(call) else { return nil }
        return AgentApprovalRequest(id: id,
                                    call: call,
                                    category: category,
                                    reason: reason(for: call, category: category))
    }

    // MARK: - macOS

    /// Reading the screen and moving between apps. None of it changes anything the user
    /// can't undo by looking somewhere else.
    static let macosAutomaticTools: Set<String> = [
        "capture_screen", "list_applications", "list_windows",
        "open_application", "activate_application", "accessibility_tree",
        "scroll", "set_volume",
    ]

    private static func classifyMacOS(_ call: AgentToolCall) -> ApprovalCategory? {
        if macosAutomaticTools.contains(call.tool) { return nil }

        switch call.tool {
        case "type_text":
            return .typing
        case "press_key":
            return keyCategory(in: call)
        case "close_window", "quit_application":
            return .closingOrQuitting
        case "click_element", "click_coordinate":
            // Clicking an ordinary control is automatic per the spec, and most clicks
            // are exactly that. The exceptions are the ones where the button's own text
            // is the only evidence available: a click inside System Settings changes a
            // system setting, and "Place order" spends money, with no argument on the
            // call to say so.
            if mentionsSystemSettings(call) { return .systemSettings }
            return textIntentCategory(in: call)
        default:
            return .unknown
        }
    }

    private static let systemSettingsApps = [
        "system settings", "system preferences", "systemsettings", "systempreferences",
    ]

    private static func mentionsSystemSettings(_ call: AgentToolCall) -> Bool {
        haystack(call).contains { text in
            systemSettingsApps.contains { text.contains($0) }
        }
    }

    // MARK: - Chrome

    static let chromeAutomaticTools: Set<String> = [
        "browser_navigate", "browser_navigate_back", "browser_snapshot",
        "browser_take_screenshot", "browser_hover", "browser_select_option",
        "browser_mouse_wheel", "browser_wait_for", "browser_resize",
        "browser_console_messages", "browser_network_requests",
    ]

    private static func classifyChrome(_ call: AgentToolCall) -> ApprovalCategory? {
        if chromeAutomaticTools.contains(call.tool) { return nil }

        switch call.tool {
        case "browser_type", "browser_fill_form":
            // Including a search box. The spec says all of it, and it's right to: a
            // search box on the wrong page is a message box, and by the time the gate
            // could tell them apart the text has been sent.
            return .typing
        case "browser_press_key":
            return keyCategory(in: call)
        case "browser_click":
            return textIntentCategory(in: call)
        case "browser_close":
            return .closingOrQuitting
        case "browser_tabs":
            // One tool, several verbs — judge the verb, the way SmartThings judges the
            // capability.
            switch call.arguments["action"]?.lowercased() {
            case "list", "new", "select", "switch", nil: return nil
            case "close": return .closingOrQuitting
            default: return .unknown
            }
        case "browser_handle_dialog":
            // Deliberately not automatic. The dialog this accepts might be a cookie
            // banner or might be "Delete this account?", and the tool call carries the
            // answer, not the question.
            return .unknown
        default:
            return .unknown
        }
    }

    // MARK: - SmartThings

    /// Inventory and status. Reads, and the spec wants them fast — resolving a device
    /// name shouldn't cost a confirmation.
    static let smartthingsAutomaticTools: Set<String> = [
        "list_locations", "list_rooms", "list_devices",
        "device_status", "device_capabilities", "refresh_inventory", "list_scenes",
    ]

    /// Capabilities that are ordinary and reversible: press it again and the house is
    /// as it was.
    static let reversibleCapabilities: Set<String> = [
        "switch", "switchlevel", "colorcontrol", "colortemperature",
        "audiovolume", "audiomute", "mediaplayback", "mediainputsource",
        "fanspeed", "refresh",
    ]

    /// Capabilities that open a house or disarm it. Not a superset of "things called a
    /// lock" — a *capability*, which is the only part of a SmartThings call the user
    /// didn't get to name.
    static let securityCapabilities: Set<String> = [
        "lock", "doorcontrol", "garagedoorcontrol", "securitysystem",
        "alarm", "panicalarm", "smartlock",
    ]

    private static func classifySmartThings(_ call: AgentToolCall) -> ApprovalCategory? {
        if smartthingsAutomaticTools.contains(call.tool) { return nil }

        switch call.tool {
        case "send_device_command":
            return capabilityCategory(call.arguments["capability"])
        case "run_scene":
            // A scene is a stored list of commands the app can't see from here. One of
            // them may be a lock. Nothing else about this call can rule that out.
            return .unknown
        default:
            return .unknown
        }
    }

    /// Judge a SmartThings command by its capability and nothing else.
    ///
    /// The device *label* is the tempting signal and the wrong one, in both directions.
    /// "Front Door Light" contains the word door and is a lamp; a deadbolt the user
    /// named "Lamp" is still a deadbolt. Labels are user-chosen strings that drift,
    /// duplicate, and get inherited from whoever set the device up — the capability is
    /// the part SmartThings itself guarantees.
    ///
    /// This is the opposite of how clicks are judged, on purpose. A click has no
    /// structured field to read, so its text is scanned and the scan can only ever *add*
    /// a confirmation. Here there is an authoritative field, and reading the label would
    /// let a name *remove* one.
    static func capabilityCategory(_ capability: String?) -> ApprovalCategory? {
        guard let raw = capability?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            // A command with no capability isn't a command we can judge.
            return .unknown
        }
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if securityCapabilities.contains(key) { return .security }
        if reversibleCapabilities.contains(key) { return nil }
        // Everything else — `valve`, `thermostatMode`, a capability shipped by a custom
        // driver last week. Unrecognised means unjudged, and unjudged means ask.
        return .unknown
    }

    // MARK: - Control

    private static func classifyControl(_ call: AgentToolCall) -> ApprovalCategory? {
        switch call.tool {
        case "escalate_model", "request_approval":
            // Neither touches the user's machine. `request_approval` is how the model
            // volunteers a confirmation it thinks it needs; gating the act of asking
            // would be a loop.
            return nil
        default:
            return .unknown
        }
    }

    // MARK: - Keys

    /// Keys that navigate rather than commit. Modifier-free, and the list is short on
    /// purpose — "press approved keys" reads as a list of what's approved, not as
    /// permission for whatever the model names.
    static let automaticKeys: Set<String> = [
        "escape", "esc", "tab", "up", "down", "left", "right",
        "arrowup", "arrowdown", "arrowleft", "arrowright",
        "pageup", "pagedown", "home", "end",
    ]

    static let submitKeys: Set<String> = ["enter", "return", "keypadenter", "numpadenter"]
    static let deleteKeys: Set<String> = ["delete", "backspace", "forwarddelete", "del"]

    private static let keyArgumentNames = ["key", "keys", "combination", "shortcut", "keystroke"]

    private static func keyCategory(in call: AgentToolCall) -> ApprovalCategory? {
        guard let raw = keyArgumentNames.compactMap({ call.arguments[$0] }).first,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unknown
        }

        let parts = raw.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
        guard let key = parts.last else { return .unknown }

        let modifiers = Set(parts.dropLast())
        let command = modifiers.contains("cmd") || modifiers.contains("command") || modifiers.contains("meta")

        if command {
            // ⌘Q and ⌘W are the two shortcuts that end things, and a model that means
            // "close this" reaches for them far more often than for the menu item.
            if key == "q" || key == "w" { return .closingOrQuitting }
            if deleteKeys.contains(key) { return .deletion }
            // ⌘Tab is app switching, which is automatic everywhere else in this file.
            if key == "tab" { return nil }
            // ⌘Return submits in most apps that have a compose field.
            if submitKeys.contains(key) { return .typing }
            // Every other ⌘-combination is an app's own menu shortcut, and what it does
            // depends entirely on which app is frontmost. That's unjudgeable from here.
            return .unknown
        }

        if submitKeys.contains(key) { return .typing }
        if deleteKeys.contains(key) { return .deletion }
        if modifiers.isEmpty, automaticKeys.contains(key) { return nil }
        // A bare letter is typing one character, and a modifier we didn't account for
        // could be anything.
        return .unknown
    }

    // MARK: - Reading intent out of a click

    /// Words that mean money is about to move. Scanned against the element description
    /// and every argument value, because for a click that text is all there is.
    static let purchaseKeywords: [String] = [
        "buy now", "buy ", "checkout", "check out", "place order", "place your order",
        "complete purchase", "confirm purchase", "confirm order", "pay now", "pay ",
        "payment", "subscribe", "start subscription", "renew", "add funds", "donate",
        "purchase", "order now", "proceed to pay",
    ]

    static let deletionKeywords: [String] = [
        "delete", "remove ", "erase", "clear history", "clear data", "clear browsing",
        "empty trash", "move to trash", "deactivate", "close account", "unsubscribe all",
    ]

    /// A click's category derived from its own text, or nil for the ordinary case.
    ///
    /// This is a heuristic and is written down as one: it catches "Place order" and will
    /// miss a checkout button that only says "Continue". It exists because missing it
    /// costs a purchase and the false positives cost one keystroke — the asymmetry runs
    /// entirely one way, so the scan is broad on purpose.
    private static func textIntentCategory(in call: AgentToolCall) -> ApprovalCategory? {
        let texts = haystack(call)
        if texts.contains(where: { text in purchaseKeywords.contains { text.contains($0) } }) {
            return .purchase
        }
        if texts.contains(where: { text in deletionKeywords.contains { text.contains($0) } }) {
            return .deletion
        }
        return nil
    }

    /// The target plus every argument value, lowercased and padded so a keyword ending
    /// in a space ("pay ") still matches a value that is exactly that word.
    private static func haystack(_ call: AgentToolCall) -> [String] {
        var texts = call.arguments.values.map { " \($0.lowercased()) " }
        if let target = call.target { texts.append(" \(target.lowercased()) ") }
        return texts
    }
}
