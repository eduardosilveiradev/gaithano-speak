# Agent Mode runtime — integration notes

Branch `agent/runtime`. Files added:

| File | Target | Tested |
| --- | --- | --- |
| `Packages/SpeakCore/Sources/SpeakCore/Agent/AgentModelRouter.swift` | SpeakCore | yes |
| `Packages/SpeakCore/Sources/SpeakCore/Agent/ClaudeCodeStreamParser.swift` | SpeakCore | yes |
| `Packages/SpeakCore/Tests/SpeakCoreTests/AgentRuntimeTests.swift` | SpeakCore | — |
| `GaithanoSpeak/Agent/ClaudeAgentRuntime.swift` | app | no (process + IO) |

Nothing else was touched. `AgentTypes.swift` is unmodified.

## What the coordinator has to do

```swift
// AppEnvironment: one instance, alongside the coordinator.
let agentRuntime = ClaudeAgentRuntime()

// Before the first request, and whenever the MCP proxy restarts its servers:
agentRuntime.configuration = .init(
    executablePath: settings.formatterClaudePath,   // same binary as the formatter
    mcpConfigPath: proxy.publishedConfigPath,       // absolute path to the mcpServers JSON
    allowedTools: proxy.allowedToolNames            // ["mcp__macos__click_element", …]
)

// One consumer, for the life of the app. The stream is unbounded and never finishes.
Task { for await event in agentRuntime.events { transcript.apply(event) } }

// On a finished agent-mode utterance:
agentRuntime.start(request: transcript)   // cancels any turn already running

// Escape, or the panel's stop button:
agentRuntime.cancel()

// "New conversation", and on app termination:
agentRuntime.reset()
```

`start(request:)` is the only entry point that begins work. It cancels an in-flight
turn silently (the `.requestStarted` event clears the panel a moment later anyway),
expires the conversation if it has been idle 15 minutes, resets the ladder to Sonnet,
and resumes the existing Claude Code session when one is still live.

The runtime schedules its own 15-minute expiry; the coordinator does not need a timer.
`expireIfNeeded(now:)` is exposed for a foreground-return check if the panel wants one.

### Events the runtime emits

`.requestStarted`, `.phase`, `.step`, `.responseDelta`, `.responseFinished`,
`.escalated`, `.failed`, `.cancelled`.

### Events it never emits — someone else owns these

- `.partialTranscript` — the coordinator, while the user is still speaking.
- `.approvalRequested` / `.approvalResolved` — the MCP approval proxy. The runtime
  sees an approved call only when it comes back as a `tool_use` line, and a denied one
  as a `tool_result` with `is_error`, which lands as a `.failed` step. If the panel
  needs a `.denied` status rather than `.failed`, the proxy should emit that step
  itself — it is the only component that knows a refusal was the user's.

### Speech

Speak on `.responseFinished`, not on `.responseDelta`. The deltas include narration
from intermediate turns ("Opening Safari…"); the `result` line replaces the whole
response with the final answer, which is the only text the spec allows to be spoken.

## AppSettings keys

**Required: none.** The runtime reuses `formatterClaudePath` — same binary, so a user
who fixed the path once should not have to fix it again.

**Recommended, if the settings owner wants it exposed:**

| Key | Type | Default | Why |
| --- | --- | --- | --- |
| `agentStallTimeoutSeconds` | `Double` | `120` | How long the CLI may emit *nothing* before the turn is declared dead. Not a run timeout — an agent run legitimately takes minutes; silence is the only reliable "it broke" signal. Wire to `Configuration.stallTimeout`. |

Deliberately **not** a setting: which model the run starts on. The spec fixes it at
Sonnet, and a "start on Opus" toggle would make the ladder decorative.

A `agentModelCeiling` setting is worth considering for users whose plan has no Opus —
today every escalation would climb to a model they cannot run and the turn fails with
whatever Claude Code says. The router has no ceiling parameter yet; adding one is a
small change to `AgentModelRouter.escalate` and belongs with whoever owns preflight.

## The `control` MCP server — specified, not built

I did not build the stdio MCP server process, because the approval proxy already has
to stand between Claude Code and every server and is the natural place for one more.
It is small. Requirements:

1. Advertise exactly one tool, from `AgentModelRouter.toolDescriptorJSON` — do not
   retype the name or schema; the constant is what keeps the descriptor, the
   `--allowed-tools` entry, and the sentence in the system prompt from drifting apart.
2. Register under server name `control` (`MCPServerID.control.rawValue`), so Claude
   Code namespaces it as `mcp__control__escalate_model` — the exact string in
   `AgentModelRouter.escalateToolQualifiedName`.
3. On a call, return the text from:

   ```swift
   await runtime.escalationAcknowledgement(callID: <tool_use id>, reason: <arguments.reason>)
   ```

   That method owns the ladder and is idempotent per `callID`, which matters: the same
   escalation reaches the runtime twice — once through the server, once as a `tool_use`
   line on stdout — and the two race. Whichever arrives first moves the ladder; the
   other reads back the same answer instead of climbing a second rung.
4. If the call cannot be routed to the runtime, return
   `"Escalation unavailable — continue the request yourself."` Never return an error:
   a model that thinks help is coming stops working.

The runtime adds `mcp__control__escalate_model` to `--allowed-tools` itself, so the
proxy's `allowedTools` list does not have to include it (including it is harmless).

Escalation still degrades safely if this server is never built: the runtime detects the
tool call on stdout and hands the conversation up the ladder regardless. What is lost is
the acknowledgement telling the losing model to stop, so it keeps working for a few more
seconds before the turn ends.

## Assumptions I made about sibling work

1. **The proxy writes the `--mcp-config` file and hands me its path.** With no path, or
   a path that does not exist, the runtime fails the request with "Agent Mode has no
   tools: its MCP servers haven't started" rather than running Claude with a
   conversation and no way to act — a model that answers as though it had acted is the
   worse failure.
2. **`allowedTools` is a list of fully-qualified `mcp__server__tool` names.** Anything
   not starting with `mcp__` is dropped before the flag is built. This list *is* the
   tool boundary; a caller that could put `Bash` in it would have undone the one
   guarantee Agent Mode makes.
3. **Screenshots reach Claude as MCP image content, from the screenshot service.** The
   runtime never stages an image file — the spec forbids handing Claude a readable path,
   and the Talk provider's `Read`-a-file trick is exactly what must not happen here. The
   parser recognises image blocks in tool results and records them as `[screenshot]`;
   the base64 never enters a step.
4. **The coordinator owns the hotkey and the transcript fold.** The runtime takes a
   finished string.
5. **`Log` gets an `agent` category eventually.** I did not edit `Log.swift` to avoid a
   collision; the runtime builds its own `Logger(subsystem: Log.subsystem, category:
   "agent")`. Fold it into `Log.swift` at merge.
6. **Scratch storage is mine and separate.** `NSTemporaryDirectory()/GaithanoSpeak/agent/<uuid>`,
   not `ClaudeCLIFormatter.workingDirectory` — the formatter and Talk sweep that folder
   on their own schedule, and a conversation whose data must be gone in 15 minutes
   cannot live somewhere another feature deletes from. Stale directories from a previous
   crash are purged at init, which is the spec's "delete expired data on next launch".

## Where the spec does not survive contact

- **"Escalation transfers the complete context" and "must not repeat completed
  actions" are the same requirement, and `--resume` is the only mechanism that
  satisfies both.** Claude Code cannot change model mid-turn, so escalation is: let the
  current turn end, then re-run with `--resume <session> --model <higher>` and a
  continuation prompt. That is why `.escalated` is emitted the moment the tool call is
  seen but the model actually changes a few seconds later — the panel is honest about
  intent, not about which process is alive. If the CLI never reported a session id, the
  runtime **fails the request** rather than starting the stronger model fresh: a
  context-free retry is precisely how a message gets sent twice.
- **"A new request always begins model routing at Sonnet, even when the preceding
  request escalated" fights the resumed session.** The stronger model's reasoning is
  still in the transcript Sonnet resumes into. This is per the spec and implemented as
  written, but it means a follow-up to a Fable-escalated request is answered by Sonnet
  reading Fable's work. If that reads badly in practice, the fix is to keep the tier for
  follow-ups in the same conversation — a one-line change in `start`, and a spec change.
- **"Do not silently substitute a lower model during an active run" has no
  counterpart for a model the plan doesn't include.** If Opus is unavailable, the
  escalated turn fails and the run ends. That is arguably correct (report it, don't
  substitute), but the user sees a raw CLI error. See `agentModelCeiling` above.
- **The 15-minute expiry deletes the scratch directory, but not the CLI's own session
  file.** `claude` writes a transcript per session under `~/.claude`, which is outside
  anything this app owns — the same disclosure `ClaudeCLIFormatter` already carries.
  Onboarding's "screenshots and spoken requests are sent to Anthropic" line should say
  they also land on disk.
- **`AgentModelTier.fable.claudeModelID` is `claude-fable-5-1`**, taken from the frozen
  `AgentTypes.swift`. Nothing here validates that the id is real or available; the
  preflight owner should, since the spec already asks for a "availability of the three
  configured models" check.
