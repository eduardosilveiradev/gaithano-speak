import Foundation
import AppKit
import CoreGraphics
import SpeakCore

/// Performs agent actions with synthesized events. The single place in the app that
/// turns a model's decision into a real click or keystroke.
///
/// It executes and nothing else: whether an action is *allowed* was already decided
/// by `AgentRiskPolicy` and `AgentSession`. Keeping that separation means the safety
/// rail can't be quietly bypassed by a future caller reaching for the executor
/// directly — there is no approval logic here to forget to call.
@MainActor
enum AgentExecutor {

    /// Pause after each action so the UI under us can react before the next
    /// screenshot. Too short and the agent photographs a half-drawn window and
    /// concludes its click failed.
    static let settleDelay: TimeInterval = 0.45

    enum ExecutionError: Error {
        case noEventSource
        case eventCreationFailed
        case unknownKey(String)
    }

    static func perform(_ action: AgentAction, in shot: ScreenCapture.Shot) async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ExecutionError.noEventSource
        }

        switch action {
        case let .click(x, y, _, double):
            let point = ScreenCapture.screenPoint(
                fromImage: CGPoint(x: x, y: y), in: shot)
            try click(at: point, source: source, double: double)

        case let .type(text):
            try await type(text, source: source)

        case let .press(keys):
            try press(keys, source: source)

        case let .scroll(x, y, amount):
            let point = ScreenCapture.screenPoint(
                fromImage: CGPoint(x: x, y: y), in: shot)
            try scroll(at: point, amount: amount, source: source)

        case let .switchTab(target):
            try switchTab(to: target, source: source)

        case .done:
            return   // not an action on the machine
        }

        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
    }

    // MARK: - Mouse

    private static func click(at point: CGPoint,
                              source: CGEventSource,
                              double: Bool) throws {
        // Move first as its own event. Some apps track hover state and won't accept a
        // click that teleports in with no preceding movement.
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left) else {
            throw ExecutionError.eventCreationFailed
        }
        move.post(tap: .cghidEventTap)

        for clickNumber in 1...(double ? 2 : 1) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) else {
                throw ExecutionError.eventCreationFailed
            }
            // `clickState` is what makes the second click register as a double rather
            // than two singles; without it, double-click never opens anything.
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func scroll(at point: CGPoint,
                               amount: Int,
                               source: CGEventSource) throws {
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left) else {
            throw ExecutionError.eventCreationFailed
        }
        move.post(tap: .cghidEventTap)

        // Negative wheel1 scrolls down, matching the model's "positive = down".
        guard let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(-amount),
                                  wheel2: 0, wheel3: 0) else {
            throw ExecutionError.eventCreationFailed
        }
        wheel.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Types Unicode directly, the same technique `KeystrokeInserter` uses — it needs
    /// no keycode table and so handles any language or emoji the model produces.
    private static func type(_ text: String, source: CGEventSource) async throws {
        let units = Array(text.utf16)
        var index = 0
        let chunk = 16
        while index < units.count {
            let end = min(index + chunk, units.count)
            var slice = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ExecutionError.eventCreationFailed
            }
            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            try? await Task.sleep(nanoseconds: 1_500_000)
        }
    }

    /// Tab switching rides on the same shortcuts a person would use, rather than an
    /// app-specific AppleScript per browser: ⌘1–9 is honoured by Chrome, Safari, Arc,
    /// Firefox, Xcode, VS Code, and every terminal worth naming, and ⌃⇥ cycles in all
    /// of them too. Nothing here is browser-aware, so nothing here breaks when the
    /// user's browser changes.
    private static func switchTab(to target: TabTarget,
                                  source: CGEventSource) throws {
        switch target {
        case let .index(n):
            // Clamped, not rejected. There is no ⌘10, and 9 already means "last" in
            // the apps that matter — so a model asking for tab 12 gets the end of the
            // strip, which is far likelier to be what it meant than an error.
            try press("cmd+\(min(max(n, 1), 9))", source: source)
        case .next:
            try press("ctrl+tab", source: source)
        case .previous:
            try press("ctrl+shift+tab", source: source)
        }
    }

    /// A chord like `cmd+shift+a`, or a bare key like `return`.
    private static func press(_ combo: String, source: CGEventSource) throws {
        let parts = combo.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last else { throw ExecutionError.unknownKey(combo) }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw ExecutionError.unknownKey(modifier)
            }
        }

        guard let code = keyCode(for: keyName) else {
            throw ExecutionError.unknownKey(keyName)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ExecutionError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Virtual keycodes for the keys a chord realistically names. Letters and digits
    /// are included because they're the other half of every ⌘-shortcut.
    private static func keyCode(for name: String) -> CGKeyCode? {
        if let special = specialKeys[name] { return special }
        if name.count == 1, let scalar = name.unicodeScalars.first {
            if let letter = letterKeys[Character(scalar)] { return letter }
            if let digit = digitKeys[Character(scalar)] { return digit }
        }
        return nil
    }

    private static let specialKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    private static let letterKeys: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
    ]

    private static let digitKeys: [Character: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
    ]
}
