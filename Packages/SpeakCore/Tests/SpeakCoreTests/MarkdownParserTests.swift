import Testing
@testable import SpeakCore

@Suite("Markdown blocks")
struct MarkdownParserTests {

    @Test("Plain prose is one paragraph")
    func prose() {
        #expect(MarkdownParser.blocks(from: "Just a sentence.")
            == [.paragraph(text: "Just a sentence.")])
    }

    @Test("Soft-wrapped lines join into one paragraph")
    func softWrap() {
        #expect(MarkdownParser.blocks(from: "one\ntwo")
            == [.paragraph(text: "one two")])
    }

    @Test("A blank line splits paragraphs")
    func paragraphSplit() {
        #expect(MarkdownParser.blocks(from: "one\n\ntwo")
            == [.paragraph(text: "one"), .paragraph(text: "two")])
    }

    @Test("Headings carry their level", arguments: [
        ("# Title", 1), ("## Title", 2), ("###### Title", 6),
    ])
    func headings(source: String, level: Int) {
        #expect(MarkdownParser.blocks(from: source) == [.heading(level: level, text: "Title")])
    }

    @Test("A hash without a space is prose, not a heading")
    func hashtag() {
        #expect(MarkdownParser.blocks(from: "#swift is fine")
            == [.paragraph(text: "#swift is fine")])
        // Seven hashes isn't a heading level in any dialect.
        #expect(MarkdownParser.blocks(from: "####### deep")
            == [.paragraph(text: "####### deep")])
    }

    @Test("Bullets", arguments: ["- item", "* item", "+ item"])
    func bullets(source: String) {
        #expect(MarkdownParser.blocks(from: source) == [.bullet(text: "item", depth: 0)])
    }

    @Test("Indentation becomes depth, capped")
    func nesting() {
        let blocks = MarkdownParser.blocks(from: "- a\n  - b\n    - c\n            - d")
        #expect(blocks == [
            .bullet(text: "a", depth: 0),
            .bullet(text: "b", depth: 1),
            .bullet(text: "c", depth: 2),
            .bullet(text: "d", depth: 3),
        ])
    }

    @Test("Ordered items keep their own numbers")
    func ordered() {
        #expect(MarkdownParser.blocks(from: "1. first\n2) second") == [
            .numbered(number: 1, text: "first", depth: 0),
            .numbered(number: 2, text: "second", depth: 0),
        ])
    }

    @Test("A year at the start of a sentence is not a list")
    func notOrdered() {
        #expect(MarkdownParser.blocks(from: "1984 was a year.")
            == [.paragraph(text: "1984 was a year.")])
        #expect(MarkdownParser.blocks(from: "3.14 is pi.")
            == [.paragraph(text: "3.14 is pi.")])
    }

    @Test("Fenced code keeps its language and its line breaks")
    func fencedCode() {
        let source = "```swift\nlet a = 1\n\nlet b = 2\n```"
        #expect(MarkdownParser.blocks(from: source)
            == [.code(language: "swift", text: "let a = 1\n\nlet b = 2")])
    }

    @Test("Code contents are never reinterpreted as markdown")
    func codeIsOpaque() {
        // A shell comment inside a fence must not become a heading.
        #expect(MarkdownParser.blocks(from: "```\n# not a heading\n- not a bullet\n```")
            == [.code(language: nil, text: "# not a heading\n- not a bullet")])
    }

    @Test("An unterminated fence renders as code rather than swallowing the answer")
    func streamingFence() {
        // The panel re-parses on every streamed chunk, so this is the normal
        // mid-stream state, not malformed input.
        #expect(MarkdownParser.blocks(from: "```swift\nlet a =")
            == [.code(language: "swift", text: "let a =")])
    }

    @Test("Quotes merge into one block")
    func quotes() {
        #expect(MarkdownParser.blocks(from: "> one\n> two")
            == [.quote(text: "one two")])
    }

    @Test("Thematic breaks", arguments: ["---", "***", "___", "- - -"])
    func rules(source: String) {
        #expect(MarkdownParser.blocks(from: source) == [.rule])
    }

    @Test("A rule wins over the bullet that shares its marker")
    func ruleBeatsBullet() {
        #expect(MarkdownParser.blocks(from: "- item\n---\n- item") == [
            .bullet(text: "item", depth: 0),
            .rule,
            .bullet(text: "item", depth: 0),
        ])
    }

    @Test("Inline syntax is left intact for the view to render")
    func inlinePassthrough() {
        // The parser must not strip `**` — `AttributedString(markdown:)` downstream
        // needs the markers to produce bold.
        #expect(MarkdownParser.blocks(from: "- **bold** and `code`")
            == [.bullet(text: "**bold** and `code`", depth: 0)])
    }

    @Test("Empty and whitespace-only input produce nothing")
    func empty() {
        #expect(MarkdownParser.blocks(from: "").isEmpty)
        #expect(MarkdownParser.blocks(from: "\n \n\t\n").isEmpty)
    }

    @Test("No text is ever dropped")
    func lossless() {
        // The guarantee that matters most: whatever the model says reaches the
        // user, even if this parser doesn't understand the construct it's in.
        let source = """
            # Heading
            Some prose with **bold**.

            - one
            - two

            | a | b |
            | - | - |

            > quoted

            ```sh
            echo hi
            ```
            Trailing line.
            """
        let words = ["Heading", "prose", "one", "two", "quoted", "echo", "Trailing"]
        let rendered = MarkdownParser.blocks(from: source).map(payload).joined(separator: " ")
        for word in words {
            #expect(rendered.contains(word), "lost \(word)")
        }
    }

    private func payload(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(_, text): text
        case let .paragraph(text): text
        case let .bullet(text, _): text
        case let .numbered(_, text, _): text
        case let .code(_, text): text
        case let .quote(text): text
        case .rule: ""
        }
    }
}

@Suite("A real answer")
struct MarkdownAnswerTests {

    @Test("A typical model reply parses into the blocks it looks like")
    func modelAnswer() {
        let answer = """
            To rename a file in Swift:

            1. Use `FileManager`.
            2. Handle the throw.

            ```swift
            try FileManager.default.moveItem(at: old, to: new)
            ```

            **Note:** this fails if the destination exists.
            """
        #expect(MarkdownParser.blocks(from: answer) == [
            .paragraph(text: "To rename a file in Swift:"),
            .numbered(number: 1, text: "Use `FileManager`.", depth: 0),
            .numbered(number: 2, text: "Handle the throw.", depth: 0),
            .code(language: "swift",
                  text: "try FileManager.default.moveItem(at: old, to: new)"),
            .paragraph(text: "**Note:** this fails if the destination exists."),
        ])
    }
}
