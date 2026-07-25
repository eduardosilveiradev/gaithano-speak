import SwiftUI
import SpeakCore

/// Renders a model answer's markdown inside the overlay panel.
///
/// Two layers, split where the work actually divides: `MarkdownParser` (SpeakCore,
/// pure, tested) finds the blocks, and this view styles them. `AttributedString`
/// handles the inline spans within each block, which is the one part of markdown
/// Foundation already does well.
///
/// It re-parses on every streamed chunk. That's cheap at answer length and it's what
/// keeps a partially-arrived answer looking like an answer instead of like a wall of
/// asterisks — the parser is written to treat mid-stream input as normal.
///
/// Colour is deliberately inherited rather than declared: the panel dims the whole
/// answer while a follow-up is in flight by setting `foregroundStyle` above this view,
/// and hard-coding white here would break that. Anything that needs to sit back from
/// the body text does it with `.opacity`, which composes with whatever it inherits.
struct MarkdownText: View {
    let source: String
    var size: CGFloat = 13

    private var blocks: [MarkdownBlock] { MarkdownParser.blocks(from: source) }

    var body: some View {
        // Spacing lives on the blocks, not the stack: list items need to sit tight
        // enough to read as one list, and a heading needs air above it. One uniform
        // gap can't do both.
        VStack(alignment: .leading, spacing: 0) {
            let blocks = blocks
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : gap(from: blocks[index - 1], to: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            body(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))

        case let .paragraph(text):
            body(text)

        case let .bullet(text, depth):
            item(marker: depth == 1 ? "◦" : "•", width: 12, depth: depth, text: text)

        case let .numbered(number, text, depth):
            item(marker: "\(number).", width: 18, depth: depth, text: text)

        case let .code(_, text):
            // Wrapped, not horizontally scrollable. A nested scroll view inside the
            // panel's own would fight it for the gesture, and a long line silently
            // parked off-screen is worse than an ugly wrap.
            Text(text)
                .font(.system(size: size - 2, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.07))
                )
                .fixedSize(horizontal: false, vertical: true)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.white.opacity(0.2)).frame(width: 2)
                body(text).opacity(0.75)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    private func item(marker: String, width: CGFloat, depth: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: size - 1))
                .opacity(0.45)
                .frame(width: width, alignment: .trailing)
            body(text)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func body(_ text: String) -> some View {
        Text(inline(text))
            .font(.system(size: size, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        // Three steps, not six. At 380pt wide an `####` that looks distinct from an
        // `###` costs more than it says.
        switch level {
        case 1: size + 4
        case 2: size + 2
        default: size
        }
    }

    /// Vertical air between two adjacent blocks.
    private func gap(from previous: MarkdownBlock, to next: MarkdownBlock) -> CGFloat {
        if case .heading = next { return 14 }
        if isListItem(previous) && isListItem(next) { return 4 }
        if case .rule = next { return 12 }
        if case .rule = previous { return 12 }
        return 9
    }

    private func isListItem(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .bullet, .numbered: true
        default: false
        }
    }

    /// Inline spans — bold, italic, links, `code` — via Foundation.
    ///
    /// `.inlineOnlyPreservingWhitespace` is the mode that leaves block syntax alone;
    /// the full parser would eat the list markers this view is drawing itself. A parse
    /// failure falls back to the literal text, because showing the markers beats
    /// showing nothing.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        // `Text` renders bold and italic from the intent on its own, but leaves inline
        // code at body font, where `` `nil` `` is indistinguishable from the prose
        // around it. Ranges are collected first — assigning through `runs` while
        // iterating it invalidates the iteration.
        let codeRuns = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRuns {
            attributed[range].font = .system(size: size - 1, design: .monospaced)
        }
        return attributed
    }
}
