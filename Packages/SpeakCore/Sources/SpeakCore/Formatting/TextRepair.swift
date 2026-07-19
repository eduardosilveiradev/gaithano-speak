import Foundation

/// Deterministic, always-safe fixups applied to the final text regardless of which
/// formatter ran. The model should catch these, but this is a cheap safety net for
/// the common dictation artifact of a doubled word.
public enum TextRepair {
    /// Words that are (almost) never validly doubled in English, so collapsing a
    /// consecutive repeat is safe. Deliberately excludes "that", "had", "is is"
    /// edge cases where doubling can be grammatical ("I know that that works").
    static let safeToDedup: Set<String> = [
        "the", "a", "an", "and", "to", "of", "in", "on", "at", "it", "is",
        "i", "we", "you", "for", "with", "but", "so", "or", "as", "if", "my",
        "he", "she", "they", "this", "these", "those", "was", "are"
    ]

    /// Collapse consecutive duplicate words from `safeToDedup` (case-insensitive),
    /// keeping the first occurrence's casing. Runs until stable so triples collapse.
    public static func removeAccidentalDuplicates(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let alternation = safeToDedup.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // \b(word)\b <whitespace> \b\1\b  -> first word
        let pattern = "(?i)\\b(\(alternation))\\b(\\s+)\\b\\1\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        // Loop so "the the the" fully collapses (non-overlapping matches leave one).
        for _ in 0..<3 {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let next = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            if next == result { break }
            result = next
        }
        return result
    }

    // MARK: - Cursor merge

    /// Characters that glue tight to the preceding word — no space before them.
    private static let noSpaceBefore: Set<Character> = [
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "”", "’"
    ]

    /// Words that stay capitalized even mid-sentence (never lowercased on a merge).
    private static let alwaysCapitalized: Set<String> = [
        "I", "I'm", "I've", "I'll", "I'd", "I’m", "I’ve", "I’ll", "I’d"
    ]

    /// Compute the correct separator when inserting `insertion` right after
    /// `precedingText` at the cursor. This is the deterministic fix for dictation
    /// that was split because the user released the key mid-thought: it guarantees
    /// exactly one space between the existing text and the new text — or none when
    /// the field already ends with whitespace, or the new text starts with closing
    /// punctuation. Any leading spaces/tabs the model added are normalized away, so
    /// it's idempotent regardless of how the formatter behaved.
    public static func joinAtCursor(_ insertion: String, precedingText: String?) -> String {
        // Strip leading spaces/tabs (but keep newlines — "new paragraph" etc.).
        let leadCount = insertion.prefix { $0 == " " || $0 == "\t" }.count
        let body = String(insertion.dropFirst(leadCount))
        guard !body.isEmpty else { return "" }

        // Nothing before the cursor → no leading space (start of a field).
        guard let preceding = precedingText, !preceding.isEmpty else { return body }

        // Field already ends with whitespace → separator is already there.
        if let last = preceding.last, last.isWhitespace { return body }

        // Glue tight when the new text begins on a new line or with closing punct.
        if let first = body.first {
            if first == "\n" { return body }
            if noSpaceBefore.contains(first) { return body }
        }
        return " " + body
    }

    /// When the text before the cursor ends mid-sentence (no terminal `.`/`!`/`?`
    /// and not a line break), lowercase the first word of `insertion` so the two
    /// halves read as one sentence — the accidental-split case. Skips words that
    /// stay capitalized ("I", contractions) and all-caps acronyms (NASA, API).
    /// Used on the deterministic path; the model handles this itself when it runs.
    public static func lowercaseContinuationIfMidSentence(_ insertion: String, precedingText: String?) -> String {
        guard let preceding = precedingText,
              let lastNonWS = preceding.reversed().first(where: { !$0.isWhitespace }) else {
            return insertion
        }
        // Previous sentence is finished, or we're on a fresh line → keep the capital.
        if lastNonWS == "." || lastNonWS == "!" || lastNonWS == "?" { return insertion }
        if preceding.last == "\n" { return insertion }

        guard let firstLetterIdx = insertion.firstIndex(where: { $0.isLetter }) else { return insertion }
        let firstChar = insertion[firstLetterIdx]
        guard firstChar.isUppercase else { return insertion }

        // Isolate the leading word for the keep-capital / acronym checks.
        let wordEnd = insertion[firstLetterIdx...].firstIndex { !($0.isLetter || $0 == "'" || $0 == "’") } ?? insertion.endIndex
        let word = String(insertion[firstLetterIdx..<wordEnd])
        if alwaysCapitalized.contains(word) { return insertion }
        if word.count > 1 && word == word.uppercased() { return insertion } // acronym

        return String(insertion[..<firstLetterIdx])
            + firstChar.lowercased()
            + String(insertion[insertion.index(after: firstLetterIdx)...])
    }

    /// Strip a reasoning model's scratchpad so only the final cleaned text is
    /// inserted. Handles three shapes seen in the wild:
    ///  - `<think>…</think>` blocks (Qwen3, DeepSeek-R1), balanced or truncated.
    ///  - Harmony / channel markup (gpt-oss and some abliterated Gemma "heretic"
    ///    builds): `<|channel>thought … <channel|>ANSWER`, or
    ///    `…<|channel|>final<|message|>ANSWER<|end|>`. The real answer is whatever
    ///    follows the LAST channel/message delimiter.
    ///  - Any residual special tokens (`<|end|>`, `<|start|>`, …) left behind.
    public static func stripReasoningTags(_ text: String) -> String {
        var out = text

        // 1) Balanced <think>…</think>.
        if let r = try? NSRegularExpression(pattern: "<think>.*?</think>",
                                            options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }

        // 2) Channel/harmony reasoning: keep only what follows the LAST channel or
        //    message delimiter, matched loosely so every pipe placement counts
        //    (<|channel>, <channel|>, <|channel|>, <|message|>).
        if let r = try? NSRegularExpression(pattern: "<\\|?(?:channel|message)\\|?>",
                                            options: [.caseInsensitive]) {
            let ns = out as NSString
            let matches = r.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if let last = matches.last {
                out = ns.substring(from: last.range.location + last.range.length)
            }
        }

        // 3) Unbalanced <think> remnants after the above.
        if let close = out.range(of: "</think>", options: .caseInsensitive) {
            out = String(out[close.upperBound...])                       // keep the real answer after it
        } else if let open = out.range(of: "<think>", options: .caseInsensitive) {
            out = String(out[..<open.lowerBound])                        // drop an unterminated scratchpad
        }

        // 4) Nuke any residual special tokens (trailing <|end|>, stray <|start|>, …).
        if let r = try? NSRegularExpression(pattern: "<\\|[^>]*>|<[^>]*\\|>",
                                            options: []) {
            out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize an OpenAI-compatible base URL: trim, drop a trailing slash, and
    /// ensure it ends in `/v1` (so users can enter `http://localhost:1234` or the
    /// full `…/v1`). Returns nil if it isn't a usable http(s) URL.
    public static func normalizedOpenAIBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasSuffix("/v1") { s += "/v1" }
        return s
    }

    /// Ensure `text` ends with a single trailing space so the next separately-
    /// dictated chunk doesn't collide with this one. Used when we CAN'T read the
    /// field's existing text — empty native fields, or Electron/web apps (Claude
    /// Desktop, VS Code, most web editors) that don't expose their AX value — so we
    /// have no preceding text to compute a leading seam from. No-op if the text is
    /// empty or already ends in whitespace / a newline.
    public static func appendSeparatorSpace(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        return text + " "
    }
}
