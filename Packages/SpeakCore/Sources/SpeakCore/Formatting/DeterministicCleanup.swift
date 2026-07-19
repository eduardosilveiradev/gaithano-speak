import Foundation

/// Non-AI transcript cleanup: the always-available fallback when the on-device
/// model is unavailable, refuses, or times out. Conservative by design — it only
/// does things that can't change meaning: strip a small set of filler words,
/// collapse whitespace, capitalize sentences, and fix spacing around punctuation.
public struct DeterministicCleanup: TextFormatter {
    public let id: FormatterID = .deterministic

    /// Filler words removed only when standing alone (never inside another word).
    static let fillers: Set<String> = ["um", "uh", "erm", "uhh", "umm", "hmm", "mhm"]

    public init() {}

    public func format(_ raw: String, hints: FormattingHints) async throws -> FormattedResult {
        FormattedResult(text: Self.clean(raw), formatter: .deterministic)
    }

    public static func clean(_ input: String) -> String {
        var text = input

        // Remove standalone filler words (case-insensitive, whole word).
        for filler in fillers {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: filler) + "(?![\\p{L}\\p{N}])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        }

        // Tighten spacing before punctuation: " ," -> ","
        text = replaceRegex(text, #"\s+([,.!?;:])"#, "$1")
        // Collapse runs of whitespace.
        text = replaceRegex(text, #"[ \t]{2,}"#, " ")
        // Trim spaces around newlines.
        text = replaceRegex(text, #"[ \t]*\n[ \t]*"#, "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        text = capitalizeSentences(text)
        return text
    }

    /// Capitalize the first letter of the text and the first letter after a
    /// sentence terminator.
    static func capitalizeSentences(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var capitalizeNext = true
        for char in input {
            if capitalizeNext, char.isLetter {
                result.append(contentsOf: String(char).uppercased())
                capitalizeNext = false
            } else {
                result.append(char)
                if char == "." || char == "!" || char == "?" || char == "\n" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }

    private static func replaceRegex(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
