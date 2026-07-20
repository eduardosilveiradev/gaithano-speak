import Foundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import SpeakCore

/// Grabs a JPEG of the focused window for Talk's vision context.
///
/// Every failure path returns nil rather than throwing: a missing permission or an
/// app with no capturable window should quietly degrade Talk to text-only, never
/// break the answer.
enum ScreenCapture {
    /// Long edge to downscale to. A 512px capture measured ~1090 prompt tokens
    /// against Gemini, so 1024 buys real legibility for UI text at a few thousand
    /// tokens — worth it, since reading the screen is the whole point.
    static let maxDimension: CGFloat = 1024

    /// JPEG quality. Screenshots are mostly flat UI, so this compresses well and
    /// the artifacts that remain don't hurt text legibility.
    static let compressionQuality: CGFloat = 0.7

    /// Capture the frontmost app's main window, or nil if we can't.
    ///
    /// Called at recording start rather than at question time, so the capture
    /// overlaps with the user still speaking instead of adding to answer latency.
    static func focusedWindowJPEG() async -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            Log.talk.info("Screen Recording permission not granted; Talk stays text-only")
            return nil
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            // Largest on-screen window belonging to the frontmost app: the main
            // document window, rather than a palette or an offscreen helper.
            let candidate = content.windows
                .filter { $0.owningApplication?.processID == frontmost.processIdentifier }
                .filter { $0.frame.width > 100 && $0.frame.height > 100 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

            guard let window = candidate else {
                Log.talk.info("No capturable window for the frontmost app")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Capture at the window's own size, then downscale once below — letting
            // ScreenCaptureKit scale directly tends to blur small UI text.
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return jpeg(from: image)
        } catch {
            Log.talk.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Downscale to `maxDimension` on the long edge and JPEG-encode.
    private static func jpeg(from image: CGImage) -> Data? {
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

        Log.talk.info("Captured window screenshot (\(data.length / 1024) KB)")
        return data as Data
    }
}
