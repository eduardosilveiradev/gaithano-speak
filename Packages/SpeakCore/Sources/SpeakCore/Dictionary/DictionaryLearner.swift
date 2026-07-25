import Foundation

/// One "the engine heard X, the formatter wrote Y" pair worth remembering.
public struct TermObservation: Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Same word, different capitalisation — "parakeet" → "Parakeet".
        case casing
        /// Different letters — "gee are dee bee" → "GRDB".
        case spelling
    }

    public let phrase: String
    public let replacement: String
    public let kind: Kind

    public init(phrase: String, replacement: String, kind: Kind) {
        self.phrase = phrase
        self.replacement = replacement
        self.kind = kind
    }
}

/// Reads the formatter's own corrections and proposes dictionary entries from them.
///
/// The insight this rests on: the formatting model already fixes the user's proper
/// nouns, and it does it *with* the surrounding sentence for context, which is far
/// more than the dictionary pass can see. Every one of those fixes is a free,
/// already-verified example of how this particular person's speech maps onto the
/// words they mean. Recording them turns a per-utterance correction into a
/// permanent one that the deterministic pass can make for free, before the model
/// ever runs — which also means it keeps working on the short utterances and the
/// offline fallback path where the model never runs at all.
///
/// It is deliberately hard to please. A formatter rewrite is mostly grammar, and
/// grammar is not vocabulary: promoting "there" → "their" into the dictionary
/// would corrupt every future dictation containing the word. So a candidate has to
/// look like a *term* — internal capitals, a digit, or internal punctuation — and
/// it has to be phonetically reachable from what was heard. Everything else is
/// dropped. Missing a real term costs the user one manual entry; inventing a fake
/// one costs them a silent corruption they have to go find.
public enum DictionaryLearner {
    /// Longest run of heard words that may collapse into one written term. Four
    /// covers spelled-out acronyms ("gee are dee bee"); beyond that the alignment
    /// is guessing.
    public static let maxHeardRun = 4

    /// Most observations one utterance may contribute. A formatter that "found"
    /// five new terms in one sentence paraphrased it; that isn't vocabulary.
    public static let maxPerUtterance = 4

    /// Token budget for the alignment. Long dictations are the ones least likely
    /// to be about a single term, so bailing out costs nothing.
    static let maxTokens = 400

    /// Diff what the engine produced against what the formatter returned.
    ///
    /// - Parameters:
    ///   - heard: the text handed to the formatter (after the dictionary pre-pass,
    ///     so terms the user already taught it are not re-learned).
    ///   - written: the formatter's output, before the dictionary post-pass and
    ///     any seam repair — those are this app's edits, not the model's.
    public static func observe(heard: String, written: String) -> [TermObservation] {
        let source = tokenize(heard)
        let result = tokenize(written, markingSentenceStarts: true)
        guard !source.isEmpty, !result.isEmpty,
              source.count <= maxTokens, result.count <= maxTokens else { return [] }

        var found: [TermObservation] = []
        var seen = Set<TermObservation>()

        for (heardRun, writtenRun) in alignmentGaps(source, result) {
            guard let candidate = candidate(heardRun: heardRun, writtenRun: writtenRun) else { continue }
            guard seen.insert(candidate).inserted else { continue }
            found.append(candidate)
        }

        // An utterance that produced a pile of candidates was paraphrased, not
        // corrected. Trust none of them rather than the first few.
        return found.count > maxPerUtterance ? [] : found
    }

    // MARK: - Classification

    private static func candidate(heardRun: [Token], writtenRun: [Token]) -> TermObservation? {
        // Only ever learn "some words → one term". One heard word becoming several
        // written ones is expansion, which the dictionary can't express usefully.
        guard writtenRun.count == 1, let target = writtenRun.first else { return nil }
        guard (1...maxHeardRun).contains(heardRun.count) else { return nil }
        guard target.text.count >= 2, target.key.count >= 2 else { return nil }
        // A bare number is a transcription of a quantity, not a term.
        guard !target.key.allSatisfy(\.isNumber) else { return nil }

        let phrase = heardRun.map(\.text).joined(separator: " ")
        guard phrase.count >= 2 else { return nil }

        if heardRun.count == 1, let heardToken = heardRun.first {
            // Same word, different case.
            if heardToken.key == target.key {
                guard heardToken.text != target.text else { return nil }
                // A capital at the start of a sentence is punctuation, not a name.
                // Anything shaped like a term ("CoreML", "GPT-4") is exempt — that
                // shape is meaningful wherever it appears.
                guard looksLikeTerm(target.text)
                        || (!target.startsSentence && target.text.first?.isUppercase == true)
                else { return nil }
                return TermObservation(phrase: phrase, replacement: target.text, kind: .casing)
            }

            // Different word. This is where grammar fixes live, so the bar is the
            // term shape — "their" is rejected, "GRDB" is not.
            guard looksLikeTerm(target.text) else { return nil }
            guard Phonetics.areClose(heardToken.key, target.key) else { return nil }
            return TermObservation(phrase: phrase, replacement: target.text, kind: .spelling)
        }

        // Several heard words → one term. Almost always a spelled-out acronym.
        guard looksLikeTerm(target.text) else { return nil }
        let joined = heardRun.map(\.key).joined()
        guard Phonetics.areClose(joined, target.key) else { return nil }
        return TermObservation(phrase: phrase, replacement: target.text, kind: .spelling)
    }

    /// Whether a written form is shaped like a term rather than an ordinary word.
    /// Sentence-initial capitals are excluded on purpose: every word can have one.
    static func looksLikeTerm(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 2 else { return false }

        if chars.contains(where: \.isNumber) { return true }
        if chars.dropFirst().contains(where: \.isUppercase) { return true }

        let joiners: Set<Character> = [".", "-", "+", "_", "/", "&"]
        let interior = chars.dropFirst().dropLast()
        if interior.contains(where: { joiners.contains($0) }) { return true }
        // Leading punctuation is load-bearing in a few real names (".NET").
        if let first = chars.first, joiners.contains(first) { return true }

        return false
    }

    // MARK: - Tokens

    struct Token: Equatable {
        /// The word as written, minus surrounding punctuation.
        var text: String
        /// Lowercased letters and digits — the identity used for alignment.
        var key: String
        /// Whether this token opens a sentence (written side only).
        var startsSentence: Bool
    }

    private static let edgeTrim = CharacterSet(charactersIn: ",;:!?\"'“”‘’()[]{}…")
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", ";"]

    static func tokenize(_ text: String, markingSentenceStarts: Bool = false) -> [Token] {
        let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var tokens: [Token] = []
        var opensSentence = true

        for piece in pieces {
            var trimmed = piece.trimmingCharacters(in: edgeTrim)
            // Trailing periods end sentences; leading ones can be part of the name.
            while let last = trimmed.last, last == "." { trimmed.removeLast() }

            let key = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
            if !key.isEmpty {
                tokens.append(Token(text: trimmed,
                                    key: key,
                                    startsSentence: markingSentenceStarts && opensSentence))
            }

            // Look at the untrimmed piece: the punctuation we just removed is
            // exactly the signal for whether the next word opens a sentence.
            let tail = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’)]}"))
            if let last = tail.last, sentenceEnders.contains(last) {
                opensSentence = true
            } else if !key.isEmpty {
                opensSentence = false
            }
        }
        return tokens
    }

    // MARK: - Alignment

    /// Longest-common-subsequence alignment on token keys, returning only the
    /// mismatched regions as (heard, written) runs.
    static func alignmentGaps(_ source: [Token], _ result: [Token]) -> [([Token], [Token])] {
        let n = source.count, m = result.count
        // table[i][j] = LCS length of source[i...] and result[j...]
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = source[i].key == result[j].key
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var gaps: [([Token], [Token])] = []
        var i = 0, j = 0
        var heardRun: [Token] = [], writtenRun: [Token] = []

        func flush() {
            if !heardRun.isEmpty || !writtenRun.isEmpty {
                gaps.append((heardRun, writtenRun))
                heardRun.removeAll(); writtenRun.removeAll()
            }
        }

        while i < n && j < m {
            if source[i].key == result[j].key {
                flush()
                // Alignment runs on keys so it can match through a casing change —
                // which means a casing change produces no gap. Emit the aligned pair
                // itself when the spelling differs, or `parakeet` → `Parakeet` would
                // be invisible to this whole mechanism.
                if source[i].text != result[j].text {
                    gaps.append(([source[i]], [result[j]]))
                }
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                heardRun.append(source[i]); i += 1
            } else {
                writtenRun.append(result[j]); j += 1
            }
        }
        while i < n { heardRun.append(source[i]); i += 1 }
        while j < m { writtenRun.append(result[j]); j += 1 }
        flush()

        return gaps
    }
}
