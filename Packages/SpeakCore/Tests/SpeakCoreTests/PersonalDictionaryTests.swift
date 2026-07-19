import Testing
@testable import SpeakCore

@Suite("Personal dictionary")
struct PersonalDictionaryTests {

    @Test("Whole-word replacement, case-insensitive by default")
    func basicReplacement() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "gaithano", replacement: "Gaithano")
        ])
        #expect(dict.apply("i love gaithano speak") == "i love Gaithano speak")
        #expect(dict.apply("GAITHANO rocks") == "Gaithano rocks")
    }

    @Test("Does not match inside other words")
    func wordBoundary() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "cat", replacement: "DOG")
        ])
        #expect(dict.apply("the cat sat") == "the DOG sat")
        #expect(dict.apply("category concatenate") == "category concatenate")
    }

    @Test("Regex metacharacters in the phrase are escaped")
    func regexEscaping() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "c++", replacement: "C plus plus"),
            DictionaryEntry(phrase: ".net", replacement: "dotnet")
        ])
        #expect(dict.apply("i code in c++ daily") == "i code in C plus plus daily")
        #expect(dict.apply("the .net runtime") == "the dotnet runtime")
    }

    @Test("Replacement text with $ is treated literally, not as a template")
    func dollarInReplacement() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "price", replacement: "$5")
        ])
        #expect(dict.apply("the price today") == "the $5 today")
    }

    @Test("Case-sensitive rules only match exact case")
    func caseSensitive() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "IOS", replacement: "iOS", matchCase: true)
        ])
        #expect(dict.apply("IOS and ios") == "iOS and ios")
    }

    @Test("Idempotent: applying twice equals applying once")
    func idempotent() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "javascript", replacement: "JavaScript")
        ])
        let once = dict.apply("i use javascript")
        let twice = dict.apply(once)
        #expect(once == twice)
        #expect(once == "i use JavaScript")
    }

    @Test("Longer phrases win over shorter overlapping ones")
    func longestFirst() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "new york", replacement: "NYC"),
            DictionaryEntry(phrase: "york", replacement: "Yorkshire")
        ])
        #expect(dict.apply("i live in new york") == "i live in NYC")
    }

    @Test("Vocabulary hints come from replacements")
    func vocabHints() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "gaithano", replacement: "Gaithano"),
            DictionaryEntry(phrase: "js", replacement: "JavaScript")
        ])
        #expect(Set(dict.vocabularyHints) == Set(["Gaithano", "JavaScript"]))
    }

    @Test("Empty dictionary is a no-op")
    func emptyNoop() {
        let dict = PersonalDictionary()
        #expect(dict.apply("unchanged text") == "unchanged text")
    }

    @Test("Unicode phrases match")
    func unicode() {
        let dict = PersonalDictionary(entries: [
            DictionaryEntry(phrase: "café", replacement: "Café Central")
        ])
        #expect(dict.apply("meet at café now") == "meet at Café Central now")
    }
}
