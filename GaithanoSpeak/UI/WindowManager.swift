import AppKit
import SwiftUI

/// Presents SwiftUI views in reusable AppKit windows. Needed because the app runs
/// as an accessory (no Dock, `LSUIElement`) where SwiftUI's own window scenes are
/// awkward to open on demand.
@MainActor
enum WindowManager {
    private static var controllers: [String: NSWindowController] = [:]

    static func present<Content: View>(id: String,
                                       title: String,
                                       size: NSSize,
                                       @ViewBuilder content: () -> Content) {
        if let existing = controllers[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AnyView(content()))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        controllers[id] = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func close(id: String) {
        controllers[id]?.close()
    }
}
