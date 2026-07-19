import Foundation

/// Small pure helpers for word counting and words-per-minute.
public enum DictationStats {
    public static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
            .filter { !$0.isEmpty }
            .count
    }

    /// Words per minute over a spoken duration. Returns 0 for non-positive
    /// durations to avoid division blow-ups.
    public static func wordsPerMinute(words: Int, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(words) / (duration / 60.0)
    }
}

/// Aggregate stats for the history view header.
public struct AggregateStats: Equatable, Sendable {
    public var totalDictations: Int
    public var totalWords: Int
    public var averageWPM: Double

    public init(totalDictations: Int = 0, totalWords: Int = 0, averageWPM: Double = 0) {
        self.totalDictations = totalDictations
        self.totalWords = totalWords
        self.averageWPM = averageWPM
    }
}
