import Foundation
import Testing
@testable import SpeakCore

@Suite("Learning store")
struct LearningStoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func casing(_ phrase: String = "parakeet", _ replacement: String = "Parakeet") -> TermObservation {
        TermObservation(phrase: phrase, replacement: replacement, kind: .casing)
    }

    private func spelling(_ phrase: String = "gee are dee bee", _ replacement: String = "GRDB") -> TermObservation {
        TermObservation(phrase: phrase, replacement: replacement, kind: .spelling)
    }

    @Test("The learning migration leaves existing dictionary entries alone")
    func migrationPreservesEntries() throws {
        let db = try AppDatabase.inMemory()
        try db.upsert(DictionaryEntry(phrase: "gaithano", replacement: "Gaithano"))

        let entries = try db.allDictionaryEntries()
        #expect(entries.count == 1)
        // Anything written before learning existed is the user's own work.
        #expect(entries.first?.source == .manual)
    }

    @Test("A casing fix promotes itself once it recurs enough")
    func casingPromotes() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default

        for _ in 1..<policy.casingThreshold {
            #expect(try db.learn(from: [casing()], policy: policy, now: t0).isEmpty)
            #expect(try db.allDictionaryEntries().isEmpty)
        }

        let outcome = try db.learn(from: [casing()], policy: policy, now: t0)
        #expect(outcome.accepted.count == 1)
        #expect(outcome.suggested.isEmpty)

        let entries = try db.allDictionaryEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.replacement == "Parakeet")
        #expect(entries.first?.source == .learned)
    }

    @Test("A promoted term stops being counted")
    func promotedTermSettles() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        for _ in 0..<(policy.casingThreshold + 3) {
            try db.learn(from: [casing()], policy: policy, now: t0)
        }
        // Not once per subsequent utterance — once, ever.
        #expect(try db.allDictionaryEntries().count == 1)
    }

    @Test("A spelling fix waits to be asked about")
    func spellingSuggests() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default

        for _ in 1..<policy.spellingThreshold {
            #expect(try db.learn(from: [spelling()], policy: policy, now: t0).isEmpty)
        }

        let outcome = try db.learn(from: [spelling()], policy: policy, now: t0)
        #expect(outcome.accepted.isEmpty)
        #expect(outcome.suggested.count == 1)
        // Suggested is not applied.
        #expect(try db.allDictionaryEntries().isEmpty)
        #expect(try db.pendingLearnedTerms(policy: policy).count == 1)
    }

    @Test("Auto-accept lets spelling fixes in without asking")
    func spellingAutoAccept() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy(autoAcceptSpelling: true)

        var outcome = LearningOutcome()
        for _ in 0..<policy.spellingThreshold {
            outcome = try db.learn(from: [spelling()], policy: policy, now: t0)
        }
        #expect(outcome.accepted.count == 1)
        #expect(try db.allDictionaryEntries().first?.replacement == "GRDB")
    }

    @Test("Accepting a suggestion writes it to the dictionary")
    func acceptSuggestion() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        for _ in 0..<policy.spellingThreshold {
            try db.learn(from: [spelling()], policy: policy, now: t0)
        }

        let pending = try db.pendingLearnedTerms(policy: policy)
        let entry = try db.acceptLearnedTerm(id: #require(pending.first?.id))
        #expect(entry?.source == .learned)
        #expect(try db.allDictionaryEntries().count == 1)
        #expect(try db.pendingLearnedTerms(policy: policy).isEmpty)
    }

    @Test("A dismissed term is never proposed again")
    func dismissIsPermanent() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        for _ in 0..<policy.spellingThreshold {
            try db.learn(from: [spelling()], policy: policy, now: t0)
        }

        try db.dismissLearnedTerm(id: #require(try db.pendingLearnedTerms(policy: policy).first?.id))
        #expect(try db.pendingLearnedTerms(policy: policy).isEmpty)

        // Saying it ten more times must not resurrect it.
        for _ in 0..<10 {
            #expect(try db.learn(from: [spelling()], policy: policy, now: t0).isEmpty)
        }
        #expect(try db.pendingLearnedTerms(policy: policy).isEmpty)
        #expect(try db.allDictionaryEntries().isEmpty)
    }

    @Test("A hand-written rule for the same phrase wins")
    func manualEntryWins() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        try db.upsert(DictionaryEntry(phrase: "parakeet", replacement: "PARAKEET"))

        for _ in 0..<policy.casingThreshold {
            try db.learn(from: [casing()], policy: policy, now: t0)
        }

        let entries = try db.allDictionaryEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.replacement == "PARAKEET")
        // Settled rather than left pending, so it stops being re-evaluated.
        #expect(try db.pendingLearnedTerms(policy: policy).isEmpty)
    }

    @Test("Distinct replacements for one phrase are counted separately")
    func distinctReplacements() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        try db.learn(from: [casing("parakeet", "Parakeet")], policy: policy, now: t0)
        try db.learn(from: [casing("parakeet", "ParaKeet")], policy: policy, now: t0)

        // Two rows at one occurrence each — neither has earned anything.
        #expect(try db.allDictionaryEntries().isEmpty)
    }

    @Test("Forgetting removes learned entries but not manual ones")
    func forget() throws {
        let db = try AppDatabase.inMemory()
        let policy = LearningPolicy.default
        try db.upsert(DictionaryEntry(phrase: "gaithano", replacement: "Gaithano"))
        for _ in 0..<policy.casingThreshold {
            try db.learn(from: [casing()], policy: policy, now: t0)
        }
        #expect(try db.allDictionaryEntries().count == 2)

        try db.forgetLearnedTerms()
        let entries = try db.allDictionaryEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.phrase == "gaithano")
        // A reset really resets: the term can be learned again from scratch.
        for _ in 0..<policy.casingThreshold {
            try db.learn(from: [casing()], policy: policy, now: t0)
        }
        #expect(try db.allDictionaryEntries().count == 2)
    }

    @Test("Learning nothing does nothing")
    func emptyObservations() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.learn(from: []).isEmpty)
    }
}
