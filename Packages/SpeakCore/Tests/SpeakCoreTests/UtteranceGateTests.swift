import Testing
import Foundation
@testable import SpeakCore

// MARK: - The predicate

@Suite("Silence artifacts")
struct UtteranceGateTests {

    @Test("Punctuation-only transcripts carry nothing to act on", arguments: [
        ".", "…", "?", "  -  ", "!!!",
    ])
    func punctuationOnly(text: String) {
        #expect(!UtteranceGate.isSubstantive(text))
    }

    /// The exact strings Parakeet returns for a second of room tone.
    @Test("Known artifacts are rejected however they're punctuated", arguments: [
        "you", "You.", "Thank you.", "thank you", "THANK YOU!", " Thanks. ",
        "Thanks for watching!", "Bye.", "so", "Okay.", "Uh…", "Hmm.",
    ])
    func artifacts(text: String) {
        #expect(!UtteranceGate.isSubstantive(text))
    }

    /// The gate matches whole utterances only. A request that merely *starts* with a
    /// pleasantry is still a request, and swallowing it would be the worse failure.
    @Test("An artifact inside a real request doesn't reject it", arguments: [
        "thanks, now close this tab",
        "okay open my calendar",
        "so what does this error mean",
        "you should look at the second column",
    ])
    func substringsSurvive(text: String) {
        #expect(UtteranceGate.isSubstantive(text))
    }

    /// Short commands are the normal way to drive the agent; a word-count floor would
    /// have been the obvious gate and would have broken every one of these.
    @Test("Short real commands pass", arguments: [
        "scroll down", "click send", "close this", "open Safari", "undo that",
    ])
    func shortCommandsPass(text: String) {
        #expect(UtteranceGate.isSubstantive(text))
    }

    @Test("Normalisation folds case, punctuation and repeated spaces")
    func normalisation() {
        #expect(UtteranceGate.normalize("  Thank   you!! ") == "thank you")
        #expect(UtteranceGate.normalize("GPT-4") == "gpt 4")
        #expect(UtteranceGate.normalize("...") == "")
    }
}

// MARK: - Wiring into the reducer

@Suite("Silence never reaches a model with tools")
struct SilenceGateReducerTests {

    private func machine(mode engage: DictationEvent?) -> DictationStateMachine {
        var m = DictationStateMachine()
        m.handle(.optionDown); m.handle(.minHoldElapsed)
        if let engage { m.handle(engage) }
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        return m
    }

    @Test("An artifact transcript never asks Talk a question")
    func talkRefusesArtifact() {
        var m = machine(mode: .talkModifierEngaged)
        let effects = m.handle(.transcriptReady("you"))
        #expect(effects == [.scheduleNoticeDismiss])
        #expect(m.state == .notice(.noSpeech))
        #expect(!m.hasAnswer)
    }

    /// The asymmetry is deliberate: "Thank you." is a perfectly ordinary thing to
    /// dictate into a reply, and refusing to type it would be a worse bug than the
    /// one the gate fixes. If this test ever starts failing, the gate has been
    /// applied too widely.
    @Test("Dictation still types an artifact-shaped utterance")
    func dictationIsExempt() {
        var m = machine(mode: nil)
        let effects = m.handle(.transcriptReady("Thank you."))
        #expect(effects.contains(.format("Thank you.")))
        #expect(m.state == .processing(.formatting))
    }

    /// An artifact arriving as a follow-up must abandon only that question — the
    /// answer the user is still reading stays up, the same as any other no-speech.
    @Test("An artifact follow-up leaves the existing answer alone")
    func followUpKeepsAnswer() {
        var m = machine(mode: .talkModifierEngaged)
        m.handle(.transcriptReady("what is a struct"))
        m.handle(.answerReady)

        m.handle(.optionDown); m.handle(.minHoldElapsed)
        m.handle(.talkModifierEngaged)
        m.handle(.optionUp)
        m.handle(.captureFinished(hasSpeech: true))
        m.handle(.transcriptReady("Bye."))

        #expect(m.hasAnswer)
        #expect(m.state == .answerPresented)
    }
}
