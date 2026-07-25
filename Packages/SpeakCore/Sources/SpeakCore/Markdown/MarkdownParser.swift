import Foundation

/// One renderable chunk of an answer.
///
/// Block structure only. Inline spans — `**bold**`, `*italic*`, `` `code` ``, links —
/// are deliberately left in the payload strings for the view to hand to
/// `AttributedString(markdown:)`, which already does that job well. What it cannot do
/// is blocks: given a list it returns one run-on line, and given a fenced code block
/// it returns the backticks. That gap is what this exists to fill.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bullet(text: String, depth: Int)
    case numbered(number: Int, text: String, depth: Int)
    case code(language: String?, text: String)
    case quote(text: String)
    case rule
}

/// A small block-level markdown reader for model answers.
///
/// Not a CommonMark implementation and not trying to be — it covers what a chat model
/// actually emits, and its hard requirement is that it never throws away text. Anything
/// it doesn't recognise comes back as a paragraph, so a malformed or exotic construct
/// degrades to plain prose rather than vanishing from the answer.
///
/// It also has to survive being called on every streamed token, which means partial
/// input is the normal case, not an error: an unclosed fence renders as code from the
/// fence onward, and a half-typed `**bold` is left to the inline pass, which drops the
/// markers only once the closing pair arrives.
public enum MarkdownParser {

    public static func blocks(from source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Soft-wrapped lines are one paragraph, per markdown.
            blocks.append(.paragraph(text: paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(text: quote.joined(separator: " ")))
            quote = []
        }
        func flushAll() { flushParagraph(); flushQuote() }

        var lines = source.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let body = line.drop { $0 == " " || $0 == "\t" }
            let trimmed = String(body).trimmingCharacters(in: .whitespaces)

            // ── Fenced code ──────────────────────────────────────────────────
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var content: [String] = []
                // No closing fence is the streaming case, not a failure: take the rest.
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    content.append(next)
                }
                blocks.append(.code(language: info.isEmpty ? nil : info,
                                    text: content.joined(separator: "\n")))
                continue
            }

            // ── Blank ────────────────────────────────────────────────────────
            if trimmed.isEmpty { flushAll(); continue }

            // ── Thematic break ───────────────────────────────────────────────
            // Checked before headings so `---` isn't mistaken for anything else.
            if isRule(trimmed) { flushAll(); blocks.append(.rule); continue }

            // ── Heading ──────────────────────────────────────────────────────
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let rest = trimmed.dropFirst(hashes.count)
                // ATX headings need a space after the hashes; `#tag` is prose.
                if hashes.count <= 6, rest.first == " " {
                    flushAll()
                    blocks.append(.heading(
                        level: hashes.count,
                        text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            // ── Quote ────────────────────────────────────────────────────────
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            let depth = depth(for: indent)

            // ── Bullet ───────────────────────────────────────────────────────
            if let marker = trimmed.first, "-*+".contains(marker),
               trimmed.dropFirst().first == " " {
                flushAll()
                blocks.append(.bullet(
                    text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces),
                    depth: depth))
                continue
            }

            // ── Ordered item ─────────────────────────────────────────────────
            if let item = orderedItem(trimmed) {
                flushAll()
                blocks.append(.numbered(number: item.0, text: item.1, depth: depth))
                continue
            }

            // ── Prose ────────────────────────────────────────────────────────
            flushQuote()
            paragraph.append(trimmed)
        }

        flushAll()
        return blocks
    }

    /// Three or more of the same marker, nothing else on the line.
    private static func isRule(_ line: String) -> Bool {
        guard let first = line.first, "-*_".contains(first) else { return false }
        let stripped = line.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    /// `1. text` or `2) text` → (1, "text").
    private static func orderedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let text = rest.dropFirst()
        guard text.first == " " || text.isEmpty else { return nil }
        return (n, text.trimmingCharacters(in: .whitespaces))
    }

    /// Nesting level. Two spaces or one tab per level, capped — models indent
    /// inconsistently and a runaway depth would push text off a 380pt panel.
    private static func depth(for indent: Substring) -> Int {
        var columns = 0
        for ch in indent { columns += ch == "\t" ? 4 : 1 }
        return min(columns / 2, 3)
    }
}
