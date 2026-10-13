import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Samples one window at a low frame rate with ScreenCaptureKit and keeps the latest frame.
///
/// The window is captured even when covered by other windows. The owner polls `latestFrame` on its own schedule
/// (screenshot policy) instead of reacting to every frame, because ScreenCaptureKit only delivers frames when
/// the window content changes.
public final class WindowFrameSampler: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    public struct Frame: @unchecked Sendable {
        public let image: CGImage
        public let time: Date

        public init(image: CGImage, time: Date) {
            self.image = image
            self.time = time
        }
    }

    public let windowID: CGWindowID
    private let maxWidth: Int
    private let frameInterval: TimeInterval
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.palmeet.frames", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let latest = OSAllocatedUnfairLock<Frame?>(initialState: nil)
    private let logger = Logger(subsystem: "app.palmeet", category: "FrameSampler")
    private let onStop: (@Sendable (Error?) -> Void)?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?

    public init(windowID: CGWindowID, maxWidth: Int = 1600, frameInterval: TimeInterval = 1, onStop: (@Sendable (Error?) -> Void)? = nil) {
        self.windowID = windowID
        self.maxWidth = maxWidth
        self.frameInterval = frameInterval
        self.onStop = onStop
    }

    public var latestFrame: Frame? { latest.withLock { $0 } }

    public func start() async throws {
        guard let window = try await ShareableSources.scWindow(id: windowID) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(2, Double(filter.pointPixelScale))
        let pixelWidth = window.frame.width * scale
        let factor = min(1, Double(maxWidth) / max(1, pixelWidth))
        config.width = max(2, Int(pixelWidth * factor))
        config.height = max(2, Int(window.frame.height * scale * factor))
        config.minimumFrameInterval = CMTime(seconds: frameInterval, preferredTimescale: 600)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.filter = filter
        self.configuration = config
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// Full-quality capture right now (for "mark moment"), independent of the stream.
    public func captureNow() async throws -> CGImage {
        if let filter, let configuration {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        guard let image = try await ShareableSources.thumbnail(windowID: windowID, maxWidth: maxWidth) else {
            throw CaptureError.windowNotFound(windowID)
        }
        return image
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        latest.withLock { $0 = Frame(image: image, time: Date()) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.warning("Window stream stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case windowNotFound(CGWindowID)
    case permissionDenied(String)
    case noAudioProcesses(String)

    public var errorDescription: String? {
        switch self {
        case .windowNotFound: "The selected window is no longer available."
        case .permissionDenied(let what): "Permission needed: \(what)."
        case .noAudioProcesses(let app): "\(app) is not playing audio yet. PalMeet will start capturing as soon as it does."
        }
    }
}
