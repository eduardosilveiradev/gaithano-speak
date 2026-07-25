import Foundation

/// Cheap phonetic comparison for dictionary learning.
///
/// Not a real metaphone — a consonant skeleton, which is all this needs. The
/// question being asked is only ever "could the engine have heard *this* and
/// meant *that*", and the failure mode of a false match is one rejected
/// suggestion, not a wrong insertion. Vowels are exactly what a speech model
/// mangles, so dropping them is the whole trick:
///
///     "gee are dee bee" → "grdb"   ==   "GRDB"   → "grdb"
///     "core em el"      → "crml"   ==   "CoreML" → "crml"
public enum Phonetics {
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Digits are spoken as words, so they have to be compared as words. Without
    /// this, "gee pee tee four" and "GPT-4" share nothing at all.
    private static let spokenDigits: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine"
    ]

    /// Lowercased letters and digits with vowels dropped and runs collapsed.
    /// A word that is *all* vowels keeps them, so "I" and "IEEE" still compare.
    public static func skeleton(_ text: String) -> String {
        let alphanumeric = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !alphanumeric.isEmpty else { return "" }

        var letters = ""
        for c in alphanumeric { letters += spokenDigits[c] ?? String(c) }

        let stripped = letters.filter { !vowels.contains($0) }
        let base = stripped.isEmpty ? letters : stripped

        var out = ""
        for c in base where out.last != c { out.append(c) }
        return out
    }

    /// Whether two strings could plausibly be the same spoken word.
    public static func areClose(_ a: String, _ b: String) -> Bool {
        let sa = skeleton(a), sb = skeleton(b)
        guard !sa.isEmpty, !sb.isEmpty else { return false }
        if sa == sb { return true }
        // One skeleton edit apart covers a dropped or doubled consonant, which is
        // the other thing engines do. Anything looser starts matching unrelated words.
        return editDistance(sa, sb) <= 1 && min(sa.count, sb.count) >= 3
    }

    /// Standard Levenshtein, two-row. Small inputs; no need for anything cleverer.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var prev = Array(0...y.count)
        var row = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            row[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &row)
        }
        return prev[y.count]
    }
}
