import Foundation
import Testing
@testable import SpeakCore

@Suite("Dictionary learning")
struct DictionaryLearnerTests {

    // MARK: - What it should learn

    @Test("Learns a mid-sentence casing fix")
    func casingMidSentence() {
        let found = DictionaryLearner.observe(
            heard: "we shipped the parakeet engine today",
            written: "We shipped the Parakeet engine today."
        )
        #expect(found == [TermObservation(phrase: "parakeet", replacement: "Parakeet", kind: .casing)])
    }

    @Test("Learns a spelled-out acronym")
    func spelledOutAcronym() {
        let found = DictionaryLearner.observe(
            heard: "the gee are dee bee layer handles migrations",
            written: "The GRDB layer handles migrations."
        )
        #expect(found == [TermObservation(phrase: "gee are dee bee", replacement: "GRDB", kind: .spelling)])
    }

    @Test("Learns a one-word misspelling of a term")
    func misspelledTerm() {
        let found = DictionaryLearner.observe(
            heard: "open the grdb file",
            written: "Open the GRDB file."
        )
        #expect(found == [TermObservation(phrase: "grdb", replacement: "GRDB", kind: .casing)])
    }

    @Test("Learns a hyphenated model name")
    func hyphenatedName() {
        let found = DictionaryLearner.observe(
            heard: "ask gpt four about it",
            written: "Ask GPT-4 about it."
        )
        #expect(found.count == 1)
        #expect(found.first?.replacement == "GPT-4")
        #expect(found.first?.kind == .spelling)
    }

    @Test("Learns a term with a leading joiner")
    func leadingJoiner() {
        #expect(DictionaryLearner.looksLikeTerm(".NET"))
        #expect(DictionaryLearner.looksLikeTerm("CoreML"))
        #expect(DictionaryLearner.looksLikeTerm("GPT-4"))
        #expect(DictionaryLearner.looksLikeTerm("k8s"))
    }

    // MARK: - What it must refuse

    @Test("Rejects a sentence-initial capital")
    func sentenceInitialCapital() {
        // Every sentence starts with a capital. Learning "today" → "Today" would
        // capitalise the word everywhere it appears.
        let found = DictionaryLearner.observe(
            heard: "today we shipped it",
            written: "Today we shipped it."
        )
        #expect(found.isEmpty)
    }

    @Test("Rejects a grammar fix that changes the word")
    func grammarFix() {
        // The canonical corruption: promoting this would rewrite "there" forever.
        let found = DictionaryLearner.observe(
            heard: "put it over there desk",
            written: "Put it over their desk."
        )
        #expect(found.isEmpty)
    }

    @Test("Rejects an ordinary lowercase word swap")
    func ordinaryWordSwap() {
        let found = DictionaryLearner.observe(
            heard: "i want to right this down",
            written: "I want to write this down."
        )
        #expect(found.isEmpty)
    }

    @Test("Rejects a term that isn't phonetically reachable")
    func phoneticallyUnreachable() {
        // Shaped like a term, but nothing like what was heard — the model
        // substituted rather than corrected.
        let found = DictionaryLearner.observe(
            heard: "use the widget for that",
            written: "Use the PostgreSQL for that."
        )
        #expect(found.isEmpty)
    }

    @Test("Rejects one word expanding into several")
    func expansion() {
        let found = DictionaryLearner.observe(
            heard: "eta is unclear",
            written: "Estimated time of arrival is unclear."
        )
        #expect(found.isEmpty)
    }

    @Test("Rejects bare numbers")
    func bareNumbers() {
        let found = DictionaryLearner.observe(
            heard: "we need twenty of them",
            written: "We need 20 of them."
        )
        #expect(found.isEmpty)
    }

    @Test("Discards everything when an utterance was paraphrased")
    func paraphraseDiscardsBatch() {
        // Five plausible candidates in one sentence means the model rewrote it.
        let heard = "the crml and grdb and swiftui and appkit and coreml parts"
        let written = "The CoreML and GRDB and SwiftUI and AppKit and CoreML parts."
        let found = DictionaryLearner.observe(heard: heard, written: written)
        #expect(found.isEmpty)
    }

    @Test("Ignores over-long dictations")
    func overLongDictation() {
        let heard = Array(repeating: "word", count: DictionaryLearner.maxTokens + 5).joined(separator: " ")
        let written = heard + " CoreML"
        #expect(DictionaryLearner.observe(heard: heard, written: written).isEmpty)
    }

    @Test("Empty input yields nothing")
    func emptyInput() {
        #expect(DictionaryLearner.observe(heard: "", written: "Hello.").isEmpty)
        #expect(DictionaryLearner.observe(heard: "hello", written: "").isEmpty)
    }

    @Test("Identical text yields nothing")
    func identicalText() {
        #expect(DictionaryLearner.observe(heard: "nothing changed here",
                                          written: "nothing changed here").isEmpty)
    }

    @Test("Punctuation-only changes yield nothing")
    func punctuationOnly() {
        let found = DictionaryLearner.observe(
            heard: "hello there how are you",
            written: "Hello there, how are you?"
        )
        #expect(found.isEmpty)
    }

    @Test("Does not duplicate a term repeated in one utterance")
    func repeatedTermDeduped() {
        let found = DictionaryLearner.observe(
            heard: "the grdb layer and the grdb tests",
            written: "The GRDB layer and the GRDB tests."
        )
        #expect(found.count == 1)
    }

    // MARK: - Phonetics

    @Test("Skeletons drop vowels and collapse runs")
    func skeletons() {
        #expect(Phonetics.skeleton("GRDB") == "grdb")
        #expect(Phonetics.skeleton("gee are dee bee") == "grdb")
        #expect(Phonetics.skeleton("CoreML") == "crml")
        #expect(Phonetics.skeleton("core em el") == "crml")
    }

    @Test("Close words are close; unrelated ones are not")
    func closeness() {
        #expect(Phonetics.areClose("grdb", "grdb"))
        #expect(Phonetics.areClose("coreml", "corml"))
        #expect(!Phonetics.areClose("widget", "postgresql"))
        // Homophones ARE close, deliberately. Phonetics is not the thing that keeps
        // "there" → "their" out — `looksLikeTerm` is. Both gates have to hold.
        #expect(Phonetics.areClose("there", "their"))
    }

    @Test("Edit distance is symmetric and correct")
    func editDistance() {
        #expect(Phonetics.editDistance("kitten", "sitting") == 3)
        #expect(Phonetics.editDistance("abc", "abc") == 0)
        #expect(Phonetics.editDistance("", "abc") == 3)
        #expect(Phonetics.editDistance("abc", "") == 3)
    }

    // MARK: - Policy

    @Test("Casing promotes itself at the threshold")
    func casingPromotes() {
        let policy = LearningPolicy.default
        #expect(policy.decision(for: term(kind: .casing, occurrences: policy.casingThreshold - 1)) == .hold)
        #expect(policy.decision(for: term(kind: .casing, occurrences: policy.casingThreshold)) == .accept)
    }

    @Test("Spelling asks instead of promoting")
    func spellingSuggests() {
        let policy = LearningPolicy.default
        #expect(policy.decision(for: term(kind: .spelling, occurrences: policy.spellingThreshold - 1)) == .hold)
        #expect(policy.decision(for: term(kind: .spelling, occurrences: policy.spellingThreshold)) == .suggest)
    }

    @Test("Auto-accept promotes spelling too")
    func autoAcceptSpelling() {
        let policy = LearningPolicy(autoAcceptSpelling: true)
        #expect(policy.decision(for: term(kind: .spelling, occurrences: policy.spellingThreshold)) == .accept)
    }

    @Test("A settled term never moves again")
    func settledStaysSettled() {
        let policy = LearningPolicy.default
        for state in [LearnedTerm.State.accepted, .dismissed] {
            var t = term(kind: .casing, occurrences: 99)
            t.state = state
            #expect(policy.decision(for: t) == .hold)
        }
    }

    private func term(kind: TermObservation.Kind, occurrences: Int) -> LearnedTerm {
        LearnedTerm(phrase: "grdb",
                    replacement: "GRDB",
                    kind: kind,
                    occurrences: occurrences,
                    firstSeen: Date(timeIntervalSince1970: 0),
                    lastSeen: Date(timeIntervalSince1970: 0))
    }
}
