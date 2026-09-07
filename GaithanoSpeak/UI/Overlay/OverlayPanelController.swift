import AppKit
import SwiftUI
import SpeakCore

/// Non-activating floating panels that sit over every app, including full-screen
/// spaces, without ever stealing key focus: the Flow Bar pill, and — above it — the
/// Agent Mode panel.
///
/// One controller owns both because only one of them may claim a given piece of the
/// screen or a given piece of status. Split across two objects, nothing would be in a
/// position to stop the pill and the panel narrating the same thing twice.
@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private var hideTask: Task<Void, Never>?

    // Agent Mode. Built on first use: most sessions never run the agent, and an
    // NSPanel that is never shown is still a window server connection.
    private var agentPanel: NSPanel?
    private var agentHostingView: AgentHostingView<AnyView>?
    /// The last transcript actually rendered, so the 60 fps overlay poll doesn't
    /// rebuild a SwiftUI tree that hasn't changed — which besides the cost would
    /// restart the spinner and the row transitions several times a second.
    private var renderedTranscript: AgentTranscript?
    private var agentPresented = false
    /// The screen the panel was last positioned against, so it can follow the user to
    /// another display without measuring itself on every poll.
    private var agentScreenFrame: NSRect = .zero

    // Max-visible failsafe: hide the pill after this long UNLESS still recording.
    private var visibleStart: Date?
    private var didTimeOut = false
    private let maxVisible: TimeInterval = 10

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    /// Render the given state; show or hide the panel appropriately. The pill sits at
    /// the bottom-center of the screen under the mouse (a full-screen click-through
    /// panel with the Flow Bar anchored near the bottom), rather than following the cursor.
    func update(state: DictationState, level: Float, partial: String = "", arming: Double = 0,
                levels: [Float] = [], mode: UtteranceMode = .dictate, answerText: String = "",
                showsAnswerPanel: Bool = false, history: [TalkTurn] = []) {
        let frame = activeScreenFrame()
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        hostingView.rootView = AnyView(
            FlowBarView(state: state, level: level, partial: partial, arming: arming,
                        levels: levels, mode: mode, answerText: answerText,
                        showsAnswerPanel: showsAnswerPanel, history: history,
                        showsAgentPanel: agentPresented)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 96)
        )

        if state.showsOverlay {
            cancelHide()
            if state.isRecording || state.isProcessing || showsAnswerPanel {
                // Recording (incl. hands-free lock), active processing (transcribing /
                // formatting / inserting), and a presented answer never time out — a
                // slow reasoning model can take well over 10s to format, and an answer
                // stays up until the user dismisses it, however long they read for.
                // Keep the clock fresh so only a lingering *notice* pill afterward is
                // subject to the cap.
                visibleStart = Date()
                didTimeOut = false
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if !didTimeOut {
                if visibleStart == nil { visibleStart = Date() }
                if Date().timeIntervalSince(visibleStart!) >= maxVisible {
                    didTimeOut = true          // stuck (e.g. hung processing) → give up
                    panel.orderOut(nil)
                } else if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            }
            // didTimeOut && !recording → stay hidden until the cycle resets below.
        } else {
            // Idle, blocked, or the silent provisional window → keep it hidden.
            scheduleHide()
            visibleStart = nil
            didTimeOut = false
        }
    }

    /// Full-screen frame of the screen currently under the mouse, so the centered
    /// pill lands on whatever display the user is working on.
    private func activeScreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func scheduleHide() {
        cancelHide()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            self?.panel.orderOut(nil)
        }
    }

    private func cancelHide() {
        hideTask?.cancel(); hideTask = nil
    }

    // MARK: - Agent Mode panel

    /// Show the Agent Mode panel for `transcript`, or hide it when handed nil.
    ///
    /// Called on every transcript change and from the overlay poll; both are cheap
    /// when nothing moved. A closure can't be compared, so `onDecision` is simply
    /// re-captured whenever the tree is rebuilt — it is expected to be a stable
    /// forward to the coordinator, not to carry per-call state.
    func updateAgent(transcript: AgentTranscript?,
                     onDecision: @escaping (String, ApprovalDecision) -> Void) {
        guard let transcript, transcript.phase != .idle else {
            hideAgent()
            return
        }

        let panel = ensureAgentPanel()
        if renderedTranscript != transcript || !agentPresented {
            renderedTranscript = transcript
            agentHostingView?.rootView = AnyView(
                AgentPanelView(transcript: transcript, onDecision: onDecision)
            )
            layoutAgentPanel(panel)
        } else if activeScreenFrame() != agentScreenFrame {
            // The user dragged the mouse to another display. Re-laying out only here,
            // and not on every poll, keeps `fittingSize` — which forces a SwiftUI
            // layout pass — off the 60 fps path.
            layoutAgentPanel(panel)
        }

        if !panel.isVisible {
            // Never `makeKeyAndOrderFront`: the panel has to appear over whatever the
            // user is working in without taking focus from it. A non-activating panel
            // ordered front regardless does that; clicking an approval button still
            // makes it key, which is the one moment the spec allows.
            panel.orderFrontRegardless()
        }
        agentPresented = true
    }

    /// Take the panel down. Also drops decoded screenshot thumbnails: the captures
    /// themselves are deleted when the conversation resets or expires, and holding
    /// decoded copies of deleted files would quietly outlive that window.
    func hideAgent() {
        guard agentPresented || agentPanel?.isVisible == true else { return }
        agentPanel?.orderOut(nil)
        agentPresented = false
        renderedTranscript = nil
        AgentThumbnailCache.purge()
    }

    private func ensureAgentPanel() -> NSPanel {
        if let agentPanel { return agentPanel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Unlike the Flow Bar, this one takes clicks — the approval buttons are on it,
        // and the transcript scrolls. It is safe to do here and not there because this
        // panel is sized to its content: the Flow Bar's window spans the whole screen
        // and would swallow every click on the desktop if it stopped ignoring them.
        panel.ignoresMouseEvents = false
        // Key only when a control genuinely needs it. Nothing on the panel does today
        // — the approval keys are consumed by the event tap precisely so they work
        // while the user's focus is somewhere else entirely.
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = AgentHostingView(rootView: AnyView(EmptyView()))
        hosting.wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        agentPanel = panel
        agentHostingView = hosting
        return panel
    }

    /// Size to the content and sit bottom-centre, clear of the Flow Bar pill.
    ///
    /// Sized rather than left full-screen so the rest of the desktop stays clickable
    /// while the agent works, which is most of what "usable without activating the
    /// app" means in practice.
    private func layoutAgentPanel(_ panel: NSPanel) {
        guard let hosting = agentHostingView else { return }
        let screen = activeScreenFrame()
        agentScreenFrame = screen
        // `fittingSize` rather than a measured layout pass: the SwiftUI tree already
        // pins its own width and caps the scroll region, so its ideal size is the
        // answer, and asking AppKit for it avoids hosting a second copy just to
        // measure one.
        let height = min(max(hosting.fittingSize.height, 80), screen.height - 200)
        let frame = NSRect(
            x: screen.midX - AgentPanelMetrics.width / 2,
            // 150pt clears the Flow Bar, which the layout above parks 96pt off the
            // bottom: during an agent recording the pill is the only live waveform
            // there is, so the two are shown together rather than one replacing the other.
            y: screen.minY + 150,
            width: AgentPanelMetrics.width,
            height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Hosting view that answers the first click.
///
/// AppKit normally spends the click that brings a window forward, so an approval
/// button would need two presses — the first to focus the panel, the second to
/// actually allow or deny. On a prompt that is holding a purchase, "press it twice"
/// is not a thing anyone should have to discover.
private final class AgentHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
