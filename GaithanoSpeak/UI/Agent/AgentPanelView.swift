import SwiftUI
import AppKit
import SpeakCore

/// Everything the user sees while Agent Mode works: what it heard, which model is
/// acting, every tool call and its outcome, the approval stop, and the answer.
///
/// A pure function of one `AgentTranscript` plus a way to answer an approval. It
/// holds no state of its own by design — the transcript is folded from events in one
/// place, and a second copy living in the view is how a panel starts claiming things
/// the runtime never said.
struct AgentPanelView: View {
    var transcript: AgentTranscript
    /// `(approval id, decision)`. The id is passed back rather than read off the
    /// transcript at the far end so a click that lands just after the runtime moved
    /// on resolves the approval the user was actually looking at, not the next one.
    var onDecision: (String, ApprovalDecision) -> Void

    /// Anchor for the auto-scroll below.
    private let bottomID = "agent-transcript-bottom"

    /// While the mic is live for a *follow-up*, the previous run stays on screen as
    /// context and steps back visually — the same bargain the Talk answer panel makes
    /// when a follow-up is in flight.
    private var isListening: Bool {
        transcript.phase == .listening
    }

    private var priorContentOpacity: Double {
        isListening && !transcript.steps.isEmpty ? 0.45 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let notice = transcript.escalationNotice { escalationRow(notice) }
            if transcript.allowAllForRun { allowAllBanner }
            if isListening || !transcript.partialTranscript.isEmpty { liveRow }

            if hasTranscriptContent { transcriptScroll }

            // Pinned below the scroll rather than inside it. An approval that can be
            // scrolled out of sight is an approval the user answers blind, and the run
            // is stopped waiting on exactly this.
            if let approval = transcript.pendingApproval {
                AgentApprovalPrompt(request: approval) { decision in
                    onDecision(approval.id, decision)
                }
            }

            if case let .failed(reason) = transcript.phase { failureBlock(reason) }
            if transcript.phase == .cancelled { cancelledBlock }

            footer
        }
        .padding(14)
        .frame(width: AgentPanelMetrics.width)
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .animation(.easeInOut(duration: 0.18), value: transcript.pendingApproval)
        .animation(.easeInOut(duration: 0.18), value: isListening)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            phaseGlyph
            Text(AgentPanelCopy.phaseLabel(transcript.phase))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer(minLength: 6)
            // The active model, named. The spec requires it visible at all times, not
            // only at the moment of escalation: a run that climbed to Fable ten steps
            // ago is still spending Fable, and the notice has long scrolled past.
            Text("via \(transcript.model.displayName)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
    }

    @ViewBuilder private var phaseGlyph: some View {
        switch transcript.phase {
        case .listening:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .thinking, .acting, .responding:
            ProgressView().controlSize(.small).tint(.white)
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.white.opacity(0.5))
        case .idle:
            Image(systemName: "circle.dotted").foregroundStyle(.white.opacity(0.4))
        }
    }

    private func escalationRow(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(notice)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Stays up for as long as the flag does. "Allow all" was a single keystroke and
    /// everything after it runs unasked, so the one thing the panel owes the user is
    /// a standing reminder that it is still in force — and when it stops being.
    private var allowAllBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 10))
            Text("Allow all is on for this request — nothing else will ask. It ends when this request does.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.orange.opacity(0.45), lineWidth: 1))
        )
    }

    /// Live transcription. Head-truncated over two lines so the words just spoken stay
    /// on screen while the sentence runs long, which is the half the user is checking.
    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text(transcript.partialTranscript.isEmpty ? "Listening…" : transcript.partialTranscript)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(transcript.partialTranscript.isEmpty ? 0.5 : 0.9))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Body

    private var hasTranscriptContent: Bool {
        !transcript.request.isEmpty || !transcript.steps.isEmpty || !transcript.response.isEmpty
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !transcript.request.isEmpty { requestRow }
                    ForEach(transcript.steps) { step in
                        AgentStepRow(step: step, decision: decision(for: step))
                    }
                    if !transcript.response.isEmpty { responseBlock }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .opacity(priorContentOpacity)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `maxHeight` inside `fixedSize` rather than on its own. A `ScrollView` is
            // greedy — offered the height of the screen it takes it, and a two-step run
            // would sit in a panel sized for a twenty-step one, most of it empty.
            // `fixedSize` proposes nothing, so the scroll view reports its content's
            // height and the frame clamps that: the panel grows with the run and stops
            // growing at the cap.
            .frame(maxHeight: AgentPanelMetrics.scrollHeight)
            .fixedSize(horizontal: false, vertical: true)
            // Follow the newest step. A run doing eight things in a row would otherwise
            // leave the user staring at step one while the interesting part happens off
            // the bottom edge. Keyed on the step count and the phase, not on every
            // transcript change, so a streaming response doesn't yank the view once per
            // token.
            .onChange(of: transcript.steps.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: transcript.phase) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private var requestRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("you")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
            Text(transcript.request)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var responseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            MarkdownText(source: transcript.response)
        }
        .padding(.top, 2)
    }

    /// `decisions` is keyed by approval id, and a step is keyed by its own. They line
    /// up when the runtime reuses one id for both, which is the arrangement asked for
    /// in INTEGRATION-panel.md; the tool call id is tried as well so the decision
    /// still finds its step under the other reasonable choice. An unmatched decision
    /// simply doesn't draw a chip — better a missing caption than one pinned to the
    /// wrong action.
    private func decision(for step: AgentStep) -> ApprovalDecision? {
        transcript.decisions[step.id] ?? step.call.flatMap { transcript.decisions[$0.id] }
    }

    // MARK: - Endings

    /// A failure is only useful with the next move attached. "MCP server unavailable"
    /// tells the user nothing they can act on; the recovery line is the part that
    /// gets them out of it.
    private func failureBlock(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AgentFailureRecovery.action(for: reason))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.red.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.red.opacity(0.45), lineWidth: 1))
        )
    }

    private var cancelledBlock: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "minus.circle")
                .font(.system(size: 10))
            Text(AgentPanelCopy.cancelled(hasInterruptedStep: transcript.steps.contains { $0.status == .interrupted }))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if transcript.pendingApproval != nil {
                keyHint("Y", "Allow")
                keyHint("N", "Deny")
                keyHint("A", "Allow all")
            } else if transcript.phase.isActive {
                keyHint("esc", "Stop")
            } else {
                keyHint("esc", "Close")
            }
            Spacer(minLength: 0)
            if !transcript.phase.isActive {
                Text("hold left ⌃⌥ to follow up")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
            Text(action).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - Metrics

/// Shared between the view and the panel that hosts it, so the window and its
/// contents can't disagree about how wide the panel is.
enum AgentPanelMetrics {
    static let width: CGFloat = 420
    /// The scroll region's cap. The panel as a whole has to stay a floating overlay
    /// over the user's work rather than a window that owns the screen, and a long run
    /// produces an unbounded number of steps.
    static let scrollHeight: CGFloat = 340
}

// MARK: - Copy

enum AgentPanelCopy {

    static func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .acting: return "Working…"
        case .awaitingApproval: return "Needs your approval"
        case .responding: return "Answering…"
        case .finished: return "Done"
        case .failed: return "Stopped"
        case .cancelled: return "Cancelled"
        }
    }

    /// Cancellation says two different things depending on what was in flight, and the
    /// difference is the whole point of `.interrupted`: queued work provably never
    /// started, but a call already on the wire may have landed.
    static func cancelled(hasInterruptedStep: Bool) -> String {
        hasInterruptedStep
            ? "Cancelled. Queued actions never started, but the step marked “outcome unknown” above was already in flight — check it before asking again."
            : "Cancelled. Nothing further ran."
    }
}

/// Turns a failure message into the next thing to do.
///
/// Matching on substrings of a message is crude, and it is still worth it: the
/// alternative the spec explicitly rules out is showing a bare error, and every
/// failure listed under "Failure behavior" has exactly one sensible next move that
/// the user cannot be expected to know. The fallback is deliberately actionable
/// rather than apologetic — an unmatched error still leaves the user needing to know
/// whether anything is still running.
enum AgentFailureRecovery {

    static func action(for reason: String) -> String {
        let text = reason.lowercased()

        if text.contains("claude code") || text.contains("claude cli") || text.contains("`claude`") {
            if text.contains("version") || text.contains("outdated") || text.contains("2.1") {
                return "Update Claude Code — Agent Mode needs 2.1.255 or newer for Fable 5.1. Run `claude update` in Terminal, then ask again."
            }
            if text.contains("auth") || text.contains("login") || text.contains("sign in") {
                return "Sign in to Claude Code: run `claude` in Terminal and complete the login, then ask again."
            }
            return "Install Claude Code, or set its full path in Settings → Agent (`which claude` in Terminal will tell you)."
        }
        if text.contains("chrome") || text.contains("playwright") || text.contains("extension") {
            return "Reconnect the Chrome extension from Settings → Agent. Desktop and SmartThings actions keep working meanwhile."
        }
        if text.contains("smartthings") {
            return "Re-authenticate SmartThings in Settings → Agent. Doing it there rather than asking the agent is deliberate: it has no shell to run the CLI in."
        }
        if text.contains("screen recording") || text.contains("screenshot") || text.contains("capture") {
            return "Grant Screen Recording in System Settings → Privacy & Security, then relaunch. Actions that need to see the screen are paused until then; text-only questions still work."
        }
        if text.contains("accessibility") {
            return "Grant Accessibility in System Settings → Privacy & Security. Without it the agent can't click, type, or read the interface."
        }
        if text.contains("microphone") || text.contains("mic ") {
            return "Grant Microphone access in System Settings → Privacy & Security, then hold left ⌃⌥ again."
        }
        if text.contains("usage limit") || text.contains("rate limit") || text.contains("quota") {
            return "Your Claude plan is out of capacity for now. Wait for the limit to reset, or ask again later — no model is substituted for you mid-run."
        }
        if text.contains("model") && (text.contains("unavailable") || text.contains("not available") || text.contains("access")) {
            return "That model isn't available on your plan. Ask again to start a fresh run on Sonnet; the run won't quietly drop to a lower model on its own."
        }
        if text.contains("mcp") || text.contains("server") || text.contains("disconnect") {
            return "That capability is offline. The others still work — ask again, or restart Gaithano Speak to reconnect it."
        }
        if text.contains("network") || text.contains("offline") || text.contains("connection") || text.contains("timed out") {
            return "Check your connection and ask again. Nothing else from this request will run."
        }
        return "Hold left ⌃⌥ and ask again. Nothing further from the stopped request will run — check any step marked “outcome unknown” above first."
    }
}

// MARK: - Previews

#if DEBUG
/// Hand-built transcripts covering the states the runtime will eventually produce.
///
/// These exist so the panel can be judged before any of it is real, and so the
/// statuses can be compared side by side — which is the only way to tell whether
/// "visually distinct" actually holds.
@MainActor
enum AgentPanelPreviewData {

    static let t0 = Date(timeIntervalSince1970: 1_772_000_000)

    /// A tiny PNG on disk so the thumbnail path renders for real rather than showing
    /// its placeholder. Written once per preview session into the temp directory —
    /// the same place the real captures live.
    static let screenshotURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-panel-preview-shot.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let size = NSSize(width: 320, height: 200)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.26, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.85, alpha: 1).setFill()
            NSRect(x: 24, y: 120, width: 200, height: 44).fill()
            NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
            NSRect(x: 24, y: 40, width: 260, height: 12).fill()
            image.unlockFocus()
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        return url
    }()

    static func shot(_ offset: TimeInterval) -> AgentScreenshot {
        AgentScreenshot(capturedAt: t0.addingTimeInterval(offset), url: screenshotURL)
    }

    /// Mid-run, every status that can coexist in one list, plus an escalation.
    static var working: AgentTranscript {
        AgentTranscript(
            phase: .acting,
            model: .opus,
            request: "Turn the living room lights down to 30% and put the Sonos on something quiet.",
            steps: [
                AgentStep(id: "s1",
                          call: AgentToolCall(id: "c1", server: .smartthings, tool: "list_devices",
                                              target: "Living Room",
                                              arguments: ["room": "Living Room"]),
                          status: .completed,
                          result: "4 devices: Living Room Lamp, Living Room Ceiling, Sonos One, Blinds",
                          startedAt: t0),
                AgentStep(id: "s2",
                          note: "Both lamps support setLevel, so dimming can be one command each.",
                          status: .completed,
                          startedAt: t0.addingTimeInterval(2)),
                AgentStep(id: "s3",
                          call: AgentToolCall(id: "c3", server: .smartthings, tool: "device_command",
                                              target: "Living Room Lamp",
                                              arguments: ["capability": "switchLevel", "command": "setLevel", "level": "30"]),
                          status: .completed,
                          result: "ok — level 30",
                          screenshot: shot(4),
                          startedAt: t0.addingTimeInterval(3)),
                AgentStep(id: "s4",
                          call: AgentToolCall(id: "c4", server: .macos, tool: "click_element",
                                              target: "Sonos › Play",
                                              arguments: ["element": "AXButton “Play”", "app": "Sonos"]),
                          status: .running,
                          startedAt: t0.addingTimeInterval(5)),
                AgentStep(id: "s5",
                          call: AgentToolCall(id: "c5", server: .macos, tool: "screenshot",
                                              arguments: ["display": "1"]),
                          status: .planned,
                          startedAt: t0.addingTimeInterval(6))
            ],
            escalationNotice: "Escalated to Opus — the device list didn't match the room name.")
    }

    /// The mic is live for a follow-up while the previous run is still on screen.
    static var listening: AgentTranscript {
        var t = working
        t.phase = .listening
        t.partialTranscript = "and can you also close the blinds in the"
        return t
    }

    /// Stopped on a purchase, with a denial already recorded above it.
    static var awaitingApproval: AgentTranscript {
        AgentTranscript(
            phase: .awaitingApproval,
            model: .sonnet,
            request: "Reorder the coffee I bought last month.",
            steps: [
                AgentStep(id: "s1",
                          call: AgentToolCall(id: "c1", server: .chrome, tool: "browser_navigate",
                                              target: "amazon.com/orders",
                                              arguments: ["url": "https://www.amazon.com/gp/css/order-history"]),
                          status: .completed,
                          result: "Loaded — 12 orders listed",
                          screenshot: shot(1),
                          startedAt: t0),
                AgentStep(id: "ap-0",
                          call: AgentToolCall(id: "c2", server: .chrome, tool: "browser_type",
                                              target: "Search your orders",
                                              arguments: ["text": "coffee"]),
                          status: .denied,
                          result: "Denied — used the order list instead.",
                          startedAt: t0.addingTimeInterval(3)),
                AgentStep(id: "ap-1",
                          call: AgentToolCall(id: "c3", server: .chrome, tool: "browser_click",
                                              target: "Place your order",
                                              arguments: ["ref": "button#placeOrder", "total": "$148.20"]),
                          status: .awaitingApproval,
                          startedAt: t0.addingTimeInterval(8))
            ],
            pendingApproval: AgentApprovalRequest(
                id: "ap-1",
                call: AgentToolCall(id: "c3", server: .chrome, tool: "browser_click",
                                    target: "Place your order",
                                    arguments: ["ref": "button#placeOrder", "total": "$148.20"]),
                category: .purchase,
                reason: "This completes a checkout on amazon.com for $148.20."),
            decisions: ["ap-0": .deny])
    }

    /// "Allow all" spent, and the banner that has to stay up while it is.
    static var allowAllActive: AgentTranscript {
        var t = awaitingApproval
        t.phase = .acting
        t.pendingApproval = nil
        t.allowAllForRun = true
        t.decisions["ap-1"] = .allowAll
        t.steps[2].status = .completed
        t.steps[2].result = "Order placed — confirmation #114-2298813"
        return t
    }

    /// A failure with a recovery line, and an interrupted step above it.
    static var failed: AgentTranscript {
        var t = AgentTranscript(
            phase: .acting,
            model: .sonnet,
            request: "Open the garage and turn the porch light on.",
            steps: [
                AgentStep(id: "s1",
                          call: AgentToolCall(id: "c1", server: .smartthings, tool: "device_command",
                                              target: "Garage Door",
                                              arguments: ["capability": "doorControl", "command": "open"]),
                          status: .running,
                          startedAt: t0),
                AgentStep(id: "s2",
                          call: AgentToolCall(id: "c2", server: .smartthings, tool: "device_command",
                                              target: "Porch Light",
                                              arguments: ["capability": "switch", "command": "on"]),
                          status: .planned,
                          startedAt: t0.addingTimeInterval(1))
            ])
        t.apply(.failed("SmartThings authentication expired."))
        return t
    }

    /// Escape mid-run.
    static var cancelled: AgentTranscript {
        var t = working
        t.apply(.cancelled)
        return t
    }

    /// The end state: an answer, nothing running, allow-all expired.
    static var finished: AgentTranscript {
        var t = working
        t.steps[3].status = .completed
        t.steps[3].result = "Playing “Rain on Concrete” on Sonos One"
        t.steps[4].status = .completed
        t.steps[4].result = "Captured"
        t.steps[4].screenshot = shot(9)
        t.apply(.responseFinished("Living room lamp is at **30%** and the Sonos is playing something quiet.\n\nThe ceiling light was already off, so I left it alone."))
        return t
    }

    /// Every status in one list, so they can be judged against each other.
    static var statusGallery: AgentTranscript {
        let all: [AgentStepStatus] = [.planned, .awaitingApproval, .running, .completed,
                                      .denied, .failed, .cancelled, .interrupted]
        return AgentTranscript(
            phase: .acting,
            model: .fable,
            request: "Every step status, side by side.",
            steps: all.enumerated().map { index, status in
                AgentStep(id: "s\(index)",
                          call: AgentToolCall(id: "c\(index)", server: .macos, tool: "click_element",
                                              target: AgentStatusStyle.label(status),
                                              arguments: ["element": "AXButton “Continue”"]),
                          status: status,
                          result: status == .failed ? "Element not found after 3 attempts" : nil,
                          startedAt: t0.addingTimeInterval(Double(index)))
            },
            decisions: ["s4": .deny],
            escalationNotice: "Escalated to Fable 5.1 — the page layout kept changing between snapshots.")
    }
}

private struct PreviewStage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(24)
            .background(
                LinearGradient(colors: [Color(white: 0.20), Color(white: 0.08)],
                               startPoint: .top, endPoint: .bottom)
            )
    }
}

#Preview("Working") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.working) { _, _ in } }
}

#Preview("Listening (follow-up)") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.listening) { _, _ in } }
}

#Preview("Awaiting approval") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.awaitingApproval) { _, _ in } }
}

#Preview("Allow all active") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.allowAllActive) { _, _ in } }
}

#Preview("Failed") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.failed) { _, _ in } }
}

#Preview("Cancelled") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.cancelled) { _, _ in } }
}

#Preview("Finished") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.finished) { _, _ in } }
}

#Preview("Status gallery") {
    PreviewStage { AgentPanelView(transcript: AgentPanelPreviewData.statusGallery) { _, _ in } }
}
#endif
