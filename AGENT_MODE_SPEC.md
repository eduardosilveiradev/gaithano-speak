# Agent Mode Specification

## Summary

Agent Mode turns Gaithano Speak into a hold-to-speak macOS assistant powered by an embedded Claude Code session. Claude Code supplies the conversation and reasoning runtime, but none of its coding capabilities. The assistant controls apps, the desktop, Chrome, system devices, and SmartThings through an explicit allowlist of bounded MCP tools. It shows all user-facing activity in a panel, speaks only Claude's final responses, and asks before sensitive actions.

This specification replaces the removed legacy agent implementation. It does not restore or reuse the old screenshot loop, action model, risk policy, or provider backends.

## Goals

- Accept natural-language tasks through a global voice shortcut.
- Use Claude Code as the agent runtime and conversation engine.
- Control macOS apps through a bounded computer-use MCP server.
- Control the user's existing Chrome session through a bounded browser MCP server.
- Control every device and command exposed by `smartthings-cli` through an MCP adapter.
- Preserve conversational context for follow-up requests.
- Make autonomous low-risk actions fast while stopping before sensitive actions.
- Run with no file-reading, file-writing, code-editing, or shell tools.

## Non-goals

- Reading, searching, creating, editing, moving, or deleting files.
- Running shell commands, scripts, AppleScript, or arbitrary code.
- Acting as a coding agent.
- Native messaging integrations.
- Calendar integrations.
- Exposing arbitrary AppleScript, arbitrary browser JavaScript, or unrestricted MCP execution.
- Showing or claiming to show private chain-of-thought. The panel may show concise model-provided status and rationale, but not hidden reasoning tokens.

## Shortcuts

### Transcription

- Shortcut: Right Command + Right Option.
- Behavior: hold to record and release either key to finish.
- Result: transcribe, format, and insert text at the cursor.
- This shortcut never starts Agent Mode.

### Agent Mode

- Shortcut: Left Control + Left Option.
- Hold: start listening when both keys are down. Submit when either key is released.
- Double-tap: toggle hands-free listening on. Press the chord again to stop and submit.
- Escape: immediately cancel listening, the active Claude turn, or the current cancellable tool action.
- Starting another Agent Mode recording while Claude is working cancels the active turn before recording the new request.

Left and right modifier state must be tracked by physical keycode. Generic Control and Option flags are insufficient because they cannot distinguish the two modes.

## Runtime and tool isolation

Each conversation owns one embedded Claude Code session. Claude Code is used only as an assistant runtime. The app starts it from an empty, isolated working directory, but Claude receives no tools that can inspect or modify that directory.

The runtime must enforce these boundaries:

- Disable every built-in Claude Code file and shell tool, including Read, Write, Edit, Glob, Grep, NotebookEdit, Bash, and any equivalent introduced later.
- Use a positive tool allowlist. Do not rely only on a denylist that could miss newly added Claude Code tools.
- Expose only the approved desktop, browser, screenshot, SmartThings, approval, and model-escalation tools defined in this specification.
- Do not mount, copy, or disclose user project files to the runtime.
- Do not pass screenshots as readable file paths. Return them directly as MCP image content.
- MCP processes may receive the macOS permissions needed for their bounded operations, but those permissions do not expand Claude's tool list.
- Conversation reset deletes all app-owned temporary conversation data and retained screenshots.
- App termination deletes expired temporary data on the next launch if an earlier shutdown could not clean it up.

The host app may keep private runtime metadata and screenshots in its own temporary storage. Claude can access that data only when the app deliberately includes it in conversation context or an MCP result.

## Conversation lifecycle

- Requests share one conversation and retain prior user requests, Claude responses, approvals, and tool results.
- The conversation expires after 15 minutes without a user request or active agent work.
- Expiration ends the Claude Code session and deletes its temporary conversation data and screenshots.
- A request arriving before expiration continues the existing conversation.
- A new request always begins model routing at Sonnet, even when the preceding request escalated.
- App relaunch starts a new conversation. Conversation persistence across launches is not required.

## Model routing

The routing hierarchy is:

1. Sonnet
2. Opus
3. Fable 5.1

Sonnet handles every new request first. Sonnet may escalate the active run to Opus when it judges the task too difficult, uncertain, or long-running. Opus may escalate to Fable 5.1 under the same rule.

Escalation requirements:

- Escalation transfers the complete conversation context, current request, screenshots, tool transcript, and completed-action state.
- A run may only move upward. It must never downgrade while active.
- Escalation must not repeat actions already completed.
- The panel must state when escalation occurs and name the new model.
- When the run ends, the next request starts with Sonnet while retaining conversation context.
- Claude Code must be version 2.1.255 or newer so Fable 5.1 is available.

Model escalation should be implemented as an app-owned structured tool or control message. It must not depend on parsing casual prose such as "this is hard."

## MCP integrations

### macOS computer control

Preferred server: `mcp-macos-cua`.

Expose only these bounded capabilities:

- Capture a display screenshot.
- List, open, activate, switch, and inspect applications.
- Read the Accessibility tree for an application or window.
- Click a named UI element or bounded screen coordinate.
- Type text.
- Press approved keys and key combinations.
- Scroll.
- Control ordinary system functions such as volume, playback, display brightness, and other device controls supported by bounded tools.

Do not expose arbitrary AppleScript, shell execution, file operations, or a generic command-execution tool.

### Chrome control

Preferred server: Microsoft's `playwright-mcp` in Chrome extension mode. It must attach to the user's existing Chrome profile and tabs so authenticated sessions, cookies, extensions, SSO, and 2FA state remain available.

Expose navigation, tab management, accessibility snapshots, bounded element interaction, typing, scrolling, downloads, and screenshots. Disable arbitrary JavaScript evaluation, `browser_run_code_unsafe`, and any equivalent unrestricted execution tool.

### SmartThings

Provide a dedicated MCP adapter around `smartthings-cli`.

- Expose every home, room, device, capability, status query, and device command available to the authenticated CLI account.
- Let Claude resolve natural names from live CLI inventory. Existing device names encode room and owner.
- Refresh inventory when a named device cannot be resolved or when the user asks what is available.
- Return structured device identifiers, labels, rooms, owners, capabilities, and command results.
- The host-side adapter may invoke `smartthings-cli` internally. Claude sees only bounded MCP operations with validated arguments, never the CLI process, a command string, or a generic shell passthrough.
- Security-sensitive device commands pass through the approval gate.

## Screenshot policy

- Capture the entire active display at the start of every Agent Mode request.
- Make an on-demand screenshot tool available to Claude.
- Capture the active display again after every completed action, including app actions, browser actions, and SmartThings commands.
- Attach the post-action screenshot to the tool result so Claude can verify the outcome before proceeding.
- Retain screenshots only for the active 15-minute conversation.
- Delete screenshots when the conversation resets, expires, or the app terminates normally.
- Do not save agent screenshots in dictation history or any permanent user-visible history.
- Exclude Gaithano Speak's overlay from screenshots where ScreenCaptureKit permits it.

## Action and approval policy

Low-risk actions run automatically. These include:

- Opening, activating, and switching apps.
- Clicking ordinary controls.
- Navigating and reading web pages.
- Scrolling.
- Reading UI state.
- Adjusting ordinary media, volume, brightness, lights, and similar reversible controls.

The following actions require approval before execution:

- Typing any text or submitting entered text.
- Closing windows or quitting apps.
- Changing system settings.
- Deleting records, browser data, or device data. File deletion is unavailable because no file tools exist.
- Purchases, subscriptions, orders, financial transactions, and checkout actions.
- Unlocking doors, opening garages or gates, disabling alarms, or changing security devices.

When classification is uncertain, require approval.

### Approval interface

The panel shows the exact proposed action, target, important arguments, and reason for confirmation.

- Click **Allow** or press `Y`: execute this action once.
- Click **Deny** or press `N`: reject this action and let Claude reconsider or explain.
- Click **Allow all for this run** or press `A`: approve every subsequent available action category for the current run, including purchases, destructive actions, and security-device controls. It does not enable file or shell tools.
- Escape cancels the entire run.

"Allow all" expires when the current user request finishes, fails, or is cancelled. It never carries into a follow-up request, even within the same conversation.

The app must enforce approvals in an MCP proxy between Claude Code and each server. Prompt instructions alone are not an approval boundary. Claude must not receive a second unproxied route to the same operation.

No approval can grant a capability outside the fixed tool allowlist. `Y` and `A` authorize proposed assistant actions; they can never enable shell access, file access, arbitrary JavaScript, or arbitrary AppleScript.

## User interface

The Agent Mode panel remains visible while listening, working, awaiting approval, presenting a result, and accepting follow-ups.

Display all user-facing activity as text:

- Live transcription while the user speaks.
- Current phase and active model.
- Concise model-provided progress updates.
- MCP tool name, target, arguments safe to display, and result.
- Screenshot thumbnails with timestamps.
- Approval prompts and the selected decision.
- Errors with a concrete recovery action.
- A concise final response.

The panel must visually distinguish planned, running, completed, denied, failed, and cancelled actions. It must remain usable without activating the app during ordinary progress, but approval buttons may activate the panel when clicked.

Do not display raw hidden reasoning or label summaries as chain-of-thought.

## Speech output

- Speak only Claude's user-facing response text.
- Do not speak live transcription, progress, model escalation notices, tool calls, tool results, screenshots, approval prompts, or errors unless the final response includes the error.
- Stream complete sentences to speech when possible so long responses begin promptly.
- Escape stops speech along with the active run.
- Speech remains local through the configured system or Qwen voice engine.

## Cancellation and recovery

Escape or a new spoken request must:

1. Stop audio capture if active.
2. Cancel the current Claude turn.
3. Cancel the current tool call when the MCP supports cancellation.
4. Prevent queued actions from starting.
5. Preserve completed actions and their transcript in the conversation.
6. Mark any action with an unknown outcome as interrupted and require Claude to inspect current state before retrying.

After a crash or MCP disconnect, the app must not blindly replay the last action. It should reconnect, capture a fresh screenshot, inspect state, and let Claude decide how to recover.

## Permissions and setup

Onboarding must check and explain:

- Microphone permission for voice input.
- Accessibility permission for desktop input and UI inspection.
- Screen Recording permission for full-display screenshots.
- Chrome extension installation and connection for Playwright MCP.
- Claude Code installation, authentication, and minimum version.
- `smartthings-cli` installation and authentication.
- Availability of the three configured Claude models on the user's plan.

Agent Mode remains unavailable until microphone, Accessibility, Screen Recording, and Claude Code checks pass. Chrome and SmartThings may report separate unavailable states without disabling unrelated desktop control.

## Audit and privacy

- Keep the active conversation transcript, tool log, approvals, and screenshots for at most 15 minutes of inactivity.
- Do not persist screenshots or tool logs in normal dictation history.
- Show which MCP server performed each action.
- Redact secrets from displayed tool arguments where the server identifies them as sensitive.
- Never place captured screenshots or agent transcripts on the clipboard unless the user explicitly asks.
- State clearly during onboarding that screenshots and spoken requests are sent to Anthropic through Claude Code.

## Failure behavior

- If Claude Code is unavailable, show how to install, update, or authenticate it.
- If an MCP server fails, name the unavailable capability and keep other capabilities working.
- If Chrome is disconnected, offer a direct path to reconnect the extension.
- If SmartThings authentication expires, provide a setup action in the app. Do not ask Claude to run a reauthentication command.
- If a model is unavailable, report it. Do not silently substitute a lower model during an active run.
- If screenshot capture fails, stop computer-use actions that require visual verification. Text-only questions may continue.
- If post-action verification fails, do not assume success. Ask Claude to inspect or request user help.

## Acceptance criteria

1. Right Command + Right Option performs transcription and never starts Agent Mode.
2. Left Control + Left Option supports hold-to-speak and double-tap hands-free Agent Mode.
3. A follow-up within 15 minutes retains context; a later request starts a new conversation.
4. Every request starts on Sonnet. Escalation can move to Opus and then Fable 5.1, never downward during a run.
5. Claude has no file, shell, code-editing, arbitrary JavaScript, or arbitrary AppleScript tools.
6. Desktop control works without arbitrary AppleScript exposure.
7. Browser control uses the existing Chrome session without arbitrary JavaScript execution.
8. SmartThings inventory and all supported device commands are available through bounded tools.
9. The active display is captured at request start and after every action.
10. Every sensitive action pauses before execution and supports clickable controls plus `Y`, `N`, and `A`.
11. "Allow all" covers every category but expires at the end of that request.
12. Escape and a new request cancel the active run and prevent queued actions.
13. The panel renders all user-facing progress in text and does not claim to expose hidden reasoning.
14. Speech reads only the user-facing response.
15. Conversation screenshots and temporary data are deleted after 15 minutes of inactivity.

## Review decisions still available

The interview resolved the core product behavior. These implementation details can still be changed during review:

- Exact double-tap timing and maximum recording duration.
- Whether "entire active display" should expand to every connected display.
- Exact visual layout and placement of the Agent Mode panel.
- Whether completed conversations need an optional durable text-only history.
- Which ordinary system controls qualify as reversible low-risk actions.
- The exact SmartThings MCP package or whether the adapter should be maintained inside this repository.
