import Foundation

/// The fixed set of tools Agent Mode may ever call, and the shape a call has to have
/// to be considered at all.
///
/// This is a *positive* list, and that is the whole point of it. A denylist can only
/// name the tools that exist today: Claude Code ships new built-ins regularly, and the
/// first release that adds a file tool we never heard of would silently hand the
/// assistant a second, unproxied route to the user's disk. Nothing reaches a downstream
/// server unless it is written down here, so a tool added anywhere else — upstream, in
/// a server update, or by a model guessing a plausible name — is refused by default
/// rather than by vigilance.
///
/// The denylist below is belt-and-braces on top of that, not the boundary. It catches
/// the case the positive list can't: someone editing this file later and adding
/// `browser_run_code_unsafe` to a server's set because the task in front of them needed
/// it. `isAllowed` runs both checks, so that edit still doesn't take effect.
///
/// Names are `mcp__<server>__<tool>`, matching how Claude Code namespaces MCP tools.
/// The proxy exposes them under exactly these names and strips the prefix on the way
/// down to the real server, which is what makes one name meaningful in both the panel
/// and the wire protocol.
public enum AgentToolAllowlist {

    // MARK: - Names

    public static let prefix = "mcp__"
    static let separator = "__"

    public static func qualifiedName(server: MCPServerID, tool: String) -> String {
        "\(prefix)\(server.rawValue)\(separator)\(tool)"
    }

    /// Split a qualified name back into a server and a bare tool name, or nil if it
    /// isn't one. Rejecting the shape *before* any lookup is deliberate: a bare `Bash`
    /// or a `mcp__someone_elses_server__x` never reaches a set membership test, so
    /// adding a server enum case is the only way to widen what can be addressed.
    public static func reference(forQualifiedName name: String) -> AgentToolRef? {
        guard name.hasPrefix(prefix) else { return nil }
        let body = String(name.dropFirst(prefix.count))
        guard let range = body.range(of: separator) else { return nil }
        let serverPart = String(body[body.startIndex..<range.lowerBound])
        let tool = String(body[range.upperBound...])
        guard !tool.isEmpty, let server = MCPServerID(rawValue: serverPart) else { return nil }
        // A second `__` inside the tool name would let one name parse two ways, and two
        // readings of a name is one more than a security boundary can afford. The
        // character check is the same argument: `escalate_model ` and `escalate_model`
        // must not be two spellings of one tool, because only one of them is the one
        // anybody compared against a list.
        guard !tool.contains(separator) else { return nil }
        guard tool.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        return AgentToolRef(server: server, tool: tool)
    }

    // MARK: - The list

    /// macOS desktop control, via `mcp-macos-cua`.
    ///
    /// Bounded verbs only. There is no "run AppleScript", no "run this command", and no
    /// tool that takes a script of any kind — the spec rules those out, and a proxy that
    /// exposed one would be gating the wrapper while leaving the payload unread.
    static let macosTools: Set<String> = [
        "capture_screen",
        "list_applications",
        "list_windows",
        "open_application",
        "activate_application",
        "accessibility_tree",
        "click_element",
        "click_coordinate",
        "scroll",
        "press_key",
        "type_text",
        "close_window",
        "quit_application",
        "set_volume",
        "set_brightness",
        "media_control",
    ]

    /// Chrome, via Microsoft's `playwright-mcp` in extension mode.
    ///
    /// `browser_evaluate` and `browser_run_code_unsafe` are the two tools that server
    /// offers which would end this boundary — arbitrary JavaScript in a page can click,
    /// type, submit, and read every cookie the profile holds without ever naming a tool
    /// the gate would recognise. They are absent here and, because "eval" and "run_code"
    /// are forbidden fragments, they cannot be re-added by editing this set alone.
    static let chromeTools: Set<String> = [
        "browser_navigate",
        "browser_navigate_back",
        "browser_snapshot",
        "browser_take_screenshot",
        "browser_click",
        "browser_hover",
        "browser_select_option",
        "browser_type",
        "browser_fill_form",
        "browser_press_key",
        "browser_scroll",
        "browser_wait_for",
        "browser_tabs",
        "browser_resize",
        "browser_console_messages",
        "browser_network_requests",
        "browser_handle_dialog",
        "browser_close",
    ]

    /// SmartThings, via the app's own adapter around `smartthings-cli`.
    ///
    /// One command verb, not one tool per capability: the spec wants every device
    /// command the account can reach, and enumerating them here would go stale the
    /// first time the user adds a device. What keeps that safe is that the *arguments*
    /// are structured — `ActionRiskPolicy` judges the capability, so a new device
    /// arrives already classified. The CLI itself is never addressable: there is no
    /// tool here that takes a command string.
    static let smartthingsTools: Set<String> = [
        "list_locations",
        "list_rooms",
        "list_devices",
        "device_status",
        "device_capabilities",
        "refresh_inventory",
        "send_device_command",
        "list_scenes",
        "run_scene",
    ]

    /// The app's own tools. These exist because the spec requires escalation and
    /// approval to be structured calls rather than prose the runtime has to recognise
    /// in a sentence — "this is hard" is not a control channel.
    static let controlTools: Set<String> = [
        "escalate_model",
        "request_approval",
    ]

    public static func tools(for server: MCPServerID) -> Set<String> {
        switch server {
        case .macos: return macosTools
        case .chrome: return chromeTools
        case .smartthings: return smartthingsTools
        case .control: return controlTools
        }
    }

    /// Every allowed tool, in a stable order so `tools/list` output and test failures
    /// don't reshuffle between runs.
    public static var allTools: [AgentToolRef] {
        MCPServerID.allCases.flatMap { server in
            tools(for: server).sorted().map { AgentToolRef(server: server, tool: $0) }
        }
    }

    // MARK: - The gate

    public static func isAllowed(_ qualifiedName: String) -> Bool {
        guard let ref = reference(forQualifiedName: qualifiedName) else { return false }
        return isAllowed(server: ref.server, tool: ref.tool)
    }

    public static func isAllowed(server: MCPServerID, tool: String) -> Bool {
        guard tools(for: server).contains(tool) else { return false }
        // Belt and braces, and it runs last on purpose: it is the check that survives
        // someone adding a name to the set above.
        return !isForbiddenName(tool)
    }

    // MARK: - Belt and braces

    /// Claude Code's own tools, disabled by name as well as by omission.
    ///
    /// The runtime passes these to `--disallowed-tools`. That is redundant with the
    /// allowlist and worth doing anyway: it means a misconfigured allowlist and a
    /// misconfigured launch have to fail *together* before Claude gets a file tool.
    /// The list is what ships today; the shape check is what covers what ships next.
    public static let deniedBuiltInTools: [String] = [
        "Bash", "BashOutput", "KillBash", "KillShell",
        "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead",
        "Glob", "Grep", "LS",
        "WebFetch", "WebSearch",
        "Task", "Agent", "Skill", "SlashCommand", "TodoWrite", "ExitPlanMode",
    ]

    /// Substrings that describe a capability this feature must never have, whatever the
    /// tool containing them claims to do.
    ///
    /// Matched case-insensitively against the bare tool name. `eval` catches
    /// `browser_evaluate`; `exec`, `shell`, and `bash` catch every flavour of "just run
    /// this"; `applescript`/`osascript` catch the macOS server's escape hatch. This is
    /// why the SmartThings command verb is `send_device_command` and not
    /// `execute_command` — a name that trips this list would be denied at runtime while
    /// looking allowed in the source, which is a worse failure than the awkward name.
    static let forbiddenFragments: [String] = [
        "eval", "run_code", "javascript", "applescript", "osascript",
        "shell", "exec", "bash", "spawn", "subprocess", "unsafe",
        "passthrough", "arbitrary", "raw_command", "command_line",
        "read_file", "write_file", "delete_file", "file_read", "file_write",
    ]

    public static func isForbiddenName(_ tool: String) -> Bool {
        let lowered = tool.lowercased()
        if deniedBuiltInTools.contains(where: { $0.lowercased() == lowered }) { return true }
        return forbiddenFragments.contains { lowered.contains($0) }
    }
}

/// A tool name that has already been parsed — a server and a bare tool, never a string
/// two layers still have to agree about how to split.
public struct AgentToolRef: Equatable, Hashable, Sendable {
    public var server: MCPServerID
    public var tool: String

    public init(server: MCPServerID, tool: String) {
        self.server = server
        self.tool = tool
    }

    public var qualifiedName: String {
        AgentToolAllowlist.qualifiedName(server: server, tool: tool)
    }
}

// MARK: - Redaction

/// Turns raw tool arguments into the display-safe `[String: String]` an `AgentToolCall`
/// carries.
///
/// It lives on the way *out* of the proxy so that redaction happens once, at the only
/// point that sees the raw call. Everything downstream — the panel, the transcript, the
/// log — then handles arguments that are already safe, instead of each having to
/// remember. The spec's rule is narrow ("where the server identifies them as sensitive")
/// so `serverDeclared` carries what the tool schema marked; the fragment list is the
/// backstop for servers that mark nothing, which is most of them.
public enum AgentArgumentRedaction {
    public static let placeholder = "•••"

    /// Longest argument value the panel will show. A page snapshot passed back as an
    /// argument is thousands of characters of markup that tells the user nothing about
    /// what they are approving.
    public static let maxValueLength = 200

    /// Matched as substrings of the argument name, lowercased.
    ///
    /// Note what is *not* here: a bare `key`. `press_key`'s argument is called `key`,
    /// and redacting it would hide the one fact the approval panel exists to show —
    /// whether the assistant is about to press Escape or ⌘Q. Secrets are named
    /// `api_key`, `access_key`, or `secret`, and those are matched instead.
    static let sensitiveNameFragments: [String] = [
        "password", "passwd", "passphrase", "passcode", "secret", "token",
        "credential", "api_key", "apikey", "access_key", "private_key",
        "cvv", "card_number", "cardnumber", "ssn", "otp", "one_time",
        "authorization", "auth_header", "session_id", "cookie",
    ]

    public static func isSensitive(name: String, serverDeclared: Set<String>) -> Bool {
        if serverDeclared.contains(name) { return true }
        let lowered = name.lowercased()
        return sensitiveNameFragments.contains { lowered.contains($0) }
    }

    public static func displayArguments(_ raw: [String: String],
                                        serverDeclared: Set<String> = []) -> [String: String] {
        var safe: [String: String] = [:]
        safe.reserveCapacity(raw.count)
        for (name, value) in raw {
            if isSensitive(name: name, serverDeclared: serverDeclared) {
                safe[name] = placeholder
            } else if value.count > maxValueLength {
                safe[name] = String(value.prefix(maxValueLength)) + "…"
            } else {
                safe[name] = value
            }
        }
        return safe
    }
}
