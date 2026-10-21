import Testing
import Foundation
@testable import SpeakCore

/// Answers are written to be read, not heard. These pin the removals that stop a
/// synthesiser from narrating punctuation or performing a shell command out loud.
@Suite("Speech text")
struct SpeechTextTests {

    @Test("Plain prose is left alone")
    func plainProse() {
        #expect(SpeechText.spoken(from: "The build succeeded.", limit: 600)
                == "The build succeeded.")
    }

    /// The worst case: left in, the voice spends thirty seconds reading a command.
    @Test("Fenced code is dropped whole")
    func fencedCode() {
        let answer = """
            Run this:

            ```bash
            rm -rf ./build && swift build --configuration release
            ```

            Then try again.
            """
        let spoken = SpeechText.spoken(from: answer, limit: 600)
        #expect(spoken?.contains("rm -rf") == false)
        #expect(spoken?.contains("Run this:") == true)
        #expect(spoken?.contains("Then try again.") == true)
    }

    /// A streamed answer cut off mid-block is exactly when this matters most.
    @Test("An unterminated fence is dropped too")
    func unterminatedFence() {
        let spoken = SpeechText.spoken(from: "Try:\n\n```swift\nlet x = 1\nlet y = 2",
                                       limit: 600)
        #expect(spoken == "Try:")
    }

    @Test("An answer that is only code says nothing at all")
    func onlyCode() {
        #expect(SpeechText.spoken(from: "```\nls -la\n```", limit: 600) == nil)
    }

    @Test("Markdown emphasis and headings lose their markers, not their words")
    func markers() {
        let spoken = SpeechText.spoken(from: "## Result\n\nThe **important** part is *here*.",
                                       limit: 600)
        #expect(spoken == "Result\n\nThe important part is here.")
    }

    /// The word inside the backticks usually *is* the answer, so only the ticks go.
    @Test("Inline code keeps its contents")
    func inlineCode() {
        #expect(SpeechText.spoken(from: "Use `GRDB` for that.", limit: 600)
                == "Use GRDB for that.")
    }

    @Test("A link is read as its label, never its URL")
    func links() {
        #expect(SpeechText.spoken(from: "See [the migration guide](https://example.com/a/b?c=1).",
                                  limit: 600)
                == "See the migration guide.")
    }

    @Test("Bullets become clauses without their glyphs")
    func bullets() {
        let spoken = SpeechText.spoken(from: "- first thing\n- second thing", limit: 600)
        #expect(spoken == "first thing\nsecond thing")
    }

    @Test("Table rows and rules have no spoken form")
    func tables() {
        let spoken = SpeechText.spoken(from: "Here:\n\n| a | b |\n| - | - |\n\n---\n\nDone.",
                                       limit: 600)
        #expect(spoken == "Here:\n\nDone.")
    }

    @Test("A lone asterisk in prose survives")
    func loneAsterisk() {
        #expect(SpeechText.spoken(from: "The 2 * 3 case.", limit: 600) == "The 2 * 3 case.")
    }

    // MARK: - Clamping

    /// A clipped answer should end like an answer, not stop dead mid-word.
    @Test("Clamping cuts at a sentence boundary")
    func clampsAtSentence() {
        let text = "One sentence here. Two sentences here. Three sentences here."
        let spoken = SpeechText.spoken(from: text, limit: 45)
        #expect(spoken == "One sentence here. Two sentences here.")
    }

    /// Ends with a full stop, never an ellipsis — see `ellipsisFree`.
    @Test("With no sentence break it cuts at a whole word")
    func clampsAtWord() {
        let text = String(repeating: "alpha ", count: 40)
        let spoken = SpeechText.spoken(from: text, limit: 20)
        #expect(spoken?.hasSuffix(".") == true)
        #expect(spoken?.contains("…") == false)
        #expect(spoken?.contains("alph ") == false)
    }

    /// Qwen3-TTS vocalises an ellipsis as an audible moan rather than reading it as a
    /// pause, so none may reach it — in either spelling, from the model's prose or
    /// from our own truncation marker.
    @Test("Ellipses never reach the synthesiser", arguments: [
        "Well… that is unexpected.",
        "Well... that is unexpected.",
        "Well.... that is unexpected.",
    ])
    func ellipsesAreRemoved(input: String) {
        let spoken = SpeechText.spoken(from: input, limit: 600)
        #expect(spoken?.contains("…") == false)
        #expect(spoken?.contains("..") == false)
        #expect(spoken?.contains("Well. that is unexpected.") == true)
    }

    @Test("A streamed fragment ending in an ellipsis is cleaned too")
    func ellipsisInStream() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        let out = splitter.accept("Hold on, let me check the second one…\n")
        #expect(out.count == 1)
        #expect(out[0].contains("…") == false)
        #expect(out[0].hasSuffix("."))
    }

    @Test("Short answers are never clamped")
    func shortUntouched() {
        #expect(SpeechText.spoken(from: "Done.", limit: 600) == "Done.")
    }

    @Test("Whitespace-only input says nothing")
    func whitespaceOnly() {
        #expect(SpeechText.spoken(from: "   \n\n  ", limit: 600) == nil)
    }
}

@Suite("Speech settings")
struct SpeechSettingsTests {

    /// Off unless asked for. This app is used in meetings and next to sleeping people;
    /// a default that makes the machine talk would be the wrong kind of surprise.
    @Test("Speech is off by default")
    func offByDefault() {
        #expect(AppSettings.default.speechEnabled == false)
    }

    @Test("Settings resolve into the synthesiser's config")
    func resolvesConfig() {
        var settings = AppSettings.default
        settings.speechEnabled = true
        settings.speechEngine = .qwen3
        settings.speechVoice = .serena
        settings.speechMaxCharacters = 900

        let config = settings.speechConfig
        #expect(config.enabled)
        #expect(config.engine == .qwen3)
        #expect(config.voice == .serena)
        #expect(config.maxCharacters == 900)
    }

    /// The same lenient-decode contract every other setting has: adding these must not
    /// wipe a saved preference, and neither must removing an engine case later.
    @Test("Speech settings round-trip, and missing keys fall back")
    func roundTrips() throws {
        var settings = AppSettings.default
        settings.speechEnabled = true
        settings.speechVoice = .dylan
        settings.speechPythonPath = "/opt/venv/bin/python"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.speechEnabled)
        #expect(decoded.speechVoice == .dylan)
        #expect(decoded.speechPythonPath == "/opt/venv/bin/python")

        // A payload written before these settings existed.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"playSounds":false}"#.utf8))
        #expect(older.speechEnabled == AppSettings.default.speechEnabled)
        #expect(older.speechVoice == AppSettings.default.speechVoice)
        #expect(older.playSounds == false)
    }

    /// An unknown engine must not fail the whole decode and reset every unrelated
    /// setting — the reason every enum field here uses `try?`.
    @Test("An unrecognised engine falls back without taking the rest with it")
    func unknownEngine() throws {
        let json = Data(#"{"speechEngine":"piper","playSounds":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.speechEngine == AppSettings.default.speechEngine)
        #expect(decoded.playSounds == false)
    }

    /// The raw values are what the model matches on, exactly.
    @Test("Voice raw values are the model's own speaker names")
    func voiceRawValues() {
        #expect(SpeechVoice.uncleFu.rawValue == "uncle_fu")
        #expect(SpeechVoice.onoAnna.rawValue == "ono_anna")
        #expect(SpeechVoice.allCases.allSatisfy { $0.rawValue == $0.rawValue.lowercased() })
    }
}

/// Streaming exists so the voice starts on the first sentence instead of the last.
@Suite("Sentence splitting")
struct SentenceSplitterTests {

    @Test("Emits a sentence as soon as it is complete")
    func emitsOnCompletion() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        #expect(splitter.accept("The build succeeded and ").isEmpty)
        let out = splitter.accept("every test passed. Now for ")
        #expect(out == ["The build succeeded and every test passed."])
    }

    /// `3.5` and `e.g.` are not sentence ends; the trailing space is what tells them
    /// apart from one.
    @Test("A period inside a number or abbreviation is not an ending")
    func decimalsAreNotEndings() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        #expect(splitter.accept("Gemini 3.5 costs less than ").isEmpty)
    }

    /// Splitting inside a fence would speak the first line of a code block before the
    /// closing fence arrived to say it was code.
    @Test("Nothing is emitted while a code fence is open")
    func holdsOpenFence() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        #expect(splitter.accept("Run this to fix the build issue:\n").isEmpty == false)
        #expect(splitter.accept("```bash\nrm -rf build. ls -la. ").isEmpty)
        let out = splitter.accept("```\nThat should do it, one way or another.\n")
        #expect(out.contains { $0.contains("That should do it") })
        #expect(out.allSatisfy { !$0.contains("rm -rf") })
    }

    /// A one-word fragment synthesised alone comes out clipped, with an audible gap
    /// before the next one.
    @Test("A very short fragment is held back and merged")
    func mergesShortFragments() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 24, chunk: 24)
        #expect(splitter.accept("Yes. ").isEmpty)
        let out = splitter.accept("That is the right way to do it here.\n")
        #expect(out.count == 1)
        #expect(out[0].contains("Yes."))
        #expect(out[0].contains("right way"))
    }

    @Test("finish flushes a trailing fragment with no punctuation")
    func finishFlushes() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        _ = splitter.accept("A complete sentence lands first. ")
        _ = splitter.accept("then a trailing thought")
        #expect(splitter.finish() == "then a trailing thought")
    }

    @Test("Nothing is left to flush once everything was emitted")
    func finishEmpty() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        _ = splitter.accept("This whole thing is one clean sentence.\n")
        #expect(splitter.finish() == nil)
    }

    /// The limit is a total across the stream, not per sentence — otherwise a long
    /// answer speaks forever one clause at a time.
    @Test("The limit applies across the whole stream")
    func limitIsCumulative() {
        var splitter = SpeechText.SentenceSplitter(limit: 60, firstChunk: 1, chunk: 1)
        var spoken = ""
        for _ in 0..<10 {
            for sentence in splitter.accept("Another sentence arrives here now. ") {
                spoken += sentence
            }
        }
        #expect(splitter.isFull)
        #expect(spoken.count <= 70)
    }

    /// Sentence-at-a-time synthesis is what makes Qwen sound flat: nothing carries
    /// across a boundary the model never saw. So only the opening chunk is small.
    @Test("The first chunk is small so speech starts quickly")
    func firstChunkIsSmall() {
        var splitter = SpeechText.SentenceSplitter(limit: 4000)
        #expect(splitter.accept("Right, here is what I found. ").isEmpty)

        let first = splitter.accept("The build succeeded and every test passed on the first run. ")
        #expect(first.count == 1)
        #expect(first[0].contains("Right, here is what I found."))
        #expect(first[0].contains("The build succeeded"))
    }

    /// After that the threshold rises, so the model gets whole phrases to shape a
    /// reading across rather than one isolated sentence at a time.
    @Test("Later sentences are gathered into one chunk")
    func gathersLaterSentences() {
        var splitter = SpeechText.SentenceSplitter(limit: 4000)
        _ = splitter.accept("Right, here is what I found. The build succeeded and every test passed. ")

        // None of these reaches the chunk size alone, so they accumulate.
        #expect(splitter.accept("Nothing needed a retry. ").isEmpty)
        #expect(splitter.accept("The suite finished quickly. ").isEmpty)
        #expect(splitter.accept("That is faster than the previous run was. ").isEmpty)

        let full = splitter.accept("Coverage is unchanged, and the only edit was to the speech layer itself, which is exactly where the pacing problem lived. ")
        #expect(full.count == 1)
        #expect(full[0].contains("Nothing needed a retry."))
        #expect(full[0].contains("Coverage is unchanged"))
    }

    @Test("Markup is stripped from each fragment, not just the whole")
    func stripsPerFragment() {
        var splitter = SpeechText.SentenceSplitter(limit: 600, firstChunk: 1, chunk: 1)
        let out = splitter.accept("Use the **fastest** available `GRDB` query here.\n")
        #expect(out == ["Use the fastest available GRDB query here."])
    }
}
