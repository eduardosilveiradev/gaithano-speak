import Foundation
import CoreGraphics
import SpeakCore

/// Types text directly as synthesized Unicode key events. Clipboard-free, best
/// for short strings. Requires Accessibility (PostEvent) permission.
@MainActor
struct KeystrokeInserter: TextInserter {
    /// UTF-16 units per event; small chunks avoid dropped characters in some apps.
    private let chunkSize = 16

    func insert(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertionError.noEventSource
        }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var slice = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw InsertionError.eventCreationFailed
            }
            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            // A tiny gap keeps fast apps from coalescing/dropping events.
            try? await Task.sleep(nanoseconds: 1_500_000)
        }
    }
}

enum InsertionError: Error {
    case noEventSource
    case eventCreationFailed
    case pasteFailed
}
