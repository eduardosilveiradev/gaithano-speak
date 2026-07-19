import AppKit
import SpeakCore

/// Chooses an insertion strategy: keystrokes for short strings (no clipboard
/// clobber), pasteboard ⌘V for longer text (fast + reliable everywhere).
@MainActor
struct SmartInserter: TextInserter {
    /// Strings at or below this length are typed rather than pasted.
    static let keystrokeThreshold = 12

    private let keystroke = KeystrokeInserter()
    private let paste = PasteboardInserter()

    func insert(_ text: String) async throws {
        let signpost = Log.signposter
        let state = signpost.beginInterval("insert")
        defer { signpost.endInterval("insert", state) }

        if text.count <= Self.keystrokeThreshold {
            try await keystroke.insert(text)
        } else {
            try await paste.insert(text)
        }
    }

    /// Rescue path: just leave the text on the clipboard for the user to paste.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
