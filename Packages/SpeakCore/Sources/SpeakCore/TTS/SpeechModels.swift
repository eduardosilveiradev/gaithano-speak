import Foundation

/// Which synthesiser speaks an answer aloud.
public enum SpeechEngineID: String, Codable, Sendable, CaseIterable {
    /// `AVSpeechSynthesizer` — instant, offline, and always available.
    case system
    /// Qwen3-TTS through a resident `mlx-audio` sidecar. Far better prosody, at the
    /// cost of a 4 GB model held in memory and a Python interpreter to run it.
    case qwen3

    public var displayName: String {
        switch self {
        case .system: return "macOS (built-in)"
        case .qwen3: return "Qwen3-TTS (local, MLX)"
        }
    }

    /// Whether picking this engine requires anything the app can't provide itself.
    public var needsExternalSetup: Bool { self == .qwen3 }
}

/// The Qwen3-TTS CustomVoice speakers.
///
/// The raw values are lowercase because the model matches on them exactly — anything
/// else fails opaquely somewhere deep inside generation rather than at the call.
public enum SpeechVoice: String, Codable, Sendable, CaseIterable {
    case serena, vivian, uncleFu = "uncle_fu", ryan, aiden
    case onoAnna = "ono_anna", sohee, eric, dylan

    public var displayName: String {
        switch self {
        case .serena: return "Serena"
        case .vivian: return "Vivian"
        case .uncleFu: return "Uncle Fu"
        case .ryan: return "Ryan"
        case .aiden: return "Aiden"
        case .onoAnna: return "Ono Anna"
        case .sohee: return "Sohee"
        case .eric: return "Eric"
        case .dylan: return "Dylan"
        }
    }
}

/// Everything the speech layer needs, resolved from `AppSettings` at call time.
public struct SpeechConfig: Sendable, Equatable {
    public var enabled: Bool
    public var engine: SpeechEngineID
    public var voice: SpeechVoice
    /// Interpreter with `mlx-audio` importable. Blank means "go and look" — see
    /// `SpeechConfig.candidateInterpreters`.
    public var pythonPath: String
    /// Words per minute for `.system`. Ignored by Qwen, which paces itself.
    public var rate: Double
    /// Refuse to speak past this many characters. A short reply is a sentence; a
    /// Talk answer can be six paragraphs, and Qwen synthesises at roughly 1× realtime,
    /// so a long answer would leave the machine talking for a minute with no way to
    /// skip ahead but Esc.
    public var maxCharacters: Int

    public init(enabled: Bool = false,
                engine: SpeechEngineID = .qwen3,
                voice: SpeechVoice = .ryan,
                pythonPath: String = "",
                rate: Double = 175,
                maxCharacters: Int = 600) {
        self.enabled = enabled
        self.engine = engine
        self.voice = voice
        self.pythonPath = pythonPath
        self.rate = rate
        self.maxCharacters = maxCharacters
    }

    /// Where to look for an interpreter that can import `mlx_audio`, in order.
    ///
    /// The venv belonging to the sibling project this model was first set up for comes
    /// first: it is the one that is known to work, and asking a user to rebuild a 4 GB
    /// environment they already have would be the wrong kind of purity. Everything
    /// after it is a normal place to have put one. A `pythonPath` in Settings skips the
    /// search entirely.
    public static func candidateInterpreters(home: String) -> [String] {
        [
            "\(home)/Documents/Projects/explainer-studio/.venv-tts/bin/python",
            "\(home)/.venvs/tts/bin/python",
            "\(home)/.venv-tts/bin/python",
            "/opt/homebrew/bin/python3",
        ]
    }
}

/// Preparing model output to be read out loud.
///
/// Answers are written to be *seen*: they carry fenced code, bullet glyphs, link
/// syntax, and inline backticks, none of which have a spoken form. Left in, a synthesis
/// model does one of two things with them, and both are bad — it reads the punctuation
/// out ("star star note star star"), or it treats the block as text to perform and
/// spends thirty seconds narrating a shell command.
public enum SpeechText {

    /// Strip what shouldn't be spoken and clamp the rest to a sane length.
    ///
    /// Returns nil when there is nothing left worth saying, so callers can treat "an
    /// answer that was entirely a code block" as silence rather than speaking a stray
    /// bracket.
    public static func spoken(from text: String, limit: Int) -> String? {
        var result = ellipsisFree(text)

        // Fenced code first, whole. A block is the one thing here that is never worth
        // reading aloud even in summary, and removing it before anything else stops its
        // contents from being mistaken for prose by the rules below.
        result = removeFencedCode(from: result)

        var lines: [String] = []
        for rawLine in result.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // Headings: the text is worth speaking, the hashes are not.
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#,
                                             with: "", options: .regularExpression)
            // Bullets and numbered items become clauses. The glyph itself is silent, but
            // dropping it entirely runs two list items into one sentence, so it leaves a
            // pause behind.
            line = line.replacingOccurrences(of: #"^\s*[-*+•]\s+"#,
                                             with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#,
                                             with: "", options: .regularExpression)
            // A table row or a horizontal rule has no spoken form at all.
            if line.range(of: #"^\s*\|.*\|\s*$"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            lines.append(line)
        }
        result = lines.joined(separator: "\n")

        // `inline code` → its contents. The word usually is the answer ("use GRDB"), so
        // dropping it would gut the sentence; only the backticks go.
        result = result.replacingOccurrences(of: "`", with: "")
        // [label](url) → label. The URL is unspeakable and the label is the point.
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#,
                                             with: "$1", options: .regularExpression)
        // Bold/italic markers, but only in pairs, so a lone asterisk in prose survives.
        result = result.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#,
                                             with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?!\w)"#,
                                             with: "$1", options: .regularExpression)

        // Collapse the blank lines the removals left behind.
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n",
                                             options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return nil }
        return clamp(result, to: limit)
    }

    /// Replace every ellipsis with a full stop.
    ///
    /// Qwen3-TTS **vocalises** an ellipsis — it comes out as an audible moan rather
    /// than the pause a reader would infer. The finding is not ours: the sibling
    /// `explainer-studio/pipeline/tts_qwen.py` hit it joining captions and left a note
    /// saying to use a sentence break instead, which is exactly the substitution here.
    /// A full stop is a pause the model already reads correctly.
    ///
    /// Both spellings, because a model writes either: the single `…` character and
    /// three periods. Longer runs of dots collapse too, so `....` doesn't become two
    /// sentence ends.
    static func ellipsisFree(_ text: String) -> String {
        text
            .replacingOccurrences(of: "…", with: ".")
            .replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
    }

    /// Cut at a sentence boundary rather than mid-word, so a clipped answer ends like
    /// an answer instead of stopping dead.
    static func clamp(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let head = String(text.prefix(limit))
        // Look for the last sentence end in the back half, so a text with no punctuation
        // at all doesn't get cut to almost nothing.
        let searchFloor = head.index(head.startIndex, offsetBy: limit / 2)
        if let end = head.range(of: #"[.!?](?=\s|$)"#,
                                options: [.regularExpression, .backwards],
                                range: searchFloor..<head.endIndex) {
            return String(head[head.startIndex..<end.upperBound])
        }
        // No sentence break to use — fall back to the last whole word, ended with a
        // full stop. This used to append "…", which Qwen vocalises as a moan — and it
        // sat at the end of every clipped fragment, so it was the loudest instance of
        // the bug rather than an edge case.
        if let space = head.lastIndex(of: " ") {
            return String(head[head.startIndex..<space]) + "."
        }
        return head + "."
    }

    /// Cuts a growing stream into speakable sentences.
    ///
    /// Synthesis is roughly 1× realtime, so waiting for a complete answer means the
    /// voice starts only after the whole thing has arrived and then talks for as long
    /// again. Feeding it a sentence at a time overlaps the two: by the time the first
    /// sentence has been spoken the second is already generated, and the delay the user
    /// hears is the length of one sentence rather than of the answer.
    ///
    /// Stateful because a stream arrives in fragments that mean nothing alone — a delta
    /// can end mid-word, mid-sentence, or mid-code-fence.
    public struct SentenceSplitter: Sendable {
        /// Everything received and not yet emitted.
        private var buffer = ""
        /// Emitted so far, to keep the total under the caller's limit.
        private var spokenCount = 0
        private let limit: Int
        /// How much text to gather before the *first* chunk, and before every one
        /// after it.
        ///
        /// Qwen synthesises each call cold, so prosody does not carry across a chunk
        /// boundary — sentence-at-a-time streaming makes every sentence its own flat,
        /// unconnected reading, which is what "the pacing is bad" sounds like. The
        /// sibling `explainer-studio/pipeline/tts_qwen.py` reached the same conclusion
        /// from the other direction and batches captions rather than synthesising each
        /// one.
        ///
        /// So the first chunk is deliberately small — it decides how long the user
        /// waits before hearing anything — and later chunks are several sentences, where
        /// the model can shape a phrase across a full stop. Generation runs at about 1×
        /// realtime, so playing one chunk covers generating the next at any of these
        /// sizes; the size trades the opening delay against how natural the reading is,
        /// not against keeping up.
        private let firstChunk: Int
        private let chunk: Int
        /// Chunks emitted so far, which selects the threshold above.
        private var emitted = 0

        public init(limit: Int, firstChunk: Int = 50, chunk: Int = 200) {
            self.limit = limit
            self.firstChunk = firstChunk
            self.chunk = chunk
        }

        /// The size the buffer must reach before a sentence boundary is worth cutting on.
        private var threshold: Int { emitted == 0 ? firstChunk : chunk }

        /// Add a delta, returning any sentences that are now complete.
        public mutating func accept(_ delta: String) -> [String] {
            buffer += delta
            var out: [String] = []
            while let sentence = takeSentence() {
                if let ready = prepare(sentence) { out.append(ready) }
                if spokenCount >= limit { break }
            }
            return out
        }

        /// Flush whatever is left when the stream ends.
        public mutating func finish() -> String? {
            let rest = buffer
            buffer = ""
            return prepare(rest)
        }

        /// Whether the limit has been reached and further text should be dropped.
        public var isFull: Bool { spokenCount >= limit }

        /// Strip the markup and account for the length. Returns nil for a fragment that
        /// is entirely unspeakable — a lone code fence, a table row — so the caller
        /// stays silent rather than voicing a stray bracket.
        private mutating func prepare(_ raw: String) -> String? {
            guard spokenCount < limit else { return nil }
            guard let cleaned = SpeechText.spoken(from: raw, limit: limit - spokenCount) else {
                return nil
            }
            spokenCount += cleaned.count
            return cleaned
        }

        /// Pull one complete sentence off the front of the buffer.
        ///
        /// A sentence ends at `.`, `!`, or `?` followed by whitespace — the trailing
        /// space is what distinguishes an ending from `3.5`, `e.g.`, or a file
        /// extension. A newline ends one too, since a list item or a heading is a unit
        /// to speak even without punctuation.
        ///
        /// Fenced code is removed from the buffer *whole* before any of this, and
        /// scanning stops at an unterminated fence. Splitting a fence across two
        /// fragments was the bug this shape exists to prevent: the closing ``` ended up
        /// at the head of the next fragment, where it reads as an *opening* one and
        /// silences the rest of the answer.
        private mutating func takeSentence() -> String? {
            removeCompleteFences()
            // An open fence means the block is still arriving; only the text before it
            // is safe to speak.
            let scanEnd = buffer.range(of: "```")?.lowerBound ?? buffer.endIndex

            var index = buffer.startIndex
            while index < scanEnd {
                let character = buffer[index]
                let next = buffer.index(after: index)
                let isBreak: Bool
                if character == "\n" {
                    isBreak = true
                } else if character == "." || character == "!" || character == "?" {
                    isBreak = next == buffer.endIndex ? false : buffer[next].isWhitespace
                } else {
                    isBreak = false
                }
                if isBreak {
                    let candidate = String(buffer[buffer.startIndex..<next])
                    // Keep gathering until the chunk is worth synthesising, so the
                    // model sees whole phrases rather than isolated sentences.
                    if candidate.trimmingCharacters(in: .whitespacesAndNewlines).count < threshold,
                       next < scanEnd {
                        index = next
                        continue
                    }
                    buffer = String(buffer[next...])
                    emitted += 1
                    return candidate
                }
                index = next
            }
            return nil
        }

        /// Delete every ```…``` block that has fully arrived, leaving any unterminated
        /// one in place for a later delta to close.
        private mutating func removeCompleteFences() {
            while let open = buffer.range(of: "```"),
                  let close = buffer.range(of: "```", range: open.upperBound..<buffer.endIndex) {
                buffer.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
    }

    /// Remove ``` fenced blocks, including an unterminated one at the end — a streamed
    /// answer that was cut off mid-block is exactly when this matters most.
    static func removeFencedCode(from text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { out.append(String(line)) }
        }
        return out.joined(separator: "\n")
    }
}
