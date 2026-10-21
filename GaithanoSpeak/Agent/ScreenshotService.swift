import Foundation
import CoreGraphics
import os
import SpeakCore


/// One capture, in the two forms it is used in.
///
/// The split is the safety property, not a convenience. The spec says Claude receives
/// screenshots "directly as MCP image content" and never as a readable file path, so
/// the bytes (`jpeg`) and the file reference (`screenshot`) are different members of
/// different types: `mcpImageContent()` can only see the bytes, and `AgentScreenshot`
/// — the thing that goes into `AgentStep` and reaches the panel — carries a URL and
/// no data. There is no value in this file that offers both a path and a way to send
/// it, so the mistake has to be typed out deliberately rather than made by reaching
/// for the nearest field.
struct AgentCapture: Sendable {
    /// The panel's thumbnail reference. App-private, and deleted with the
    /// conversation — see `AgentScratchStore`.
    let screenshot: AgentScreenshot
    /// The JPEG that goes to the model.
    let jpeg: Data
    /// Pixel size of `jpeg`, after downscaling.
    let imageSize: CGSize
    /// The captured display in global CoreGraphics coordinates. Travels with the
    /// image because a click the model expresses in image pixels is mapped back
    /// through both, and recomputing either at click time is how coordinates end up
    /// on the wrong monitor.
    let displayBounds: CGRect

    /// The image as MCP content. Base64 in the message, which is the only form that
    /// keeps the runtime's "no readable paths" promise.
    func mcpImageContent() -> [String: String] {
        ["type": "image", "mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]
    }
}

/// Why a capture didn't happen.
///
/// A typed error rather than an optional because the spec draws a line through this
/// exact point: "if screenshot capture fails, stop computer-use actions that require
/// visual verification. Text-only questions may continue." A caller can only make
/// that decision if it is told, so this throws — and there is deliberately no variant
/// that returns a blank or stale image, which would let a run keep clicking against a
/// screen nobody has seen.
enum ScreenshotFailure: LocalizedError, Sendable {
    case screenRecordingDenied
    case captureFailed
    case storeFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording access is off, so Agent Mode can't see the screen."
        case .captureFailed:
            return "The screen capture didn't complete."
        case let .storeFailed(detail):
            return "The screenshot couldn't be saved: \(detail)"
        }
    }

    /// The recovery action the panel shows. Shares the preflight's wording so the
    /// message during a run and the message in Settings can't drift apart and
    /// describe the same missing grant two different ways.
    var remedy: PreflightRemedy {
        switch self {
        case .screenRecordingDenied:
            return PreflightCheckResult.remedy(for: .screenRecording, finding: .permissionNotGranted)
        case .captureFailed, .storeFailed:
            return PreflightRemedy(problem: errorDescription ?? "Screen capture failed.",
                                   actionLabel: "Try again",
                                   action: .retryCheck)
        }
    }
}

/// Screenshots for Agent Mode: at the start of every request, after every completed
/// action, and whenever Claude asks.
///
/// The ScreenCaptureKit work itself is `ScreenCapture` in `Talk/`, and this
/// deliberately calls it rather than growing a second copy. The requirements are the
/// same ones, for the same reasons: whole active display (a focused-window capture
/// has to ask who is frontmost, and with an overlay up the answer can be us), our own
/// application excluded through `SCContentFilter` (the Flow Bar and the agent panel
/// sit *over* the thing the agent is about to click — a model that can see our UI
/// tries to interact with it), and one downscale to 1536px at quality 0.7, which is
/// the budget that keeps small UI text legible.
///
/// Two things differ, and both are handled here rather than by editing `ScreenCapture`:
///
/// - **Failure is not silent.** Talk folds every failure into `nil` because a missing
///   grant should quietly degrade an answer to text-only. An agent that can't see has
///   to stop, so this separates the permission case out with its own preflight check
///   and throws the rest.
/// - **A copy is retained.** Talk's image is used once and dropped. The panel needs a
///   thumbnail for every capture in the conversation, so each one is also written to
///   the conversation's scratch directory.
struct ScreenshotService: Sendable {
    let scratch: AgentScratchStore

    /// Capture the active display.
    ///
    /// Deliberately not a stale-cache read: every call is a fresh capture, because the
    /// whole point of the post-action screenshot is to show what the last action
    /// actually did.
    func capture(at now: Date = Date()) async throws -> AgentCapture {
        // Checked first so a denied grant is distinguishable from a capture that
        // failed for any other reason — the remedies are completely different, and
        // `ScreenCapture` returns the same `nil` for both. Non-prompting on purpose;
        // `CGRequestScreenCaptureAccess()` would put a dialog in front of a user who
        // is mid-sentence.
        guard CGPreflightScreenCaptureAccess() else {
            Log.agent.error("Agent capture blocked: Screen Recording not granted")
            throw ScreenshotFailure.screenRecordingDenied
        }

        // Its own interval name: `capture` already means audio capture in the
        // dictation budget, and a screenshot landing in that row would make the
        // latency trace unreadable.
        let signpost = Log.signposter
        let state = signpost.beginInterval("agentScreenshot")
        defer { signpost.endInterval("agentScreenshot", state) }

        guard let shot = await ScreenCapture.capture() else {
            Log.agent.error("Agent capture failed after the permission check passed")
            throw ScreenshotFailure.captureFailed
        }

        let screenshot: AgentScreenshot
        do {
            screenshot = try await scratch.store(jpeg: shot.jpeg, capturedAt: now)
        } catch {
            // The bytes are in hand and would work; it is the panel's thumbnail that
            // is missing. Failing anyway keeps one rule — every capture in the
            // conversation is visible in the transcript — rather than producing runs
            // where some actions have evidence and others silently don't.
            throw ScreenshotFailure.storeFailed(error.localizedDescription)
        }

        return AgentCapture(screenshot: screenshot,
                            jpeg: shot.jpeg,
                            imageSize: shot.imageSize,
                            displayBounds: shot.displayBounds)
    }

    /// Map a point the model gave in image pixels to a global screen point.
    ///
    /// Forwards to `ScreenCapture.screenPoint(fromImage:in:)`, which clamps to the
    /// display: a hallucinated off-screen coordinate should click a harmless edge
    /// rather than warp to another monitor.
    func screenPoint(fromImage point: CGPoint, in capture: AgentCapture) -> CGPoint {
        ScreenCapture.screenPoint(
            fromImage: point,
            in: ScreenCapture.Shot(jpeg: capture.jpeg,
                                   imageSize: capture.imageSize,
                                   displayBounds: capture.displayBounds))
    }
}
