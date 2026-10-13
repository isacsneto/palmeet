import CoreGraphics
import Foundation

/// A tab reported by the companion extension.
public struct BrowserTab: Sendable, Hashable, Codable {
    public var tabID: Int
    public var title: String
    public var url: String
    public var active: Bool
    public var audible: Bool
    /// True when the URL matches one of the extension's meeting URL patterns.
    public var isMeeting: Bool

    public init(tabID: Int, title: String, url: String, active: Bool, audible: Bool, isMeeting: Bool) {
        self.tabID = tabID
        self.title = title
        self.url = url
        self.active = active
        self.audible = audible
        self.isMeeting = isMeeting
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tabId", title, url, active, audible, isMeeting
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try c.decode(Int.self, forKey: .tabID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        audible = try c.decodeIfPresent(Bool.self, forKey: .audible) ?? false
        isMeeting = try c.decodeIfPresent(Bool.self, forKey: .isMeeting) ?? false
    }
}

/// Window bounds in screen points, as reported by `chrome.windows` (top-left origin).
public struct BrowserWindowBounds: Sendable, Hashable, Codable {
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int

    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// The bounds as a `CGRect` in top-left-origin global screen coordinates
    /// (the same space as `SCWindow.frame` / `CGWindowListCopyWindowInfo`).
    public var rect: CGRect {
        CGRect(x: left, y: top, width: width, height: height)
    }
}

/// A browser window owned by one profile's extension instance.
public struct BrowserWindow: Sendable, Hashable, Codable {
    public var windowID: Int
    public var focused: Bool
    /// `chrome.windows.WindowState`: "normal", "minimized", "maximized", "fullscreen", "locked-fullscreen".
    public var state: String
    public var bounds: BrowserWindowBounds
    public var activeTabID: Int?
    public var tabs: [BrowserTab]

    public init(
        windowID: Int, focused: Bool, state: String, bounds: BrowserWindowBounds,
        activeTabID: Int?, tabs: [BrowserTab]
    ) {
        self.windowID = windowID
        self.focused = focused
        self.state = state
        self.bounds = bounds
        self.activeTabID = activeTabID
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "windowId", focused, state, bounds, activeTabID = "activeTabId", tabs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try c.decode(Int.self, forKey: .windowID)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "normal"
        bounds = try c.decodeIfPresent(BrowserWindowBounds.self, forKey: .bounds)
            ?? BrowserWindowBounds(left: 0, top: 0, width: 0, height: 0)
        activeTabID = try c.decodeIfPresent(Int.self, forKey: .activeTabID)
        tabs = try c.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
    }

    /// Tabs whose URL matches a meeting pattern.
    public var meetingTabs: [BrowserTab] { tabs.filter(\.isMeeting) }
}

/// One connected extension instance (= one browser profile).
public struct BrowserProfile: Sendable, Hashable, Identifiable {
    /// The extension's `profileInstanceId` (stable per browser profile).
    public var id: String
    /// User-facing name ("Work", "Client X", an email, …).
    public var label: String
    /// Browser family, e.g. "Chrome", "Edge", "Brave", "Arc", "Chromium".
    public var browser: String
    public var extensionVersion: String
    public var windows: [BrowserWindow]
    public var connectedAt: Date

    public init(
        id: String, label: String, browser: String, extensionVersion: String,
        windows: [BrowserWindow], connectedAt: Date
    ) {
        self.id = id
        self.label = label
        self.browser = browser
        self.extensionVersion = extensionVersion
        self.windows = windows
        self.connectedAt = connectedAt
    }
}

/// A chunk of tab audio, downmixed to mono.
public struct BridgeAudioChunk: Sendable {
    public var sessionID: UUID
    public var captureTime: Date
    public var sampleRate: Double
    /// Channel count of the original (interleaved) payload.
    public var channels: Int
    /// Mono samples (average of all channels), normalized to -1...1.
    public var samples: [Float]

    public init(sessionID: UUID, captureTime: Date, sampleRate: Double, channels: Int, samples: [Float]) {
        self.sessionID = sessionID
        self.captureTime = captureTime
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// A JPEG frame sampled from the captured tab's video track (~1 fps).
public struct BridgeVideoFrame: Sendable {
    public var sessionID: UUID
    public var captureTime: Date
    public var jpegData: Data

    public init(sessionID: UUID, captureTime: Date, jpegData: Data) {
        self.sessionID = sessionID
        self.captureTime = captureTime
        self.jpegData = jpegData
    }
}

public enum BridgeCaptureState: Sendable, Equatable {
    /// The extension is waiting for the user to click its toolbar icon (or press the shortcut).
    case awaitingGesture
    case capturing
    case stopped(String?)
    case error(String)

    public var isTerminal: Bool {
        switch self {
        case .stopped, .error: true
        case .awaitingGesture, .capturing: false
        }
    }
}

public enum BrowserBridgeEvent: Sendable {
    /// The set of connected profiles, or any of their windows/tabs, changed.
    case profilesChanged([BrowserProfile])
    case captureState(sessionID: UUID, BridgeCaptureState)
    /// The user started a capture from the browser (icon click with no pending request).
    /// The app may adopt it as a new session; audio for `sessionID` is already flowing.
    case userInitiatedCapture(sessionID: UUID, profileID: String, windowID: Int, tabID: Int)
    /// Mute / presenting state scraped from the meeting page. `nil` = unknown.
    case meetingState(sessionID: UUID, muted: Bool?, presenting: Bool?)
}

public enum BrowserBridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRunning
    case noAvailablePort([UInt16])
    case listenerFailed(String)
    case profileNotConnected(String)
    case unknownSession(UUID)

    public var description: String {
        switch self {
        case .notRunning: "The browser bridge server is not running."
        case .noAvailablePort(let ports): "No free port for the browser bridge (tried \(ports))."
        case .listenerFailed(let message): "Browser bridge listener failed: \(message)"
        case .profileNotConnected(let id): "Browser profile \(id) is not connected."
        case .unknownSession(let id): "Unknown capture session \(id)."
        }
    }
}
