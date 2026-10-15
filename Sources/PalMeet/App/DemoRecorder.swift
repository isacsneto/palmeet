#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import PalMeetCore
import SessionKit
import SwiftUI
import UniformTypeIdentifiers

/// `PalMeet --demo-video <folder>` (debug builds): plays a scripted meeting in the app's real windows, off screen
/// and with made-up data (`DemoContent`), and writes `demo.mp4` and `demo.gif` (`scripts/make-demo-video.sh`).
/// Nothing real is recorded, read or sent.
@MainActor
enum DemoRecorder {
    static var outputFolder: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-video"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    static var isRequested: Bool { outputFolder != nil }

    static func makeManager() -> SessionManager {
        DemoContent.makeManager(root: FileManager.default.temporaryDirectory.appending(path: "palmeet-demo"))
    }

    static func start() {
        guard let folder = outputFolder else { return }
        Task {
            do {
                try await Recorder(folder: folder).run()
            } catch {
                FileHandle.standardError.write(Data("Demo video failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}

/// A window that always draws as the active one (the app is activated while recording so controls keep color).
private final class DemoWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The copilot panel draws its controls as active too (it floats beside the active main window).
private final class DemoPanel: NSPanel {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class Recorder {
    // Video: 1440×900, 12 fps. GIF: every other frame at 960×600.
    let width = 1440, height = 900, fps = 12
    let folder: URL
    let app = AppState.shared
    var mainWindow: NSWindow!
    var panelWindow: NSWindow!
    var showPanel = false
    var showMain = false
    var caption = ""
    var card: (title: String, lines: [String])?
    var live: MeetingSession?
    var speakingUntil: [String: Double] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    func run() async throws {
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        mainWindow = makeWindow(MainView().environment(app), size: NSSize(width: 1180, height: 740), x: -8000)
        panelWindow = makeWindow(CopilotPanelView().environment(app).frame(width: 380, height: 480), size: NSSize(width: 380, height: 480), x: -6000, panel: true)
        // Like the real app: the main window is the active one, the copilot panel floats without taking focus.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        let video = try VideoWriter(url: folder.appending(path: "demo.mp4"), width: width, height: height, fps: fps)
        let script = makeScript()
        let duration = 37.0
        let gif = try GIFWriter(url: folder.appending(path: "demo.gif"), frames: Int(duration * Double(fps)) / 2, delay: 2 / Double(fps))
        var nextAction = 0
        var frame = 0
        while Double(frame) / Double(fps) < duration {
            let t = Double(frame) / Double(fps)
            while nextAction < script.count, script[nextAction].at <= t {
                await script[nextAction].run()
                nextAction += 1
            }
            animateLevels(at: t)
            try? await Task.sleep(for: .milliseconds(30))
            let image = compose()
            try video.append(image, frame: frame)
            if frame.isMultiple(of: 2), let small = image.scaled(width: 960, height: 600) {
                gif.append(small)
            }
            frame += 1
        }
        try await video.finish()
        try gif.finish()
    }

    // MARK: Script

    struct Step {
        var at: Double
        var run: @MainActor () async -> Void
    }

    func makeScript() -> [Step] {
        var steps: [Step] = []
        func at(_ t: Double, _ run: @escaping @MainActor () async -> Void) { steps.append(Step(at: t, run: run)) }
        let lines = DemoContent.demoLines

        at(0) { self.card = ("PalMeet", ["Records, transcribes and summarizes your meetings.", "Native macOS · on-device speech recognition"]) }
        at(2.6) {
            self.card = nil
            self.showMain = true
            self.caption = "Record a meeting tab or app window: their audio and your mic, on separate tracks"
            if let session = try? await DemoContent.startLiveMeeting(in: self.app.manager) {
                self.live = session
                self.app.selectedSessionID = session.id
            }
        }
        at(3.6) { self.live?.demoCaptions(["Maria Silva", "John Park"]) }
        for (index, line) in lines.prefix(4).enumerated() {
            at(4 + Double(index) * 2.1) {
                self.speakingUntil[line.speaker == "me" ? "me" : "them"] = 4 + Double(index) * 2.1 + 1.8
                await self.live?.demoHear(line.text, speaker: line.speaker, at: line.at)
            }
        }
        at(13) {
            self.caption = "Live copilot: suggested answers, only while you turn it on"
            self.live?.setCopilot(enabled: true)
            self.showPanel = true
        }
        at(14) {
            let line = lines[4]
            self.speakingUntil["them"] = 15.8
            await self.live?.demoHear(line.text, speaker: line.speaker, at: line.at)
        }
        at(21.5) {
            self.caption = "A Markdown summary written by the AI you already use"
            self.showPanel = false
            if let live = self.live, let finished = await DemoContent.finish(live, in: self.app.manager) {
                self.app.reviewTab = .summary
                self.app.selectedSessionID = finished.id
            }
        }
        at(28) {
            self.caption = "Who said what: names from the meeting's captions and voices it learned"
            self.app.reviewTab = .transcript
        }
        at(34) {
            self.showMain = false
            self.caption = ""
            self.card = ("PalMeet", ["Hidden from screen sharing · Hotkeys for everything", "Claude, Codex, Gemini, Cursor or a local model"])
        }
        return steps.sorted { $0.at < $1.at }
    }

    /// Level meters follow whoever is "talking".
    func animateLevels(at t: Double) {
        guard let live else { return }
        func level(_ key: String) -> Float {
            guard let until = speakingUntil[key], t < until else { return 0.02 }
            return Float(0.35 + 0.35 * abs(sin(t * 9.1)) * abs(cos(t * 3.7)))
        }
        live.demoLevels(them: level("them"), me: level("me"))
    }

    // MARK: Drawing

    func makeWindow(_ view: some View, size: NSSize, x: CGFloat, panel: Bool = false) -> NSWindow {
        let frame = NSRect(origin: NSPoint(x: x, y: -6000), size: size)
        let window: NSWindow = panel
            ? DemoPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                      backing: .buffered, defer: false)
            : DemoWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.orderFrontRegardless()
        return window
    }

    func snapshot(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    func compose() -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1), CGColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = nil }

        if let card {
            drawCard(card.title, card.lines)
        }
        if showMain, let image = snapshot(mainWindow) {
            let w: CGFloat = 1180, h = w * CGFloat(image.height) / CGFloat(image.width)
            draw(image, in: CGRect(x: (CGFloat(width) - w) / 2 - (showPanel ? 90 : 0), y: 40, width: w, height: h), in: context)
        }
        if showPanel, let image = snapshot(panelWindow) {
            let w: CGFloat = 330, h = w * CGFloat(image.height) / CGFloat(image.width)
            draw(image, in: CGRect(x: CGFloat(width) - w - 40, y: 70, width: w, height: h), in: context)
        }
        if !caption.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style,
            ])
            text.draw(in: NSRect(x: 40, y: CGFloat(height) - 70, width: CGFloat(width) - 80, height: 44))
        }
        return context.makeImage()!
    }

    func draw(_ image: CGImage, in rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    func drawCard(_ title: String, _ lines: [String]) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let icon = NSApp.applicationIconImage ?? NSImage()
        icon.draw(in: NSRect(x: CGFloat(width) / 2 - 90, y: CGFloat(height) / 2 + 60, width: 180, height: 180))
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: style])
            .draw(in: NSRect(x: 0, y: CGFloat(height) / 2 - 40, width: CGFloat(width), height: 90))
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 30, weight: index == 0 ? .medium : .regular),
                                                          .foregroundColor: NSColor(white: index == 0 ? 0.92 : 0.7, alpha: 1), .paragraphStyle: style])
                .draw(in: NSRect(x: 0, y: CGFloat(height) / 2 - 100 - CGFloat(index) * 48, width: CGFloat(width), height: 44))
        }
    }
}

// MARK: - Video

private final class VideoWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_600_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        self.fps = Int32(fps)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, frame: Int) throws {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

/// Animated GIF for the README (plays inline on GitHub).
private final class GIFWriter {
    let destination: CGImageDestination
    let frameProperties: CFDictionary

    init(url: URL, frames: Int, delay: Double) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.destination = destination
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
    }

    func append(_ image: CGImage) {
        CGImageDestinationAddImage(destination, image, frameProperties)
    }

    func finish() throws {
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private extension CGImage {
    func scaled(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
#endif
