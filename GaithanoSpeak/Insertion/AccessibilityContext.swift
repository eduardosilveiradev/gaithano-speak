import Foundation
import ApplicationServices

/// Best-effort reader of the focused text field's contents around the cursor, via
/// the Accessibility API. Used to merge new dictation into existing text cleanly.
/// Returns nils whenever the focused app doesn't expose an AX text value (many
/// Electron/web apps don't) — the pipeline degrades gracefully.
@MainActor
enum AccessibilityContext {
    struct Context {
        var precedingText: String?
        var followingText: String?
    }

    /// How much text on each side of the cursor to hand the model.
    private static let window = 240

    static func focusedTextContext() -> Context {
        guard PermissionsService.accessibilityGranted else { return Context() }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return Context()
        }
        let axElement = element as! AXUIElement

        // Full text value of the field.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else {
            return Context()
        }

        // Cursor position (selected text range → location).
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else {
            // No cursor info — treat the whole field as preceding context.
            return Context(precedingText: String(text.suffix(window)), followingText: nil)
        }

        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) else {
            return Context(precedingText: String(text.suffix(window)), followingText: nil)
        }

        let location = max(0, min(cfRange.location, text.count))
        let chars = Array(text)
        let precedingStart = max(0, location - window)
        let preceding = String(chars[precedingStart..<location])
        let followingEnd = min(chars.count, location + window)
        let following = location < chars.count ? String(chars[location..<followingEnd]) : nil

        return Context(
            precedingText: preceding.isEmpty ? nil : preceding,
            followingText: (following?.isEmpty ?? true) ? nil : following
        )
    }

    /// Text the user currently has selected in the focused element, or nil if there
    /// is no selection or the app doesn't expose one. Talk uses this to ground a
    /// question like "what does this mean?" in whatever the user highlighted.
    static func selectedText() -> String? {
        guard PermissionsService.accessibilityGranted else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return nil
        }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let selected = selectedRef as? String else {
            return nil
        }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Screen bounds of the text insertion caret, in Core Graphics global coordinates
    /// (top-left origin), or nil if the focused element doesn't expose it. Native
    /// text views support this; most Electron/web apps (Claude Desktop, browsers, VS
    /// Code) return nothing, so callers must have a fallback.
    static func caretScreenRect() -> CGRect? {
        guard PermissionsService.accessibilityGranted else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let ax = element as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var cursor = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cursor) else { return nil }

        // Zero-length range at the cursor → the caret's rect.
        var caretRange = CFRange(location: cursor.location, length: 0)
        guard let caretRangeValue = AXValueCreate(.cfRange, &caretRange) else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                ax, kAXBoundsForRangeParameterizedAttribute as CFString, caretRangeValue, &boundsRef) == .success,
              let boundsValue = boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }

        // A collapsed caret has zero width but a real height; reject empty rects.
        guard rect.height > 1, rect.width >= 0, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }
}
