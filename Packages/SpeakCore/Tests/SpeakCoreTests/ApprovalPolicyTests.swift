import Testing
import Foundation
@testable import SpeakCore

// The approval gate is the security boundary of Agent Mode, and these tests are the
// part of it that survives a refactor. They are written to fail loudly when someone
// widens the boundary — including when widening it is exactly what the task in front of
// them seemed to need.

// MARK: - What may be called at all

@Suite("Agent tool allowlist")
struct AgentToolAllowlistTests {

    @Test("An allowlisted tool passes under its qualified name")
    func allowlisted() {
        #expect(AgentToolAllowlist.isAllowed("mcp__macos__click_element"))
        #expect(AgentToolAllowlist.isAllowed("mcp__chrome__browser_navigate"))
        #expect(AgentToolAllowlist.isAllowed("mcp__smartthings__send_device_command"))
        #expect(AgentToolAllowlist.isAllowed("mcp__control__escalate_model"))
    }

    /// The whole reason the list is positive. Nobody can enumerate the tools Claude Code
    /// or a server update will add; this is what happens to them by default.
    @Test("A tool invented after this file was written is denied", arguments: [
        "mcp__macos__run_applescript",
        "mcp__macos__execute_command",
        "mcp__chrome__browser_run_code_unsafe",
        "mcp__chrome__browser_evaluate",
        "mcp__smartthings__shell",
        "mcp__control__read_project_file",
        "mcp__macos__click_element_v2",
        "mcp__chrome__browser_download_file",
    ])
    func inventedToolsDenied(name: String) {
        #expect(!AgentToolAllowlist.isAllowed(name))
    }

    /// A model that never saw the tool in `tools/list` can still put any string in a
    /// `tools/call`. Nothing that isn't `mcp__<known server>__<tool>` gets that far.
    @Test("Anything that isn't the qualified shape is denied", arguments: [
        "Bash", "Read", "browser_click", "click_element",
        "mcp__macos", "mcp__macos__", "mcp____click_element",
        "mcp__filesystem__read_file", "mcp__MACOS__click_element",
        "macos__click_element", "mcp__macos__click__element",
        "", "mcp__", "__", "mcp__control__escalate_model ",
    ])
    func shapeIsRequired(name: String) {
        #expect(!AgentToolAllowlist.isAllowed(name))
        #expect(AgentToolAllowlist.reference(forQualifiedName: name) == nil)
    }

    @Test("Claude Code's own file and shell tools are denied by name too")
    func builtInsDenied() {
        for tool in ["Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit", "Bash"] {
            #expect(AgentToolAllowlist.deniedBuiltInTools.contains(tool),
                    "\(tool) is named in the spec and must stay in --disallowed-tools")
            #expect(AgentToolAllowlist.isForbiddenName(tool))
            #expect(!AgentToolAllowlist.isAllowed(tool))
            // Wrapping a built-in in the MCP shape doesn't launder it.
            #expect(!AgentToolAllowlist.isAllowed("mcp__macos__\(tool)"))
        }
    }

    /// Belt and braces, and the case it exists for: a future edit that adds one of these
    /// to a server's set because a task needed it. The set membership would pass; this
    /// still doesn't.
    @Test("Arbitrary-code tools are refused by name whatever list they're in", arguments: [
        "browser_run_code_unsafe", "browser_evaluate", "evaluate_javascript",
        "run_applescript", "osascript", "execute_shell", "bash_command",
        "spawn_process", "raw_command_passthrough", "read_file", "write_file",
    ])
    func forbiddenFragments(tool: String) {
        #expect(AgentToolAllowlist.isForbiddenName(tool))
        for server in MCPServerID.allCases {
            #expect(!AgentToolAllowlist.isAllowed(server: server, tool: tool),
                    "\(tool) must stay denied on \(server.rawValue)")
        }
    }

    /// The inverse check: nothing currently allowed trips the fragment list. If it did,
    /// the tool would read as allowed here and be refused at runtime — the worst of both.
    @Test("No allowlisted tool collides with the forbidden fragments")
    func listsAgree() {
        for ref in AgentToolAllowlist.allTools {
            #expect(!AgentToolAllowlist.isForbiddenName(ref.tool),
                    "\(ref.qualifiedName) is listed but would be refused by name")
            #expect(AgentToolAllowlist.isAllowed(ref.qualifiedName))
        }
    }

    @Test("Names round-trip through parsing")
    func roundTrip() {
        for ref in AgentToolAllowlist.allTools {
            #expect(AgentToolAllowlist.reference(forQualifiedName: ref.qualifiedName) == ref)
        }
    }

    /// Chrome is allowed, and the two tools on it that would end the boundary are not.
    @Test("An allowed server does not make every one of its tools allowed")
    func serverIsNotBlanket() {
        #expect(AgentToolAllowlist.isAllowed("mcp__chrome__browser_click"))
        #expect(!AgentToolAllowlist.isAllowed("mcp__chrome__browser_run_code_unsafe"))
        #expect(!AgentToolAllowlist.isAllowed("mcp__chrome__browser_evaluate"))
        #expect(!AgentToolAllowlist.isAllowed("mcp__macos__run_applescript"))
        #expect(!AgentToolAllowlist.isAllowed("mcp__chrome__browser_file_upload"))
    }
}

// MARK: - Redaction

@Suite("Tool argument redaction")
struct AgentArgumentRedactionTests {

    @Test("Secrets are replaced before they can reach a panel or a log", arguments: [
        "password", "user_password", "api_key", "apiKey", "access_key",
        "token", "refresh_token", "cvv", "card_number", "otp", "cookie",
    ])
    func secretsRedacted(name: String) {
        let safe = AgentArgumentRedaction.displayArguments([name: "hunter2"])
        #expect(safe[name] == AgentArgumentRedaction.placeholder)
    }

    /// `press_key`'s argument is called `key`, and it is the one fact the approval panel
    /// exists to show. Redacting it would hide whether the assistant is pressing Escape
    /// or ⌘Q.
    @Test("The key of press_key is not treated as a secret")
    func pressKeySurvives() {
        let safe = AgentArgumentRedaction.displayArguments(["key": "cmd+q"])
        #expect(safe["key"] == "cmd+q")
    }

    @Test("A server that declares a field sensitive is believed")
    func serverDeclared() {
        let safe = AgentArgumentRedaction.displayArguments(["pairing": "1234"],
                                                           serverDeclared: ["pairing"])
        #expect(safe["pairing"] == AgentArgumentRedaction.placeholder)
    }

    @Test("Huge values are clipped so the panel stays readable")
    func longValuesClipped() {
        let snapshot = String(repeating: "a", count: 5_000)
        let safe = AgentArgumentRedaction.displayArguments(["snapshot": snapshot])
        #expect(safe["snapshot"]?.count == AgentArgumentRedaction.maxValueLength + 1)
        #expect(safe["snapshot"]?.hasSuffix("…") == true)
    }
}

// MARK: - Classification

@Suite("Action risk policy")
struct ActionRiskPolicyTests {

    private func call(_ server: MCPServerID,
                      _ tool: String,
                      target: String? = nil,
                      _ arguments: [String: String] = [:]) -> AgentToolCall {
        AgentToolCall(id: "c1", server: server, tool: tool, target: target, arguments: arguments)
    }

    // MARK: Automatic

    @Test("Looking, opening, and switching run without asking", arguments: [
        "capture_screen", "list_applications", "list_windows",
        "open_application", "activate_application", "accessibility_tree", "scroll",
    ])
    func macosReadsAreAutomatic(tool: String) {
        #expect(ActionRiskPolicy.classify(call(.macos, tool, target: "Safari")) == nil)
    }

    @Test("Ordinary reversible device controls run without asking", arguments: [
        "set_volume", "set_brightness", "media_control",
    ])
    func mediaControlsAreAutomatic(tool: String) {
        #expect(ActionRiskPolicy.classify(call(.macos, tool)) == nil)
    }

    @Test("Reading and navigating the web runs without asking", arguments: [
        "browser_navigate", "browser_navigate_back", "browser_snapshot",
        "browser_take_screenshot", "browser_hover", "browser_scroll",
        "browser_wait_for", "browser_console_messages", "browser_network_requests",
    ])
    func chromeReadsAreAutomatic(tool: String) {
        #expect(ActionRiskPolicy.classify(call(.chrome, tool, target: "example.com")) == nil)
    }

    @Test("An ordinary click is not an approval")
    func ordinaryClick() {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_click", target: "Next page")) == nil)
        #expect(ActionRiskPolicy.classify(call(.macos, "click_element", target: "Sidebar toggle")) == nil)
    }

    // MARK: Typing

    /// The spec says all of it, including a search box, and the reason is that the gate
    /// can't tell a search box from a message box until after the text has gone.
    @Test("Every kind of typing needs approval")
    func typingNeedsApproval() {
        #expect(ActionRiskPolicy.classify(call(.macos, "type_text", ["text": "hello"])) == .typing)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_type",
                                               target: "Search",
                                               ["text": "weather"])) == .typing)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_fill_form")) == .typing)
    }

    @Test("Return submits, and submitting is typing", arguments: ["enter", "Return", "cmd+Return"])
    func submitKeys(key: String) {
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": key])) == .typing)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_press_key", ["key": key])) == .typing)
    }

    @Test("Navigation keys are approved keys", arguments: [
        "Escape", "tab", "PageDown", "ArrowDown", "home", "end", "cmd+Tab",
    ])
    func navigationKeys(key: String) {
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": key])) == nil)
    }

    /// "Press approved keys" reads as a list of what's approved. A letter is one
    /// character of typing; an unrecognised ⌘-combination is whatever the frontmost app
    /// decided it means, which is not something this file can know.
    @Test("Unapproved keys and app shortcuts stop", arguments: [
        "a", "cmd+s", "cmd+shift+3", "ctrl+alt+f7", "f13", "space",
    ])
    func unapprovedKeys(key: String) {
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": key])) == .unknown)
    }

    @Test("A key press with no key argument is unjudgeable")
    func missingKeyArgument() {
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key")) == .unknown)
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": "  "])) == .unknown)
    }

    // MARK: Closing, deleting, settings, purchases

    @Test("Closing and quitting need approval")
    func closingNeedsApproval() {
        #expect(ActionRiskPolicy.classify(call(.macos, "close_window", target: "Notes")) == .closingOrQuitting)
        #expect(ActionRiskPolicy.classify(call(.macos, "quit_application", target: "Notes")) == .closingOrQuitting)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_close")) == .closingOrQuitting)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_tabs", ["action": "close"])) == .closingOrQuitting)
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": "cmd+q"])) == .closingOrQuitting)
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": "cmd+W"])) == .closingOrQuitting)
    }

    @Test("Tab housekeeping that isn't closing stays automatic", arguments: ["list", "new", "select"])
    func tabActions(action: String) {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_tabs", ["action": action])) == nil)
    }

    @Test("A tab verb nobody wrote down here stops")
    func unknownTabAction() {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_tabs", ["action": "detach"])) == .unknown)
    }

    @Test("Deleting needs approval")
    func deletionNeedsApproval() {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_click",
                                               target: "Delete account")) == .deletion)
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_click",
                                               target: "Clear browsing data")) == .deletion)
        #expect(ActionRiskPolicy.classify(call(.macos, "press_key", ["key": "cmd+delete"])) == .deletion)
    }

    @Test("Spending money stops, however the button is worded", arguments: [
        "Buy now", "Place order", "Proceed to checkout", "Pay", "Complete purchase",
        "Subscribe", "Confirm order",
    ])
    func purchasesStop(label: String) {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_click", target: label)) == .purchase)
        #expect(ActionRiskPolicy.classify(call(.macos, "click_element", target: label)) == .purchase)
    }

    /// A click inside System Settings is a settings change, and the button's own text is
    /// the only evidence the call carries.
    @Test("Clicking inside System Settings is a settings change")
    func systemSettingsClick() {
        #expect(ActionRiskPolicy.classify(call(.macos, "click_element",
                                               target: "System Settings")) == .systemSettings)
        #expect(ActionRiskPolicy.classify(call(.macos, "click_coordinate",
                                               ["app": "System Preferences"])) == .systemSettings)
    }

    // MARK: Uncertainty

    /// The single most important line in the policy. An unrecognised tool must fail
    /// safe, and "safe" is asking, not running.
    @Test("A tool that does not exist requires approval", arguments: [
        "teleport_window", "browser_do_the_thing", "reticulate_splines",
        "click_element_2", "sudo",
    ])
    func unknownToolsRequireApproval(tool: String) {
        for server in MCPServerID.allCases {
            #expect(ActionRiskPolicy.classify(call(server, tool)) == .unknown,
                    "\(server.rawValue)/\(tool) fell through to automatic")
        }
    }

    /// Defence in depth: the proxy refuses these long before classification, and if that
    /// check were ever removed the policy still doesn't call them safe.
    @Test("A denied tool is never classified automatic")
    func deniedToolsAreNotAutomatic() {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_run_code_unsafe",
                                               ["code": "fetch('/logout')"])) == .unknown)
        #expect(ActionRiskPolicy.classify(call(.macos, "run_applescript")) == .unknown)
        #expect(ActionRiskPolicy.classify(call(.macos, "Bash", ["command": "ls"])) == .unknown)
    }

    @Test("A dialog is answered without the gate seeing the question")
    func dialogsStop() {
        #expect(ActionRiskPolicy.classify(call(.chrome, "browser_handle_dialog",
                                               ["accept": "true"])) == .unknown)
    }

    /// Every allowlisted tool must have been thought about. A tool added to the
    /// allowlist without a line in this policy falls to `.unknown`, which is safe but
    /// means every use of it prompts — this test is what makes that a decision rather
    /// than a surprise.
    @Test("Every allowlisted tool is deliberately classified")
    func policyCoversTheAllowlist() {
        // Tools whose category genuinely depends on their arguments, and which are
        // therefore expected to be `.unknown` when called bare.
        let argumentDependent: Set<String> = [
            "press_key", "browser_press_key", "send_device_command", "run_scene",
            "browser_handle_dialog",
        ]
        for ref in AgentToolAllowlist.allTools where !argumentDependent.contains(ref.tool) {
            let category = ActionRiskPolicy.classify(
                AgentToolCall(id: "c", server: ref.server, tool: ref.tool))
            #expect(category != .unknown,
                    "\(ref.qualifiedName) has no line in ActionRiskPolicy")
        }
    }
}

// MARK: - SmartThings

@Suite("SmartThings capabilities, not device names")
struct SmartThingsRiskTests {

    private func command(capability: String,
                         command: String = "on",
                         label: String) -> AgentToolCall {
        AgentToolCall(id: "st",
                      server: .smartthings,
                      tool: "send_device_command",
                      target: label,
                      arguments: ["capability": capability, "command": command, "deviceId": "abc"])
    }

    @Test("Reading the house is free", arguments: [
        "list_locations", "list_rooms", "list_devices",
        "device_status", "device_capabilities", "refresh_inventory", "list_scenes",
    ])
    func inventoryIsAutomatic(tool: String) {
        #expect(ActionRiskPolicy.classify(
            AgentToolCall(id: "st", server: .smartthings, tool: tool)) == nil)
    }

    @Test("Lamps are reversible", arguments: [
        "switch", "switchLevel", "colorControl", "colorTemperature",
    ])
    func lampsAreAutomatic(capability: String) {
        #expect(ActionRiskPolicy.classify(command(capability: capability,
                                                  label: "Living Room Lamp")) == nil)
    }

    /// The label says door. The capability says switch. The capability is the one
    /// SmartThings guarantees, and it's a lamp.
    @Test("A lamp called Front Door Light is still a lamp")
    func labelDoesNotAddRisk() {
        #expect(ActionRiskPolicy.classify(command(capability: "switch",
                                                  label: "Front Door Light")) == nil)
        #expect(ActionRiskPolicy.classify(command(capability: "switchLevel",
                                                  label: "Garage Gate Lamp")) == nil)
    }

    /// The direction that matters. If a name could make a capability look safe, renaming
    /// a lock would disarm the gate.
    @Test("A lock the user named Lamp is still a lock", arguments: [
        "lock", "doorControl", "garageDoorControl", "securitySystem", "alarm",
    ])
    func labelDoesNotRemoveRisk(capability: String) {
        #expect(ActionRiskPolicy.classify(command(capability: capability,
                                                  label: "Lamp")) == .security)
        #expect(ActionRiskPolicy.classify(command(capability: capability,
                                                  command: "unlock",
                                                  label: "Kitchen Light")) == .security)
    }

    @Test("Capability matching ignores case and punctuation", arguments: [
        "LOCK", "lock", "Lock", "door-control", "garage_door_control",
    ])
    func capabilityNormalisation(capability: String) {
        #expect(ActionRiskPolicy.capabilityCategory(capability) == .security)
    }

    /// A capability shipped by a custom driver last week is not on either list, and a
    /// water valve is exactly the kind of thing that would quietly land on the automatic
    /// one if the fall-through were "allow".
    @Test("An unrecognised capability asks", arguments: [
        "valve", "thermostatMode", "windowShade", "somethingNew", "",
    ])
    func unknownCapabilityAsks(capability: String) {
        #expect(ActionRiskPolicy.capabilityCategory(capability) == .unknown)
    }

    @Test("A command with no capability is unjudgeable")
    func missingCapability() {
        #expect(ActionRiskPolicy.capabilityCategory(nil) == .unknown)
        #expect(ActionRiskPolicy.classify(
            AgentToolCall(id: "st", server: .smartthings, tool: "send_device_command",
                          arguments: ["deviceId": "abc"])) == .unknown)
    }

    /// A scene is a stored list of commands the adapter can't see from here, and one of
    /// them may be a lock.
    @Test("Running a scene asks, because a scene can contain anything")
    func scenesAsk() {
        #expect(ActionRiskPolicy.classify(
            AgentToolCall(id: "st", server: .smartthings, tool: "run_scene",
                          target: "Good Night")) == .unknown)
    }
}

// MARK: - Requests

@Suite("Approval requests carry the reason the gate acted on")
struct ApprovalRequestTests {

    @Test("An automatic call produces no request")
    func automaticProducesNothing() {
        let call = AgentToolCall(id: "c", server: .macos, tool: "capture_screen")
        #expect(ActionRiskPolicy.approvalRequest(id: "a1", for: call) == nil)
    }

    @Test("A gated call produces a request whose category matches the judgement")
    func gatedProducesRequest() {
        let call = AgentToolCall(id: "c", server: .macos, tool: "type_text",
                                 target: "Mail", arguments: ["text": "hi"])
        let request = ActionRiskPolicy.approvalRequest(id: "a1", for: call)
        #expect(request?.category == .typing)
        #expect(request?.call == call)
        #expect(request?.reason.isEmpty == false)
        #expect(request?.reason.contains("Mail") == true)
    }

    @Test("Every category has a reason a person can act on")
    func everyCategoryExplains() {
        let call = AgentToolCall(id: "c", server: .macos, tool: "type_text")
        for category in ApprovalCategory.allCases {
            let reason = ActionRiskPolicy.reason(for: call, category: category)
            #expect(reason.count > 20, "\(category) has no usable explanation")
        }
    }

    /// An unrecognised action has to say *which* action, or the user is approving a
    /// blank.
    @Test("The unknown reason names the tool")
    func unknownReasonNamesTool() {
        let call = AgentToolCall(id: "c", server: .chrome, tool: "browser_handle_dialog")
        let reason = ActionRiskPolicy.reason(for: call, category: .unknown)
        #expect(reason.contains("browser_handle_dialog"))
    }
}
