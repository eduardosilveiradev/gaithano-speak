import AppKit
import SwiftUI
import SpeakCore

/// A non-activating floating panel that shows the Flow Bar over every app,
/// including full-screen spaces, without ever stealing key focus.
@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private var hideTask: Task<Void, Never>?

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
                levels: [Float] = [], mode: UtteranceMode = .dictate, answerText: String = "") {
        let frame = activeScreenFrame()
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        hostingView.rootView = AnyView(
            FlowBarView(state: state, level: level, partial: partial, arming: arming,
                        levels: levels, mode: mode, answerText: answerText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 96)
        )

        if state.showsOverlay {
            cancelHide()
            if state.isRecording || state.isProcessing || state.showsAnswerPanel {
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
}
