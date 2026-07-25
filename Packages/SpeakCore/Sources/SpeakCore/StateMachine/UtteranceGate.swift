import Foundation

/// Tells a real instruction from what a speech model emits when it was handed
/// silence.
///
/// Parakeet does not return an empty string for a second of room tone — it returns
/// its most likely short utterance, which is why "you", "Thank you." and "Bye."
/// come out of a dictation where nobody said anything. The reducer's
/// `trimmed.isEmpty` check never sees those, so before this gate existed they went
/// through as the task, and the agent would take the screenshot and start clicking
/// on whatever it could make of "Thank you".
///
/// **This gate applies to Talk and the agent, and deliberately not to dictation.**
/// Dictating "Thank you." into a reply is a completely ordinary thing to do, and
/// refusing to type it would be a worse bug than the one this fixes. The asymmetry
/// is the point: dictation puts characters where the caret already is and the user
/// can see and undo them, whereas the agent acts on the screen. A junk transcript
/// costs a keystroke in one mode and an unrecoverable click in the other.
public enum UtteranceGate {

    /// Whole utterances that are never a question or a task.
    ///
    /// Matched against the *entire* normalised transcript, never as a substring —
    /// "thanks, now close this tab" is a real instruction and must survive. Keep the
    /// list to things that carry no request at all: anything a user might plausibly
    /// mean on its own belongs out of here, because a false reject reads to them as
    /// the app not listening.
    public static let silenceArtifacts: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "bye", "goodbye", "bye bye",
        "so", "okay", "ok", "yeah", "yep", "yes", "no", "right",
        "uh", "um", "eh", "ah", "oh", "hmm", "mm", "mhm", "huh",
    ]

    /// Whether `text` is worth acting on.
    ///
    /// Rejects a transcript with no letters or digits at all (".", "…", "?") and one
    /// that is nothing but a known artifact. Everything else passes: this is a floor
    /// against silence, not a judgement about whether the request makes sense — that
    /// is the model's job, and the prompt already tells it to call `done` and explain
    /// rather than guess.
    public static func isSubstantive(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        return !silenceArtifacts.contains(normalized)
    }

    /// Lowercased, punctuation dropped, whitespace collapsed — so "Thank you!",
    /// "thank  you" and "Thank you." all reduce to the same key.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
