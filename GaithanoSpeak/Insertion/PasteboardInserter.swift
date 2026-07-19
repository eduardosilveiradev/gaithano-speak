import AppKit
import CoreGraphics
import SpeakCore

/// Inserts text by placing it on the pasteboard and synthesizing ⌘V, then
/// restoring the previous clipboard contents. The most universally reliable
/// method (works in Electron, terminals, web apps). Requires Accessibility.
@MainActor
struct PasteboardInserter: TextInserter {
    /// Pasteboard type well-behaved clipboard managers skip.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general

        // Snapshot the current contents so we can restore them.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        let writeCount = pasteboard.changeCount

        try synthesizePaste()

        // Restore only if nothing else grabbed the clipboard after us.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard pasteboard.changeCount == writeCount else {
            Log.insert.info("Clipboard changed after paste; leaving new contents.")
            return
        }
        pasteboard.clearContents()
        if saved.isEmpty {
            // Nothing to restore.
        } else {
            let items: [NSPasteboardItem] = saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

    private func synthesizePaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertionError.noEventSource
        }
        let vKeyV: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: false) else {
            throw InsertionError.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
