import Testing
import Foundation
@testable import SpeakCore

@Suite("Deterministic cleanup")
struct DeterministicCleanupTests {

    @Test("Strips standalone filler words")
    func stripsFillers() {
        let out = DeterministicCleanup.clean("um so uh this is a test")
        #expect(!out.lowercased().contains("um "))
        #expect(out.contains("this is a test"))
    }

    @Test("Does not strip fillers inside words")
    func keepsFillersInWords() {
        let out = DeterministicCleanup.clean("the umbrella is huge")
        #expect(out.contains("umbrella"))
    }

    @Test("Capitalizes the first letter and after sentence terminators")
    func capitalizes() {
        #expect(DeterministicCleanup.clean("hello world") == "Hello world")
        #expect(DeterministicCleanup.clean("hi there. how are you") == "Hi there. How are you")
    }

    @Test("Tightens spacing before punctuation")
    func tightensPunctuation() {
        #expect(DeterministicCleanup.clean("wait , what ?") == "Wait, what?")
    }

    @Test("Collapses repeated whitespace and trims")
    func collapsesWhitespace() {
        #expect(DeterministicCleanup.clean("too    many     spaces  ") == "Too many spaces")
    }

    @Test("Empty input stays empty")
    func empty() {
        #expect(DeterministicCleanup.clean("") == "")
    }

    @Test("Formatter protocol conformance returns deterministic id")
    func formatterID() async throws {
        let result = try await DeterministicCleanup().format("um hello", hints: .none)
        #expect(result.formatter == .deterministic)
        #expect(result.text == "Hello")
    }
}

@Suite("Prompt builder")
struct PromptBuilderTests {

    @Test("Instructions forbid answering the transcript")
    func instructionsGuardAgainstAnswering() {
        #expect(PromptBuilder.instructions.contains("NEVER answer"))
    }

    @Test("Vocabulary hints are injected")
    func vocabInjected() {
        let prompt = PromptBuilder.prompt(for: "hello gaithano",
                                          hints: FormattingHints(vocabulary: ["Gaithano", "SwiftUI"]))
        #expect(prompt.contains("Gaithano"))
        #expect(prompt.contains("SwiftUI"))
        #expect(prompt.contains("hello gaithano"))
    }

    @Test("Vocabulary is capped at 50 entries")
    func vocabCapped() {
        let many = (1...100).map { "Word\($0)" }
        let prompt = PromptBuilder.prompt(for: "text", hints: FormattingHints(vocabulary: many))
        #expect(prompt.contains("Word50"))
        #expect(!prompt.contains("Word51"))
    }

    @Test("No-structure hint adds a prose directive")
    func noStructure() {
        let prompt = PromptBuilder.prompt(for: "a b c", hints: FormattingHints(allowStructure: false))
        #expect(prompt.contains("running prose"))
    }

    @Test("Short utterances skip the model")
    func skipsShort() {
        #expect(!PromptBuilder.shouldUseModel(for: "yes please do"))
        #expect(PromptBuilder.shouldUseModel(for: "this one has plenty of words to format"))
    }

    @Test("Surrounding text forces the model even for short utterances")
    func forcesWithContext() {
        #expect(PromptBuilder.shouldUseModel(for: "bought milk", hasSurroundingText: true))
        #expect(PromptBuilder.shouldUseModel(for: "hi", hasSurroundingText: true))
        // Without surrounding text the length rule still applies.
        #expect(!PromptBuilder.shouldUseModel(for: "bought milk", hasSurroundingText: false))
    }
}

@Suite("Text repair")
struct TextRepairTests {

    @Test("Collapses a doubled 'the'")
    func doubledThe() {
        #expect(TextRepair.removeAccidentalDuplicates("this is the the answer") == "this is the answer")
    }

    @Test("Keeps first word's casing")
    func casing() {
        #expect(TextRepair.removeAccidentalDuplicates("The the cat") == "The cat")
    }

    @Test("Collapses triples")
    func triple() {
        #expect(TextRepair.removeAccidentalDuplicates("the the the end") == "the end")
    }

    @Test("Leaves grammatical doubling of unlisted words alone")
    func leavesValidDoubling() {
        // "that that" can be valid, so it's not in the safe list.
        #expect(TextRepair.removeAccidentalDuplicates("I know that that works") == "I know that that works")
    }

    @Test("Does not touch distinct adjacent words")
    func distinctWords() {
        #expect(TextRepair.removeAccidentalDuplicates("the cat sat") == "the cat sat")
    }
}

@Suite("Cursor merge join")
struct CursorMergeTests {

    @Test("Adds a single space joining a split sentence")
    func addsSpace() {
        // User released the key after "and", then dictated the rest.
        #expect(TextRepair.joinAtCursor("bought some milk", precedingText: "I went to the store and")
                == " bought some milk")
    }

    @Test("No leading space at the start of an empty field")
    func noSpaceAtStart() {
        #expect(TextRepair.joinAtCursor("Hello there", precedingText: nil) == "Hello there")
        #expect(TextRepair.joinAtCursor("Hello there", precedingText: "") == "Hello there")
    }

    @Test("No extra space when the field already ends with whitespace")
    func noDoubleSpace() {
        #expect(TextRepair.joinAtCursor("world", precedingText: "hello ") == "world")
        #expect(TextRepair.joinAtCursor("next line", precedingText: "prior\n") == "next line")
    }

    @Test("Normalizes a leading space the model added (idempotent)")
    func normalizesModelSpace() {
        #expect(TextRepair.joinAtCursor("  bought milk", precedingText: "I went and") == " bought milk")
        #expect(TextRepair.joinAtCursor("  bought milk", precedingText: "I went and ") == "bought milk")
    }

    @Test("Glues tight before closing punctuation")
    func gluesPunctuation() {
        #expect(TextRepair.joinAtCursor(", he said", precedingText: "Well") == ", he said")
        #expect(TextRepair.joinAtCursor("? really", precedingText: "you think so") == "? really")
    }

    @Test("Keeps newline starts without a leading space")
    func keepsNewline() {
        #expect(TextRepair.joinAtCursor("\nNew point", precedingText: "First point") == "\nNew point")
    }

    @Test("Appends a trailing space when the field is unreadable")
    func appendsTrailingSpace() {
        // Electron/web apps: no context, so separate dictations by a trailing space.
        #expect(TextRepair.appendSeparatorSpace("Hello there.") == "Hello there. ")
        #expect(TextRepair.appendSeparatorSpace("no period") == "no period ")
    }

    @Test("Does not double the trailing space or touch newlines/empty")
    func trailingSpaceIdempotent() {
        #expect(TextRepair.appendSeparatorSpace("already ") == "already ")
        #expect(TextRepair.appendSeparatorSpace("line\n") == "line\n")
        #expect(TextRepair.appendSeparatorSpace("") == "")
    }
}

@Suite("Local server response handling")
struct LocalServerParsingTests {

    @Test("Strips a balanced reasoning block")
    func stripsBalanced() {
        #expect(TextRepair.stripReasoningTags("<think>let me fix grammar</think>Hello there.") == "Hello there.")
    }

    @Test("Keeps the answer after a lone closing tag")
    func loneClose() {
        #expect(TextRepair.stripReasoningTags("planning...</think>The final text.") == "The final text.")
    }

    @Test("Drops an unterminated scratchpad")
    func loneOpen() {
        #expect(TextRepair.stripReasoningTags("Clean text.<think>oops truncated") == "Clean text.")
    }

    @Test("Leaves normal text untouched")
    func noTags() {
        #expect(TextRepair.stripReasoningTags("Just a normal sentence.") == "Just a normal sentence.")
    }

    @Test("Strips harmony/channel reasoning (heretic Gemma)")
    func channelFormat() {
        let raw = "<|channel>thought\nThinking Process:\n1. fix grammar\n2. keep swearing<channel|>He and I were gonna fix this shit, but we didn't have time."
        #expect(TextRepair.stripReasoningTags(raw) == "He and I were gonna fix this shit, but we didn't have time.")
    }

    @Test("Strips gpt-oss harmony channels and trailing tokens")
    func harmonyFinalChannel() {
        let raw = "<|channel|>analysis<|message|>let me think<|end|><|start|>assistant<|channel|>final<|message|>The final text.<|end|>"
        #expect(TextRepair.stripReasoningTags(raw) == "The final text.")
    }

    @Test("Normalizes OpenAI base URLs")
    func normalizesURL() {
        #expect(TextRepair.normalizedOpenAIBase("http://localhost:1234") == "http://localhost:1234/v1")
        #expect(TextRepair.normalizedOpenAIBase("http://localhost:1234/v1/") == "http://localhost:1234/v1")
        #expect(TextRepair.normalizedOpenAIBase("http://localhost:11434") == "http://localhost:11434/v1")
        #expect(TextRepair.normalizedOpenAIBase("not-a-url") == nil)
    }
}

@Suite("Mid-sentence continuation casing")
struct ContinuationCasingTests {

    @Test("Lowercases a mid-sentence continuation")
    func lowercasesMidSentence() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("Bought some milk", precedingText: "I went to the store and")
                == "bought some milk")
    }

    @Test("Keeps the capital after a finished sentence")
    func keepsAfterTerminator() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("Then we left.", precedingText: "We arrived.")
                == "Then we left.")
    }

    @Test("Keeps the capital on a fresh line")
    func keepsAfterNewline() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("Second item", precedingText: "First item\n")
                == "Second item")
    }

    @Test("Never lowercases 'I' or its contractions")
    func keepsI() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("I think so", precedingText: "and honestly")
                == "I think so")
        #expect(TextRepair.lowercaseContinuationIfMidSentence("I'm sure", precedingText: "and")
                == "I'm sure")
    }

    @Test("Keeps all-caps acronyms capitalized")
    func keepsAcronym() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("NASA confirmed it", precedingText: "according to")
                == "NASA confirmed it")
    }

    @Test("No preceding text leaves casing untouched")
    func noPreceding() {
        #expect(TextRepair.lowercaseContinuationIfMidSentence("Hello", precedingText: nil) == "Hello")
    }
}

@Suite("Prompt context merge")
struct PromptContextTests {

    @Test("Instructions fix grammar and duplicates")
    func instructionsCoverGrammar() {
        #expect(PromptBuilder.instructions.contains("subject-verb agreement"))
        #expect(PromptBuilder.instructions.contains("Duplicated words"))
    }

    /// Parakeet hands over near-uncased text, so casing is the formatter's job and
    /// the instruction has to be explicit about it — not a clause on a punctuation line.
    @Test("Instructions spell out capitalization")
    func instructionsCoverCapitalization() {
        #expect(PromptBuilder.instructions.contains("Capitalize the first word of every sentence"))
        #expect(PromptBuilder.instructions.contains("Never return all-lowercase text"))
    }

    /// A speaker who says "scratch that" has already told you what they want; leaving
    /// it in means they have to go delete it by hand, which is the thing dictation was
    /// supposed to save them. The model wouldn't do this on its own — the boundary
    /// against acting on transcript content reads as an argument against it — so the
    /// rule and its carve-out have to be stated together or the fix half-lands.
    @Test("Instructions handle retractions without loosening the never-act rail")
    func instructionsCoverRetractions() {
        #expect(PromptBuilder.instructions.contains("Retractions"))
        #expect(PromptBuilder.instructions.contains("scratch that"))
        #expect(PromptBuilder.instructions.contains("NEVER answer"))
        #expect(PromptBuilder.instructions.contains("edits to the words in front of you rather than tasks"))
    }

    /// With thinking disabled — which is how the Claude CLI formatter runs, because it
    /// takes the call from ~16s to ~1.5s — a transcript that reads as a command made
    /// the model refuse and explain itself, cleaned text and all. That preamble goes
    /// straight into the user's document. Naming refusal as the wrong answer is what
    /// fixed it, so the wording is pinned.
    @Test("Instructions forbid refusing outright, not just answering")
    func instructionsForbidRefusal() {
        #expect(PromptBuilder.instructions.contains("NEVER refuse"))
        #expect(PromptBuilder.instructions.contains("you are not its audience"))
        #expect(PromptBuilder.instructions.contains("is a WRONG answer even when it comes with the cleaned text attached"))
    }

    /// The merge block used to say "output ONLY the new words to append", which a
    /// non-reasoning pass reads as licence to trim: "This is a test of the dictation
    /// system" came back as "test of the dictation system", with unrelated text before
    /// the cursor. Losing the opening words of a dictation is invisible until you
    /// re-read what you wrote, so the block now leads with keeping every word and
    /// scopes deduplication to a literal repeat.
    @Test("The merge block insists on the whole dictation")
    func mergeBlockKeepsEveryWord() {
        let prompt = PromptBuilder.prompt(for: "this is a test",
                                          hints: FormattingHints(precedingText: "Earlier text."))
        #expect(prompt.contains("Your output is the dictation, WHOLE"))
        #expect(prompt.contains("Do NOT drop its opening words"))
        #expect(prompt.contains("CONTEXT ONLY"))
        // The narrow dedup carve-out has to stay narrow, and stay present.
        #expect(prompt.contains("literally re-say the words"))
        #expect(!prompt.contains("output ONLY the new words to append"))
    }

    @Test("Preceding text is injected for merge")
    func precedingInjected() {
        let prompt = PromptBuilder.prompt(for: "and then we left",
                                          hints: FormattingHints(precedingText: "We went to the store"))
        #expect(prompt.contains("the cursor sits right after this"))
        #expect(prompt.contains("We went to the store"))
    }

    @Test("No merge section when there's no preceding text")
    func noPrecedingNoSection() {
        let prompt = PromptBuilder.prompt(for: "hello there", hints: .none)
        #expect(!prompt.contains("before the cursor"))
    }
}

@Suite("Stats")
struct StatsTests {

    @Test("Word count ignores extra whitespace")
    func wordCount() {
        #expect(DictationStats.wordCount("  hello   world \n foo ") == 3)
        #expect(DictationStats.wordCount("") == 0)
    }

    @Test("WPM is words over minutes; zero duration is safe")
    func wpm() {
        #expect(DictationStats.wordsPerMinute(words: 120, duration: 60) == 120)
        #expect(DictationStats.wordsPerMinute(words: 10, duration: 0) == 0)
    }
}
