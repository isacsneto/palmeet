import BrowserBridge
import CaptureKit
import CoreGraphics
import Foundation
import os
import VisionContext

/// Source of meeting screenshots for a session.
protocol FrameProvider: AnyObject, Sendable {
    var latestFrame: WindowFrameSampler.Frame? { get }
    func start() async throws
    func stop() async
    /// A frame for "mark moment". May return the latest frame when an on-demand capture isn't possible.
    func captureNow() async throws -> CGImage
}

extension WindowFrameSampler: FrameProvider {}

/// Frames of one browser tab from the extension's tab capture: shows only that meeting's tab, whichever window
/// is in front, and works for background tabs/windows.
final class BrowserTabFrames: FrameProvider, @unchecked Sendable {
    private let bridge: BrowserBridgeServer
    private let sessionID: UUID
    private let latest = OSAllocatedUnfairLock<WindowFrameSampler.Frame?>(initialState: nil)
    private var task: Task<Void, Never>?

    init(bridge: BrowserBridgeServer, sessionID: UUID) {
        self.bridge = bridge
        self.sessionID = sessionID
    }

    var latestFrame: WindowFrameSampler.Frame? { latest.withLock { $0 } }

    func start() async throws {
        let frames = bridge.videoFrames(for: sessionID)
        let latest = self.latest
        task = Task.detached(priority: .utility) {
            for await frame in frames {
                guard let image = ImageEncoding.cgImage(fromJPEG: frame.jpegData) else { continue }
                latest.withLock { $0 = WindowFrameSampler.Frame(image: image, time: frame.captureTime) }
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
    }

    func captureNow() async throws -> CGImage {
        guard let frame = latestFrame else { throw CaptureError.windowNotFound(0) }
        return frame.image
    }
}
