import SwiftUI
import AppKit
import ImageIO
import SpeakCore

/// One line of the agent's work: which MCP server it went to, what it asked for,
/// what came back, and how it ended.
///
/// Everything it draws comes off the `AgentStep` it is handed. The row keeps no
/// state of its own except the decoded thumbnail, because the transcript is the
/// single definition of what the user is looking at and a second copy here would
/// eventually disagree with it.
struct AgentStepRow: View {
    var step: AgentStep
    /// What the user chose about this step, if it went through the approval gate.
    /// Resolved by the panel, not looked up here — `decisions` is keyed by approval
    /// id and only the panel knows how that maps onto a step.
    var decision: ApprovalDecision?

    private var status: AgentStepStatus { step.status }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // A tinted rail as well as a glyph: at a glance down a list of fifteen
            // steps the colour is what separates "this went wrong" from "this went
            // fine", well before anyone reads a symbol that small.
            Capsule()
                .fill(AgentStatusStyle.tint(status))
                .frame(width: 2)
                .opacity(status == .planned ? 0.35 : 0.8)

            VStack(alignment: .leading, spacing: 5) {
                headline
                if let call = step.call { arguments(for: call) }
                if let note = step.note, !note.isEmpty { noteBlock(note) }
                if let result = step.result, !result.isEmpty { resultBlock(result) }
                if let shot = step.screenshot { AgentScreenshotThumbnail(screenshot: shot) }
                if status == .interrupted { interruptedBlock }
                if let decision { decisionChip(decision) }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground)
    }

    /// Only `.interrupted` gets a filled background. The spec asks for statuses to be
    /// distinguishable; this is the one whose meaning ("we do not know if this
    /// happened") is not a shade of any other, so it gets the loudest treatment
    /// available short of a dialog.
    @ViewBuilder private var rowBackground: some View {
        if status == .interrupted {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AgentStatusStyle.tint(.interrupted).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AgentStatusStyle.tint(.interrupted).opacity(0.45), lineWidth: 1)
                )
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            glyph
            if let call = step.call {
                // Server first, always. "Which MCP server performed each action" is an
                // audit requirement, not a detail — the same `click` means different
                // things on the desktop and inside the browser.
                Text(call.server.displayName)
                    .foregroundStyle(.white.opacity(0.55))
                Text(call.tool)
                    .foregroundStyle(.white.opacity(0.95))
                if let target = call.target, !target.isEmpty {
                    Text("→ \(target)")
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(AgentStatusStyle.label(status))
                    .foregroundStyle(AgentStatusStyle.tint(status))
            }
            Spacer(minLength: 6)
            Text(AgentStepFormat.time(step.startedAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    /// A spinner rather than a symbol for `.running`: motion is the only thing that
    /// says "still happening" without the user having to re-read the panel to notice
    /// it changed.
    @ViewBuilder private var glyph: some View {
        if status == .running {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 11, height: 11)
        } else {
            Image(systemName: AgentStatusStyle.symbol(status))
                .font(.system(size: 10))
                .foregroundStyle(AgentStatusStyle.tint(status))
                .frame(width: 11)
        }
    }

    @ViewBuilder private func arguments(for call: AgentToolCall) -> some View {
        let pairs = AgentStepFormat.arguments(call.arguments)
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pairs, id: \.key) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(pair.key)
                            .foregroundStyle(.white.opacity(0.35))
                        Text(pair.value)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.leading, 17)
        }
    }

    /// A status line the model wrote. Labelled as exactly that: the spec forbids
    /// showing hidden reasoning *or* dressing a summary up as one, so this must never
    /// be captioned "thinking" or "reasoning" however much more interesting that reads.
    private func noteBlock(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("model status")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.28))
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 17)
    }

    private func resultBlock(_ result: String) -> some View {
        Text(AgentStepFormat.truncate(result, to: 320))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(status == .failed ? 0.85 : 0.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 17)
    }

    /// The sentence is the point of the status. "Interrupted" on its own reads as a
    /// synonym for "failed" to anyone who hasn't read the spec, and the difference
    /// matters: a failed action definitely didn't happen, this one might have.
    private var interruptedBlock: some View {
        Text(AgentStatusStyle.interruptedExplanation)
            .font(.system(size: 10))
            .foregroundStyle(AgentStatusStyle.tint(.interrupted).opacity(0.95))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 17)
    }

    private func decisionChip(_ decision: ApprovalDecision) -> some View {
        Text(AgentStepFormat.decisionCaption(decision))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.white.opacity(0.12))
            )
            .padding(.leading, 17)
    }
}

// MARK: - Status vocabulary

/// How each status looks and what it is called.
///
/// Centralised because the panel, the step row, and the approval prompt all have to
/// agree: a status that is green in one place and grey in another is worse than no
/// colour at all.
enum AgentStatusStyle {

    static func symbol(_ status: AgentStepStatus) -> String {
        switch status {
        case .planned: return "circle.dotted"
        case .awaitingApproval: return "hand.raised.fill"
        case .running: return "circle.dashed"       // unused: `.running` draws a spinner
        case .completed: return "checkmark.circle.fill"
        case .denied: return "hand.raised.slash.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        case .interrupted: return "questionmark.diamond.fill"
        }
    }

    static func tint(_ status: AgentStepStatus) -> Color {
        switch status {
        case .planned: return .white.opacity(0.35)
        case .awaitingApproval: return .yellow
        case .running: return .white
        case .completed: return .green
        // A refusal the user made deliberately is not an error, and colouring it like
        // one teaches people to skim past the red that does mean something.
        case .denied: return Color(red: 0.62, green: 0.70, blue: 0.92)
        case .failed: return .red
        case .cancelled: return .white.opacity(0.3)
        case .interrupted: return .orange
        }
    }

    static func label(_ status: AgentStepStatus) -> String {
        switch status {
        case .planned: return "planned"
        case .awaitingApproval: return "waiting for you"
        case .running: return "running"
        case .completed: return "done"
        case .denied: return "denied"
        case .failed: return "failed"
        case .cancelled: return "not run"
        case .interrupted: return "outcome unknown"
        }
    }

    static let interruptedExplanation =
        "Started, then the run stopped. Whether it took effect is unknown — it won't be retried until the current state has been checked."
}

// MARK: - Pure formatting

/// Text shaping the rows need and nothing else. Pure and static so the same argument
/// list renders identically wherever it appears — the step row and the approval
/// prompt show the same call, and they must not disagree about it.
enum AgentStepFormat {

    /// Wall-clock time for a step or screenshot.
    ///
    /// The formatter is built once. The panel re-renders while the agent works, and a
    /// `DateFormatter` per row per frame is a measurable cost for a string that
    /// changes at most once a second.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// Argument pairs in a stable order.
    ///
    /// Sorted by key because a Swift dictionary has no order: left alone, the same
    /// unchanged call would reshuffle its own arguments on every render and read as
    /// activity. Values are already display-safe — the proxy redacts anything a
    /// server marks sensitive before the call reaches this side — so the only job
    /// left is length.
    static func arguments(_ arguments: [String: String], valueLimit: Int = 90) -> [(key: String, value: String)] {
        arguments
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: truncate($0.value, to: valueLimit)) }
    }

    /// Truncate on a word boundary where one is near the cut, so a clipped URL or
    /// sentence still ends somewhere a reader can parse.
    static func truncate(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: limit)
        let head = trimmed[trimmed.startIndex..<cut]
        if let space = head.lastIndex(of: " "), head.distance(from: space, to: head.endIndex) < 16 {
            return head[head.startIndex..<space] + "…"
        }
        return head + "…"
    }

    /// Names the author of the decision, because "allowed" alone leaves it ambiguous
    /// whether the user chose this or the run-wide allow-all spent itself here.
    static func decisionCaption(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .allow: return "you allowed this"
        case .deny: return "you denied this"
        case .allowAll: return "allowed — and every action after it this run"
        }
    }
}

// MARK: - Screenshots

/// A thumbnail of a capture the app owns, with the time it was taken.
///
/// The URL on `AgentScreenshot` is app-private and is never handed to the model —
/// the spec routes images to Claude as MCP image content precisely so no readable
/// path exists on that side. Drawing it here is the only reason the reference is on
/// the type at all.
struct AgentScreenshotThumbnail: View {
    var screenshot: AgentScreenshot
    var maxWidth: CGFloat = 168

    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                } else {
                    // A placeholder of the same footprint: without it the row jumps
                    // when the decode lands, which mid-run reads as new activity.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: maxWidth)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )

            Text(AgentStepFormat.time(screenshot.capturedAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.leading, 17)
        .task(id: screenshot.id) {
            if let cached = AgentThumbnailCache.image(for: screenshot.id) {
                image = cached
                return
            }
            // Decoded on the main actor deliberately. It is a downscale of a few
            // milliseconds that happens once per screenshot, and hopping off-actor
            // would mean sending an `NSImage` across isolation, which Swift 6 rightly
            // refuses. The cache is what keeps it from happening twice.
            let decoded = AgentThumbnailCache.decode(screenshot.url, maxPixelSize: maxWidth * 2)
            AgentThumbnailCache.store(decoded, for: screenshot.id)
            image = decoded
        }
    }
}

/// Downscaled captures, kept so the panel doesn't re-decode on every render.
///
/// Bounded on purpose: these come from full-display captures, and a conversation can
/// take one after every action for fifteen minutes. Holding those at full size to
/// draw them 168 points wide would cost hundreds of megabytes, so ImageIO produces a
/// thumbnail and the full bitmap is never resident at all.
@MainActor
enum AgentThumbnailCache {
    private static var images: [UUID: NSImage] = [:]
    private static var order: [UUID] = []
    private static let limit = 24

    static func image(for id: UUID) -> NSImage? { images[id] }

    static func store(_ image: NSImage?, for id: UUID) {
        guard let image else { return }
        images[id] = image
        order.append(id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    /// Drop everything. The conversation's screenshots are deleted when it resets or
    /// expires; keeping decoded copies of files that no longer exist would quietly
    /// outlive the retention window the spec sets.
    static func purge() {
        images.removeAll()
        order.removeAll()
    }

    static func decode(_ url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Halved, because `maxPixelSize` was asked for in pixels for a Retina draw and
        // `NSImage.size` is in points.
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
