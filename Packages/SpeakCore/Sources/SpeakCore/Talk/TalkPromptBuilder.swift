import Foundation

/// Builds the system prompt and user turns for Talk mode. Pure and unit-tested,
/// for the same reason `PromptBuilder` is: the instruction string is stable enough
/// to act as a prompt-cache key, and its wording is the whole product.
public enum TalkPromptBuilder {
    /// Talk answers are read off a small floating panel while the user is mid-task,
    /// so brevity is the dominant constraint — this is the opposite of a chat UI.
    public static let instructions = """
        You are a voice assistant answering a spoken question. The user is in the \
        middle of doing something else and is reading your answer off a small \
        floating panel, so brevity is the point.

        Answering:
        - Lead with the answer. No preamble, no restating the question, no sign-off.
        - Two or three sentences by default. Go longer ONLY if the question plainly \
        needs it (a list of steps, several distinct items).
        - Plain prose. No markdown headings, no bold, no bullet points unless you are \
        genuinely enumerating things.
        - If you don't know, or the question is ambiguous, say so in one line rather \
        than guessing at length.

        The question arrived as a speech transcript, so it may contain recognition \
        errors, missing punctuation, or half-finished phrasing. Infer what was meant \
        and answer that. Never comment on the transcription quality, and never ask the \
        user to repeat themselves unless the question is genuinely unintelligible.
        """

    /// Extra guidance appended when a screenshot rides along.
    static let visionNote = """
        An image of the user's focused window is attached. They are most likely asking \
        about something visible in it, so read it before answering. If the question \
        turns out to be unrelated to the image, ignore the image entirely.
        """

    /// The full system prompt, including any context-dependent notes.
    public static func systemPrompt(for context: TalkContext) -> String {
        var parts = [instructions]
        if context.hasVision {
            parts.append(visionNote)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Assemble the user-visible turn text: the question, plus whatever ambient
    /// context we managed to capture. Selected text is quoted rather than inlined so
    /// the model can't confuse it with the question itself.
    public static func userTurn(question: String, context: TalkContext) -> String {
        var parts: [String] = []

        if let app = context.frontmostAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty {
            parts.append("(The user is currently in \(app).)")
        }

        if let selected = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            // Cap so a select-all can't blow the request size.
            let capped = String(selected.prefix(maxSelectedTextChars))
            parts.append("""
                The user has this text selected, and is probably asking about it:
                <<<\(capped)>>>
                """)
        }

        parts.append("Question: " + question.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.joined(separator: "\n\n")
    }

    /// Cap on quoted selection length. Generous — Flash-class context windows are
    /// large — but bounded so a runaway selection can't stall the request.
    public static let maxSelectedTextChars = 4000

    /// Build the thread to send: prior turns verbatim, with the newest question
    /// enriched by context. Only the latest turn carries context, since the earlier
    /// ones already had theirs when they were asked.
    public static func thread(priorTurns: [TalkTurn],
                              question: String,
                              context: TalkContext) -> [TalkTurn] {
        priorTurns + [TalkTurn(role: .user, text: userTurn(question: question, context: context))]
    }
}
