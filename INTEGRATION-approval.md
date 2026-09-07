# Approval gate + MCP proxy — integration notes

Branch `agent/approval`. This slice is the security boundary: the tool allowlist, the
risk policy, the MCP proxy that enforces them, and the launch configuration that makes
the proxy the only MCP server Claude Code can see.

Files owned by this slice:

- `Packages/SpeakCore/Sources/SpeakCore/Agent/AgentToolAllowlist.swift`
- `Packages/SpeakCore/Sources/SpeakCore/Agent/ActionRiskPolicy.swift`
- `Packages/SpeakCore/Tests/SpeakCoreTests/ApprovalPolicyTests.swift`
- `GaithanoSpeak/Agent/MCPApprovalProxy.swift`
- `GaithanoSpeak/Agent/MCPServerConfig.swift`

Nothing else was touched. `AgentTypes.swift` is used as frozen.

---

## 1. The seam for the runtime (spawning Claude Code)

### Launch flags

```swift
let config = MCPServerConfig.proxyConfigJSON()          // --mcp-config <this>
MCPServerConfig.allowedToolsArgument                    // --allowed-tools "mcp__gaithano"
MCPServerConfig.disallowedToolsArgument                 // --disallowed-tools "Bash,Read,Write,…"
```

`--strict-mcp-config` is **required** alongside `--mcp-config`. Without it, Claude Code
also loads the MCP servers in the user's `~/.claude.json`, and a filesystem MCP they
configured last month for their own work becomes a fully-working file tool sitting next
to a proxy that carefully refuses to expose one. Same argument for `--setting-sources ""`
(hooks) — see `ClaudeCLIFormatter` for the version of this reasoning that is already in
production.

### One line in the app entry point

Claude Code spawns its stdio MCP servers itself, so the thing in `--mcp-config` has to be
an executable — but the gate needs the running app, where the panel and the user are. The
executable is therefore this app's own binary in relay mode, copying stdin to a Unix
socket and back. **`GaithanoSpeakApp.swift` (or `main`) must call this before AppKit
starts, and it never returns in relay mode:**

```swift
MCPApprovalProxy.runRelayIfRequested()
```

If that call is missing, Agent Mode has no tools at all: Claude Code spawns a second copy
of the GUI app instead of a server.

### Host side

```swift
let proxy = MCPApprovalProxy(gate: coordinator, observer: coordinator, controlHandler: { tool, args in … })
await proxy.connect(MCPServerConfig.launches(paths: settingsPaths))
Task { await proxy.listen(atPath: MCPServerConfig.socketPath) }   // one session per connection
…
await proxy.shutdown()   // on conversation reset/expiry; terminates the downstream servers
```

`connect` never throws. A server that won't start is logged, left out of the catalogue,
and reported by `MCPServerConfig.availability(paths:)` with a sentence for onboarding to
show. The other capabilities keep working, per the spec.

### Per-run state

```swift
await proxy.beginRun(id: requestID)   // when a user request starts
await proxy.endRun()                  // when it finishes, fails, or is cancelled
```

This is the whole of the "allow all expires with the request" promise on the proxy side.
The grant is stored keyed by run id, not as a flag, so a forgotten `endRun` still can't
let a follow-up inherit blanket approval — the next `beginRun` clears it, and a grant
whose id doesn't match the active run is not in force. Call both anyway.

### Control tools

`controlHandler` receives `("escalate_model", ["reason": .string(…)])` and returns the
text the model sees. If you pass `nil`, the control tools are simply absent from
`tools/list` — the escalation path then has no structured channel, which the spec forbids,
so pass one. `request_approval` arrives the same way; route it into the same panel the
gate uses.

---

## 2. The seam for the panel (approvals)

The proxy asks through one protocol and reports through another. Both are in
`MCPApprovalProxy.swift`:

```swift
protocol AgentApprovalGate: Sendable {
    func decide(_ request: AgentApprovalRequest) async -> ApprovalDecision
}

protocol AgentProxyObserver: Sendable {
    func proxyDidUpdate(call: AgentToolCall, status: AgentStepStatus, detail: String?)
}
```

**`decide` suspends the tool call.** The downstream server does not see the request until
it returns, which is what makes "deny" mean the action never happened. It may take as
long as the user does; there is no timeout, deliberately. The coordinator is expected to:

1. publish `.approvalRequested(request)` into the transcript,
2. await the user's Allow / Deny / Allow-all (`Y` / `N` / `A`),
3. resume the continuation with the `ApprovalDecision`,
4. publish `.approvalResolved(id:decision:)`.

Escape cancels the run: resolve the pending decision with `.deny` **and** call `endRun()`.
The proxy is an actor and is suspended at an `await` while a prompt is up, so `endRun()`
lands immediately rather than queuing behind the decision it is cancelling.

`AgentApprovalRequest.reason` is built by `ActionRiskPolicy.reason(for:category:)` — show
that string verbatim. The panel composing its own explanation is how the displayed reason
drifts from the reason the gate acted on, and the user is the one who finds out.

`proxyDidUpdate` fires for every call, including refused ones, with
`.running` / `.completed` / `.denied` / `.failed` / `.interrupted`. `.interrupted` means
a downstream call threw mid-flight and the outcome is unknown — the spec forbids replaying
one of those blindly, so render it distinctly from `.failed`.

`AgentToolCall.arguments` is already redacted and clipped to 200 characters per value. The
panel does not need to sanitise anything; `AgentArgumentRedaction` did it at the only
point that held the raw call.

---

## 3. `AppSettings` keys this slice needs

None are added here (`AppSettings.swift` belongs to another slice). Three keys, all
`String`, all defaulting to `""` meaning "search the usual install locations":

| Key | Default | Meaning |
| --- | --- | --- |
| `agentMacOSMCPPath` | `""` | Path to the `mcp-macos-cua` executable. |
| `agentSmartThingsMCPPath` | `""` | Path to the `smartthings-cli` MCP adapter. |
| `agentNodeRunnerPath` | `""` | Path to `npx`, used to run `@playwright/mcp`. |

They map straight onto `MCPServerConfig.Paths(macosServer:smartThingsAdapter:nodeRunner:)`.
Remember `AppSettings.init(from:)` decodes every key with a default fallback — add them to
both the memberwise init and the custom decoder, or saved preferences get wiped.

No setting toggles the gate. There is deliberately no "don't ask me again" preference:
"allow all" is per-request by design, and a persistent version of it would be a setting
that silently disables the only boundary this feature has.

---

## 4. Assumptions about siblings' work

- **The runtime owns cancellation of the Claude turn.** The proxy only refuses and reports;
  it does not kill the CLI.
- **The runtime owns screenshots.** The spec's "capture after every completed action" is
  not done here. `proxyDidUpdate(status: .completed)` is the hook to do it on.
- **`AgentStep` construction is the coordinator's.** The proxy emits `(call, status, detail)`
  and lets the transcript own step identity, since `AgentTranscript.apply` already replaces
  steps by id.
- **`MCPServerID.control` is served by the app**, not a subprocess, so `escalate_model`
  reaches the runtime as a structured call rather than prose — the spec requires that.

## 5. Where the spec is ambiguous, and what was assumed

1. **Downstream tool names are unverified.** The allowlist names for `mcp-macos-cua` and
   for the SmartThings adapter (which does not exist yet) are the ones this slice assumes.
   Playwright's are real. A downstream server that names things differently doesn't become
   unsafe — its tools simply don't pass the allowlist and that capability looks empty. When
   the real servers land, `AgentToolAllowlist` is the single place to reconcile names, and
   `ApprovalPolicyTests.policyCoversTheAllowlist` will fail until each new name is
   classified.
2. **"Changing system settings" is not detectable by tool name.** Nothing stops the model
   opening System Settings and clicking. The policy treats a click whose target mentions
   System Settings / System Preferences as `.systemSettings`, which is a heuristic, not a
   boundary. A settings pane reached some other way is not caught.
3. **"Purchases" likewise.** A click is judged by the button's own text, because that is
   all the call carries. "Place order" is caught; a checkout button that says "Continue"
   is not. The scan is broad on purpose — a false positive costs one keystroke.
4. **Downloads are not exposed.** The spec asks for them; the Playwright tool name for it
   wasn't verified, and a download is the one browser action that writes a file. Left off
   until confirmed.
5. **`browser_handle_dialog` always asks.** The tool carries the answer, not the question,
   and the dialog may be a cookie banner or "Delete this account?".
6. **A SmartThings scene always asks.** A scene is a stored list of commands the adapter
   can't see from here, and one of them may be a lock.
