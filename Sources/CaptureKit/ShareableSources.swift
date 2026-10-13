import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Known meeting apps and how to find all of their audio-producing processes.
public struct MeetingApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let isBrowser: Bool
    /// Bundle prefixes whose processes play this app's audio.
    public let audioBundlePrefixes: [String]

    public static let known: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false, audioBundlePrefixes: ["us.zoom"]),
        MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isBrowser: false, audioBundlePrefixes: ["com.microsoft.teams2"]),
        MeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)", isBrowser: false, audioBundlePrefixes: ["com.microsoft.teams"]),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isBrowser: false, audioBundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", isBrowser: false, audioBundlePrefixes: ["com.cisco.webex", "com.webex"]),
        MeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex", isBrowser: false, audioBundlePrefixes: ["Cisco-Systems.Spark"]),
        MeetingApp(bundleID: "com.hnc.Discord", name: "Discord", isBrowser: false, audioBundlePrefixes: ["com.hnc.Discord"]),
        MeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isBrowser: false, audioBundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true, audioBundlePrefixes: ["com.google.Chrome"]),
        MeetingApp(bundleID: "com.google.Chrome.beta", name: "Chrome Beta", isBrowser: true, audioBundlePrefixes: ["com.google.Chrome.beta"]),
        MeetingApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true, audioBundlePrefixes: ["com.microsoft.edgemac"]),
        MeetingApp(bundleID: "com.brave.Browser", name: "Brave", isBrowser: true, audioBundlePrefixes: ["com.brave.Browser"]),
        MeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true, audioBundlePrefixes: ["company.thebrowser"]),
        MeetingApp(bundleID: "com.apple.Safari", name: "Safari", isBrowser: true, audioBundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"]),
        MeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true, audioBundlePrefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer"]),
    ]

    public static func lookup(bundleID: String?) -> MeetingApp? {
        guard let bundleID else { return nil }
        return known.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Audio family for any app; unknown apps fall back to their own bundle ID + PID.
    public static func audioFamily(bundleID: String?, pid: pid_t?) -> AppAudioFamily {
        let prefixes = lookup(bundleID: bundleID)?.audioBundlePrefixes ?? bundleID.map { [$0] } ?? []
        return AppAudioFamily(bundlePrefixes: prefixes, pids: pid.map { [$0] } ?? [])
    }
}

/// A window the user can record.
public struct CapturableWindow: Sendable, Hashable, Identifiable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let bundleID: String?
    public let pid: pid_t
    public let frame: CGRect
    public let isOnScreen: Bool

    public var meetingApp: MeetingApp? { MeetingApp.lookup(bundleID: bundleID) }
    public var isMeetingApp: Bool { meetingApp != nil }
    public var isBrowser: Bool { meetingApp?.isBrowser ?? false }
}

public enum ShareableSources {
    /// Windows worth showing in the source picker: titled, reasonably sized, not ours. Meeting apps first.
    public static func windows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownBundleID = Bundle.main.bundleIdentifier
        let windows = content.windows.compactMap { window -> CapturableWindow? in
            guard let app = window.owningApplication,
                  app.bundleIdentifier != ownBundleID,
                  window.windowLayer == 0,
                  window.frame.width >= 200, window.frame.height >= 150
            else { return nil }
            let title = window.title ?? ""
            let isMeeting = MeetingApp.lookup(bundleID: app.bundleIdentifier) != nil
            // Untitled windows of non-meeting apps are usually palettes and helpers.
            guard !title.isEmpty || isMeeting else { return nil }
            return CapturableWindow(
                id: window.windowID,
                title: title,
                appName: app.applicationName,
                bundleID: app.bundleIdentifier,
                pid: app.processID,
                frame: window.frame,
                isOnScreen: window.isOnScreen
            )
        }
        return windows.sorted { lhs, rhs in
            if lhs.isMeetingApp != rhs.isMeetingApp { return lhs.isMeetingApp }
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            return (lhs.appName, lhs.title) < (rhs.appName, rhs.title)
        }
    }

    /// Thumbnail of a single window, even if it is covered by other windows.
    public static func thumbnail(windowID: CGWindowID, maxWidth: Int = 480) async throws -> CGImage? {
        guard let window = try await scWindow(id: windowID) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, Double(maxWidth) / max(1, window.frame.width))
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func scWindow(id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }

    /// The front-most normal window of the front-most app (for the "record this meeting" hotkey).
    public static func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let match = info.first { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && (entry[kCGWindowLayer as String] as? Int) == 0
        }
        return (match?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }
}
