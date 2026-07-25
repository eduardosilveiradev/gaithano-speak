import Foundation

/// A term the app noticed the formatter correcting, with a running count.
///
/// One row per distinct (phrase, replacement) pair. The count is what separates a
/// one-off model whim from something the user actually says: a term has to earn
/// its way into the dictionary by recurring.
public struct LearnedTerm: Equatable, Sendable, Identifiable, Codable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Seen, not yet acted on.
        case pending
        /// Promoted into the dictionary.
        case accepted
        /// The user said no. Never proposed again.
        case dismissed
    }

    public var id: Int64?
    public var phrase: String
    public var replacement: String
    public var kind: TermObservation.Kind
    public var occurrences: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var state: State

    public init(id: Int64? = nil,
                phrase: String,
                replacement: String,
                kind: TermObservation.Kind,
                occurrences: Int = 1,
                firstSeen: Date,
                lastSeen: Date,
                state: State = .pending) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.kind = kind
        self.occurrences = occurrences
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.state = state
    }

    public var asDictionaryEntry: DictionaryEntry {
        DictionaryEntry(phrase: phrase, replacement: replacement, source: .learned)
    }
}

/// When an observation becomes a dictionary entry.
///
/// The two kinds are held to different standards on purpose. A casing fix can only
/// ever change how a word the user already says is capitalised — the worst case is
/// an unwanted capital, visible the moment it happens. A spelling fix replaces one
/// word with a different one on every future dictation, and a wrong one is close to
/// invisible: the user reads what they meant to say. So casing lets itself in, and
/// spelling knocks.
public struct LearningPolicy: Equatable, Sendable {
    /// Times a casing fix must recur before it's applied on its own.
    public var casingThreshold: Int
    /// Times a spelling fix must recur before it's shown to the user.
    public var spellingThreshold: Int
    /// Let spelling fixes in without asking too. Off by default.
    public var autoAcceptSpelling: Bool

    public init(casingThreshold: Int = 3,
                spellingThreshold: Int = 2,
                autoAcceptSpelling: Bool = false) {
        self.casingThreshold = casingThreshold
        self.spellingThreshold = spellingThreshold
        self.autoAcceptSpelling = autoAcceptSpelling
    }

    public static let `default` = LearningPolicy()

    public enum Decision: Equatable, Sendable {
        /// Keep counting.
        case hold
        /// Show it to the user and wait.
        case suggest
        /// Write it into the dictionary now.
        case accept
    }

    public func decision(for term: LearnedTerm) -> Decision {
        // A settled term stays settled. In particular a dismissal is permanent —
        // re-proposing something the user already refused is how a helpful feature
        // turns into a nag.
        guard term.state == .pending else { return .hold }

        switch term.kind {
        case .casing:
            return term.occurrences >= casingThreshold ? .accept : .hold
        case .spelling:
            guard term.occurrences >= spellingThreshold else { return .hold }
            return autoAcceptSpelling ? .accept : .suggest
        }
    }
}

/// What one round of learning changed.
public struct LearningOutcome: Equatable, Sendable {
    /// Entries written straight into the dictionary.
    public var accepted: [DictionaryEntry]
    /// Terms now waiting for the user in Settings.
    public var suggested: [LearnedTerm]

    public init(accepted: [DictionaryEntry] = [], suggested: [LearnedTerm] = []) {
        self.accepted = accepted
        self.suggested = suggested
    }

    public var isEmpty: Bool { accepted.isEmpty && suggested.isEmpty }
}
