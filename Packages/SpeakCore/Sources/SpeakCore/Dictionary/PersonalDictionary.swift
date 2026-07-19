import Foundation

/// A single spoken-phrase → replacement rule.
public struct DictionaryEntry: Equatable, Sendable, Identifiable, Codable {
    public var id: Int64?
    /// The phrase as (mis)heard, e.g. "gaithano".
    public var phrase: String
    /// What it should become, e.g. "Gaithano".
    public var replacement: String
    /// When true, matching is case-sensitive; otherwise case-insensitive.
    public var matchCase: Bool
    public var sortOrder: Int

    public init(id: Int64? = nil, phrase: String, replacement: String, matchCase: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.matchCase = matchCase
        self.sortOrder = sortOrder
    }
}

/// Applies user dictionary rules to text deterministically. Whole-word matching
/// with proper Unicode-safe regex escaping; idempotent (applying twice equals
/// applying once for typical rules).
public struct PersonalDictionary: Sendable {
    public let entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        // Longer phrases first so multi-word rules win over their sub-phrases.
        self.entries = entries.sorted {
            if $0.phrase.count != $1.phrase.count { return $0.phrase.count > $1.phrase.count }
            return $0.sortOrder < $1.sortOrder
        }
    }

    /// Words worth handing to the formatter as spelling hints.
    public var vocabularyHints: [String] {
        entries.map(\.replacement).filter { !$0.isEmpty }
    }

    public func apply(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        var result = text
        for entry in entries {
            let phrase = entry.phrase.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { continue }
            result = Self.replace(phrase, with: entry.replacement, in: result, matchCase: entry.matchCase)
        }
        return result
    }

    /// Whole-word, escaped replacement. Word boundaries are approximated with
    /// look-arounds that treat letters/digits as "word" characters so that
    /// phrases beginning or ending with punctuation still match.
    static func replace(_ phrase: String, with replacement: String, in text: String, matchCase: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Boundary only enforced on sides that begin/end with a word character,
        // so rules like "c++" or ".net" still work.
        let leading = phrase.first.map(isWordCharacter) == true ? "(?<![\\p{L}\\p{N}])" : ""
        let trailing = phrase.last.map(isWordCharacter) == true ? "(?![\\p{L}\\p{N}])" : ""
        let pattern = leading + escaped + trailing
        var options: NSRegularExpression.Options = []
        if !matchCase { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let templateEscaped = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: templateEscaped)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
