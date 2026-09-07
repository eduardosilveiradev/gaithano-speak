# Agent Mode panel — integration

What the panel needs from the coordinator, and what it will not do for itself.

Files in this branch:

- `GaithanoSpeak/UI/Agent/AgentPanelView.swift` — the panel, plus `AgentPanelMetrics`, `AgentPanelCopy`, `AgentFailureRecovery`, and the preview transcripts.
- `GaithanoSpeak/UI/Agent/AgentStepRow.swift` — one step, plus `AgentStatusStyle`, `AgentStepFormat`, `AgentScreenshotThumbnail`, `AgentThumbnailCache`.
- `GaithanoSpeak/UI/Agent/AgentApprovalPrompt.swift` — the gate UI.
- `GaithanoSpeak/UI/Overlay/OverlayPanelController.swift` — hosts the panel in a second non-activating `NSPanel`.
- `GaithanoSpeak/UI/Overlay/FlowBarView.swift` — one new defaulted parameter.
- `GaithanoSpeak/Input/HotkeyMonitor.swift` — `Y` / `N` / `A`.

## 1. What the coordinator must call

### Presenting the panel

```swift
overlay.updateAgent(transcript: coordinator.agentTranscript) { approvalID, decision in
    coordinator.resolveApproval(id: approvalID, decision: decision)
}
```

- Call it wherever `onStateChange` already calls `overlay.update(...)`, and once more from the 60 fps poll in `AppEnvironment.startMonitoring()` while `agentTranscript?.phase.isActive == true`. Both are cheap when nothing changed: the controller compares the transcript it last rendered (`AgentTranscript` is `Equatable`) and only rebuilds the SwiftUI tree when it differs.
- Pass `nil` — or a transcript whose phase is `.idle` — to take the panel down. That is also what purges the decoded screenshot thumbnails, so call it when the conversation resets or expires rather than leaving the last run on screen.
- The panel stays up on `.finished`, `.failed` and `.cancelled` by design: the spec keeps it visible while presenting a result and accepting follow-ups. Nothing hides it on a timer, unlike the Flow Bar's 10 s failsafe. **The coordinator owns dismissal** — on Escape from a settled run, on conversation reset, and on the 15-minute expiry.

### The decision callback

The panel emits `(approvalID, ApprovalDecision)` and nothing else. It does not mutate the transcript. The coordinator should:

1. hand the decision to the MCP proxy's gate, then
2. fold `.approvalResolved(id:decision:)` into the transcript.

Do not fold the event without resolving the gate: the transcript would show a decision the held tool call never received.

### The hotkey flags

```swift
hotkeyMonitor.setApprovalPending(transcript.pendingApproval != nil)
hotkeyMonitor.setActive(/* true for the whole agent run, not just while recording */)
```

- `setApprovalPending` is the *entire* licence to consume `Y`, `N`, `A`. It must go false the instant the gate resolves — including when the run is cancelled or fails out from under a pending approval, where `AgentTranscript.apply` clears `pendingApproval` for you. Leave it true and the user loses three letters in every text field on the machine.
- `setActive(true)` for the duration of an agent run, not only while the mic is open. It is what makes Escape reach the run instead of the app underneath. The panel's footer promises `esc` stops the run; that promise is the coordinator's to keep.

### Wiring the keyboard decisions (`AppEnvironment.wire()`)

```swift
hotkeyMonitor.onApprovalEvent = { [weak self] event in
    MainActor.assumeIsolated { self?.coordinator.resolveApproval(decision: event.decision) }
}
```

`event.decision` is already an `ApprovalDecision`, so the keyboard and the buttons converge on one code path. Resolve against `transcript.pendingApproval?.id` — the keys carry no id, because the user is answering whatever is on screen.

## 2. The new hotkey cases

I did **not** add cases to `HotkeyEvent`. Adding one breaks the exhaustive `switch` in `RecordingCoordinator.handleHotkey`, which this branch must not touch, so the three keys ride a separate channel instead:

```swift
enum HotkeyApprovalEvent: Sendable {
    case approvalAllow      // Y
    case approvalDeny       // N
    case approvalAllowAll   // A
    var decision: ApprovalDecision { ... }
}

var onApprovalEvent: (@Sendable (HotkeyApprovalEvent) -> Void)?
func setApprovalPending(_ pending: Bool)
```

Fold them into `HotkeyEvent` if you prefer one channel — the case names are already the ones the coordinator will want. The mapping is:

| case | coordinator call |
| --- | --- |
| `.approvalAllow` | `resolveApproval(decision: .allow)` |
| `.approvalDeny` | `resolveApproval(decision: .deny)` |
| `.approvalAllowAll` | `resolveApproval(decision: .allowAll)` |

Behaviour that is already handled in the tap and should stay that way if you move it:

- **Bare keys only.** `⌘A`, `⌃N` and friends pass through to the frontmost app. Only the unmodified letter is consumed, and only while an approval is pending.
- **Autorepeat is consumed but not emitted.** Holding `A` would otherwise resolve this approval and then race the next one the runtime raises, answering a question the user never read.
- **Escape** is now consumed while an approval is pending as well as while a dictation is active, so it can cancel a run that is sitting at the gate with the mic closed.

## 3. One convention I need from the runtime

`AgentTranscript.decisions` is keyed by **approval id**; `steps` are keyed by **step id**. To draw "you denied this" against the step it applied to, the panel tries `decisions[step.id]` and then `decisions[step.call?.id]`.

**Please make the `AgentApprovalRequest.id` equal the id of the step it gates** (or, failing that, the tool call id). Under any third choice the decision still records correctly and the run still behaves — the caption just won't appear next to its step, which is exactly the audit line the spec asks for.

## 4. AppSettings keys

**None.** The panel is a pure function of the transcript and deliberately has nothing to configure. If a "keep the panel on screen after a run" preference is wanted later it belongs on the coordinator's dismissal logic, not here.

## 5. Fields I wanted and did not add

`AgentTypes.swift` is frozen and shared, so these are requests, not changes. The panel works without all of them.

| Wanted | Why | What the panel does instead |
| --- | --- | --- |
| Audio levels during `.listening` | The panel shows live text but has no waveform, and the waveform is the only cue that the mic is *hearing* rather than merely open. | The Flow Bar pill is left visible below the panel and supplies it. See §6. |
| `AgentStep.endedAt` (or a duration) | Only `startedAt` exists, so a step that has been running for forty seconds looks the same as one that started a moment ago. | Shows the start time only. A spinner carries "still going". |
| A structured failure kind on `.failed` | `AgentFailureRecovery.action(for:)` matches substrings of the reason string to produce the concrete next step the spec requires. That is crude and will silently fall back to generic advice if the runtime's wording drifts. | Substring matching, with an actionable default. If you add a failure enum later, that function is the one place to rewrite. |
| A distinction between "cancelled by the user" and "conversation expired" | Both arrive as `.cancelled`, and they deserve different copy — one is a thing the user just did, the other is a thing that happened while they weren't looking. | Both read as "Cancelled". |
| A per-step "this needed approval" flag | Reconstructed from the decisions map, hence §3. | See §3. |

## 6. Interaction with the existing overlay

- The Agent panel is a **second** `NSPanel` owned by `OverlayPanelController`, sized to its content and parked bottom-centre 150 pt up — clear of the Flow Bar, which the existing layout parks 96 pt off the bottom. Both can be on screen at once.
- It is `.nonactivatingPanel` with `becomesKeyOnlyIfNeeded`, ordered front with `orderFrontRegardless()`, so ordinary progress never steals focus. Unlike the Flow Bar it does **not** ignore mouse events — the approval buttons are on it and the transcript scrolls. That is safe only because it is sized to its content; the Flow Bar's window spans the whole screen and must keep ignoring the mouse.
- Its hosting view overrides `acceptsFirstMouse`, so an approval button works on the first click instead of spending it on focus.
- `FlowBarView` gained one defaulted parameter, `showsAgentPanel`, set by the controller. Its only effect is to suppress the live-transcription bubble, which the Agent panel already draws. **The pill stays**, because its waveform is the mic-live cue the panel has no equivalent for. If the coordinator ends up driving `DictationState` through processing phases during an agent run, the pill will narrate them too and read as a duplicate of the panel's header — say so and I will suppress the pill on `showsAgentPanel` as well.

## 7. Things the panel promises, that the runtime has to make true

- **`.interrupted` means "we do not know if this happened."** The row says so in a sentence, not just a colour, and the cancellation footer points at it. `AgentTranscript.apply` already sets it correctly on `.failed` and `.cancelled`; don't hand-set `.failed` on a call that was already on the wire.
- **`AgentStep.note` is labelled "model status".** The spec forbids showing or implying hidden reasoning, so don't route a thinking block into it.
- **`AgentToolCall.arguments` is rendered verbatim** (truncated, sorted). The type's contract says the proxy has already redacted anything a server marks sensitive. The panel does no redaction of its own and should not start — one redaction pass in a known place beats two that can disagree.
- **The screenshot URL is drawn and never displayed as text.** It stays app-private; nothing in the panel copies, exposes, or puts it on the clipboard.

## 8. Tests

None added. The pure helpers worth pinning (`AgentStepFormat.truncate`, `AgentFailureRecovery.action(for:)`, `AgentPanelCopy`) live in the app target, which has no test target — adding one means editing `Package.swift`, which three sibling branches are also touching. If the app target gets a test target after the merge, those three are the first things to cover.

The eight `#Preview`s in `AgentPanelView.swift` are how this work is meant to be reviewed: working, listening follow-up, awaiting approval, allow-all active, failed, cancelled, finished, and a gallery of every step status side by side. `AgentPanelPreviewData` writes a small PNG into the temp directory so the screenshot thumbnails render for real.
