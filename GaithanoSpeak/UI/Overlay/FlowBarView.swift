import SwiftUI
import AppKit
import SpeakCore

/// The bottom-center pill: a live waveform while recording, a status label while
/// processing, and transient notices. Dark, minimal, monochrome.
struct FlowBarView: View {
    var state: DictationState
    var level: Float
    /// Live "ghost text" from the streaming preview model.
    var partial: String = ""
    /// 0→1 fill for the pre-commit "arming" progress bar.
    var arming: Double = 0
    /// Rolling history of recent audio levels (oldest → newest) for the waveform.
    var levels: [Float] = []

    /// Show the transcription bubble only when there's live text and we're still
    /// in an active utterance.
    private var showsPartial: Bool {
        !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (state.isRecording || state.isProcessing)
    }

    var body: some View {
        VStack(spacing: 8) {
            pill
            if showsPartial { partialPill }
        }
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .animation(.easeInOut(duration: 0.15), value: showsPartial)
    }

    /// ONE pill container for every state, so its size tweens between states
    /// (ready → listening → processing → notice) instead of hard-snapping. The
    /// content swaps inside while the outer capsule + frame animate as one identity.
    private var pill: some View {
        pillContent
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(pillBackground)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .fixedSize()
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: sizeToken)
    }

    /// Distinguishes only the states whose pill SIZE differs, so the resize spring
    /// fires on ready→listening→processing but not on every waveform frame.
    private var sizeToken: String {
        if case .recording(_, false) = state { return "arming" }
        if case .recording = state { return "listening" }
        return "text:\(label)"
    }

    @ViewBuilder private var pillContent: some View {
        if case .recording(_, false) = state {
            armingContent                       // grace window: logo + filling bar
        } else if case .recording = state {
            WaveformView(samples: levels)       // listening: waveform fills the pill
        } else {
            HStack(spacing: 10) { icon; Text(label) }   // processing / notices
                .transition(.opacity)
        }
    }

    /// Grace-window content: the logo mark over a thin progress bar that fills as the
    /// user keeps holding.
    private var armingContent: some View {
        VStack(spacing: 7) {
            logoMark.frame(width: 18, height: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: geo.size.width * arming)
                }
            }
            .frame(width: 96, height: 3)
        }
    }

    /// The live transcription bubble below the main pill. Fixed width so the overlay
    /// doesn't jitter as words stream in; head-truncated to keep the most recent
    /// words visible.
    private var partialPill: some View {
        Text(partial)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(width: 240, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(pillBackground)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(.black.opacity(0.85))
            .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .recording:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .notice(.noSpeech):
            Image(systemName: "waveform.slash")
        case .notice(.error):
            Image(systemName: "exclamationmark.triangle")
        case .notice(.copiedToClipboard):
            Image(systemName: "doc.on.clipboard")
        default:
            logoMark.frame(width: 15, height: 15)
        }
    }

    /// The Gaithano Speak logo mark (transparent-background PNG bundled in
    /// Resources), loaded once. Falls back to the mic glyph if it can't be found.
    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo-mark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    @ViewBuilder private var logoMark: some View {
        if let img = Self.logoImage {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "mic.fill")
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Press (⌥) to speak"
        case .blockedSecureInput: return "Secure input active"
        case .recording(.hold, _): return "Listening…"
        case .recording(.locked, _): return "Listening (hands-free)…"
        case .awaitingLockTap: return "Listening…"
        case .processing(.transcribing): return "Transcribing…"
        case .processing(.formatting): return "Formatting…"
        case .processing(.inserting): return "Inserting…"
        case .notice(.noSpeech): return "No speech detected"
        case .notice(.error(let m)): return m
        case .notice(.copiedToClipboard(let r)): return r
        }
    }
}

/// A live waveform filling the pill: each bar is one past audio-level sample,
/// newest on the right, mirrored around the vertical center. Uniform brightness and
/// a pre-filled buffer keep it reading as an equalizer, not a loading bar.
struct WaveformView: View {
    /// Level samples, oldest → newest. Right-aligned; missing history reads as zero.
    var samples: [Float]
    private let barCount = 32
    private let trackHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: height(i))
            }
        }
        .frame(height: trackHeight)   // bars center vertically → mirrored look
        .animation(.linear(duration: 0.06), value: samples)
    }

    private func sample(_ i: Int) -> Float {
        let missing = barCount - samples.count
        let idx = i - missing
        return (idx >= 0 && idx < samples.count) ? samples[idx] : 0
    }

    private func height(_ i: Int) -> CGFloat {
        // Perceptual boost so quiet speech still moves the bars; clamp to the track.
        let v = CGFloat(sample(i))
        return max(3, min(trackHeight, pow(v, 0.7) * 42 + 3))
    }
}
