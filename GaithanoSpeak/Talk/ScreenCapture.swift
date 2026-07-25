import Foundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import SpeakCore

/// Grabs a JPEG of the screen for Talk's vision context.
///
/// Every failure path returns nil rather than throwing: a missing permission or an
/// unreadable display should quietly degrade Talk to text-only, never break the
/// answer.
enum ScreenCapture {
    /// Long edge to downscale to. Higher than it was when this captured a single
    /// window: a whole display holds far more, so the same budget would shrink UI
    /// text past legibility. Costs a few thousand prompt tokens, which is the point
    /// of sending an image at all.
    static let maxDimension: CGFloat = 1536

    /// JPEG quality. Screenshots are mostly flat UI, so this compresses well and
    /// the artifacts that remain don't hurt text legibility.
    static let compressionQuality: CGFloat = 0.7

    /// Capture the whole active display, or nil if we can't.
    ///
    /// Deliberately the *display* and not the focused window: picking a window meant
    /// asking who was frontmost, and with the Flow Bar up that could be us — so Talk
    /// ended up looking at its own overlay. A display capture has no such ambiguity,
    /// and it also lets the model see the thing next to the window you're in, which
    /// is usually what a question is about.
    ///
    /// Called at recording start rather than at question time, so the capture
    /// overlaps with the user still speaking instead of adding to answer latency.
    /// A capture plus the geometry needed to turn the model's coordinates back into
    /// real ones. The agent maps clicks through `imageSize` → `displayBounds`, so
    /// these must describe *this* image and *this* display or every click lands in
    /// the wrong place — a failure that looks exactly like the model being bad at
    /// finding buttons, which is why the two travel together instead of being
    /// recomputed at click time.
    struct Shot: Sendable {
        /// The JPEG actually sent to the model.
        var jpeg: Data
        /// Pixel dimensions of that JPEG, after downscaling.
        var imageSize: CGSize
        /// The captured display in global CoreGraphics coordinates — top-left origin,
        /// which is the space `CGEvent` mouse positions live in.
        var displayBounds: CGRect
    }

    /// Map a point the model gave us (pixels in the screenshot) to a global screen
    /// point suitable for `CGEvent`. Clamped to the display: a model that hallucinates
    /// an off-screen coordinate should click a harmless edge, not warp to another
    /// monitor.
    static func screenPoint(fromImage point: CGPoint, in shot: Shot) -> CGPoint {
        guard shot.imageSize.width > 0, shot.imageSize.height > 0 else {
            return CGPoint(x: shot.displayBounds.midX, y: shot.displayBounds.midY)
        }
        let scaleX = shot.displayBounds.width / shot.imageSize.width
        let scaleY = shot.displayBounds.height / shot.imageSize.height
        let x = shot.displayBounds.minX + point.x * scaleX
        let y = shot.displayBounds.minY + point.y * scaleY
        return CGPoint(
            x: min(max(x, shot.displayBounds.minX), shot.displayBounds.maxX - 1),
            y: min(max(y, shot.displayBounds.minY), shot.displayBounds.maxY - 1)
        )
    }

    /// Talk's vision context: the image alone.
    static func screenJPEG() async -> Data? {
        await capture()?.jpeg
    }

    /// The agent's capture: image plus the geometry to map clicks back.
    static func capture() async -> Shot? {
        guard CGPreflightScreenCaptureAccess() else {
            Log.talk.info("Screen Recording permission not granted; Talk stays text-only")
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            guard let display = activeDisplay(in: content) else {
                Log.talk.info("No capturable display")
                return nil
            }

            // Cut ourselves out. The Flow Bar — and, on a follow-up, the answer panel
            // — are on screen at capture time, so without this the model spends part
            // of its attention reading its own previous answer back to itself.
            let ourselves = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ourselves,
                                         exceptingWindows: [])

            let config = SCStreamConfiguration()
            // Capture at the display's own size, then downscale once below — letting
            // ScreenCaptureKit scale directly tends to blur small UI text.
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            guard let encoded = jpeg(from: image) else { return nil }
            // `CGDisplayBounds`, not `NSScreen.frame`: the former is top-left origin
            // global CG space, which is what CGEvent mouse positions use. Mixing the
            // two flips Y on any non-primary display.
            return Shot(jpeg: encoded.data,
                        imageSize: encoded.size,
                        displayBounds: CGDisplayBounds(display.displayID))
        } catch {
            Log.talk.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The display under the pointer — the one the user is actually looking at, and
    /// the same rule the overlay uses to pick a screen. Falls back to the first
    /// available so a multi-monitor edge case still returns something.
    private static func activeDisplay(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let id = screen?.deviceDescription[key] as? CGDirectDisplayID,
           let match = content.displays.first(where: { $0.displayID == id }) {
            return match
        }
        return content.displays.first
    }

    /// Downscale to `maxDimension` on the long edge and JPEG-encode, returning the
    /// final pixel size alongside the bytes so callers can map coordinates into it.
    private static func jpeg(from image: CGImage) -> (data: Data, size: CGSize)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let target = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        guard let context = CGContext(
            data: nil,
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        Log.talk.info("Captured screen screenshot (\(data.length / 1024) KB)")
        return (data as Data, target)
    }
}
