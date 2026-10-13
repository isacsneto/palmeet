import AppKit
@preconcurrency import ScreenCaptureKit

/// Verifies that PalMeet windows are really excluded from screen capture on this Mac.
///
/// Shows a small marker window with a distinctive magenta/green checkerboard (with the same `sharingType` the app
/// uses), captures the whole display through ScreenCaptureKit with no exclusions (the API meeting apps and
/// browsers use for screen sharing), and looks for the pattern where the marker is.
@MainActor
enum InvisibilityCheck {
    enum Outcome: Equatable {
        case hidden
        case visible
        case failed(String)

        var message: String {
            switch self {
            case .hidden: "✅ Hidden: PalMeet windows did not appear in a ScreenCaptureKit capture of your screen."
            case .visible: "⚠️ Visible: macOS included PalMeet windows in a screen capture. Auto-hide while sharing and the panic hotkey (⌃⌥\\) will still protect you; prefer sharing a single window or tab."
            case .failed(let reason): "Couldn't run the check: \(reason)"
            }
        }
    }

    static func run(sharingType: NSWindow.SharingType) async -> Outcome {
        guard let screen = NSScreen.main else { return .failed("No screen found.") }
        let size = CGSize(width: 96, height: 96)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let marker = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        marker.level = .screenSaver
        marker.sharingType = sharingType
        marker.isOpaque = true
        marker.contentView = CheckerView(frame: CGRect(origin: .zero, size: size))
        marker.orderFrontRegardless()
        defer { marker.orderOut(nil) }

        try? await Task.sleep(for: .milliseconds(400))

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                return .failed("No display available to capture.")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Convert the marker frame (AppKit, bottom-left origin) to image pixels (top-left origin).
            let scaleX = Double(image.width) / screen.frame.width
            let scaleY = Double(image.height) / screen.frame.height
            let rect = CGRect(
                x: (origin.x - screen.frame.minX) * scaleX,
                y: (screen.frame.maxY - origin.y - size.height) * scaleY,
                width: size.width * scaleX,
                height: size.height * scaleY
            ).insetBy(dx: 6, dy: 6)
            return patternFraction(in: image, rect: rect) > 0.3 ? .visible : .hidden
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Fraction of sampled pixels that are pure magenta or pure green.
    private static func patternFraction(in image: CGImage, rect: CGRect) -> Double {
        guard let cropped = image.cropping(to: rect.integral) else { return 0 }
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var matches = 0, samples = 0
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let magenta = r > 200 && g < 60 && b > 200
                let green = r < 60 && g > 200 && b < 60
                if magenta || green { matches += 1 }
                samples += 1
            }
        }
        return samples == 0 ? 0 : Double(matches) / Double(samples)
    }

    private final class CheckerView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let cell: CGFloat = 8
            for row in 0..<Int(bounds.height / cell) {
                for col in 0..<Int(bounds.width / cell) {
                    ((row + col).isMultiple(of: 2) ? NSColor(red: 1, green: 0, blue: 1, alpha: 1) : NSColor(red: 0, green: 1, blue: 0, alpha: 1)).setFill()
                    NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
        }
    }
}
