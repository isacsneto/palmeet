import Foundation

public typealias SessionID = UUID

/// The two audio tracks of a meeting. "Me" is the local microphone, "Them" is the meeting app's output.
public enum Track: String, Codable, Sendable, CaseIterable {
    case me
    case them
}

/// How a session's remote audio was isolated from everything else on the Mac.
public enum AudioIsolation: String, Codable, Sendable {
    /// Core Audio process tap on the app's process family.
    case processTap
    /// ScreenCaptureKit app-filtered audio (fallback).
    case screenCaptureKit
    /// Per-tab capture through the companion browser extension.
    case browserExtension
    /// Audio could not be isolated from another active session.
    case sharedAudio
    /// No remote audio (mic-only session).
    case none
}

/// What the user picked in the source picker.
public struct CaptureSourceDescriptor: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case window
        case application
        case browserTab
        /// An existing audio/video recording imported from disk.
        case importedFile
    }

    public var kind: Kind
    public var appName: String
    public var bundleID: String?
    public var processID: Int32?
    /// CGWindowID of the captured window, when there is one.
    public var windowID: UInt32?
    public var windowTitle: String?
    /// Browser-extension identifiers (only for `.browserTab`).
    public var browserProfileID: String?
    public var browserProfileLabel: String?
    public var browserWindowID: Int?
    public var browserTabID: Int?
    public var tabURL: String?

    public init(
        kind: Kind,
        appName: String,
        bundleID: String? = nil,
        processID: Int32? = nil,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        browserProfileID: String? = nil,
        browserProfileLabel: String? = nil,
        browserWindowID: Int? = nil,
        browserTabID: Int? = nil,
        tabURL: String? = nil
    ) {
        self.kind = kind
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.browserProfileID = browserProfileID
        self.browserProfileLabel = browserProfileLabel
        self.browserWindowID = browserWindowID
        self.browserTabID = browserTabID
        self.tabURL = tabURL
    }

    /// Short human label, e.g. "Chrome · Work · Google Meet – Weekly sync".
    public var displayName: String {
        var parts = [appName]
        if let browserProfileLabel, !browserProfileLabel.isEmpty { parts.append(browserProfileLabel) }
        if let windowTitle, !windowTitle.isEmpty { parts.append(windowTitle) }
        return parts.joined(separator: " · ")
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case recording
    case paused
    case processing
    case ready
    case failed
}

/// A span of time during which the shared microphone was routed to a session.
public struct MicRouteSpan: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(start: TimeInterval, end: TimeInterval? = nil) {
        self.start = start
        self.end = end
    }

    public func contains(_ offset: TimeInterval) -> Bool {
        offset >= start && offset < (end ?? .infinity)
    }
}

/// Everything about a session that isn't the transcript, screenshots or summary. Stored as `session.json`.
public struct SessionMetadata: Codable, Sendable, Identifiable, Equatable {
    public var id: SessionID
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var source: CaptureSourceDescriptor
    public var isolation: AudioIsolation
    public var includesMicrophone: Bool
    /// BCP-47 language hint, `nil` for auto.
    public var language: String?
    public var meetingMode: String?
    public var concurrentWith: [SessionID]
    /// Offsets (relative to `createdAt`) during which the mic was routed to this session.
    public var micRouting: [MicRouteSpan]
    /// Offsets during which recording was paused.
    public var pausedSpans: [MicRouteSpan]
    public var summaryProvider: String?
    public var summaryModel: String?
    public var lastError: String?
    public var appVersion: String

    public init(
        id: SessionID = SessionID(),
        title: String,
        createdAt: Date = Date(),
        source: CaptureSourceDescriptor,
        isolation: AudioIsolation,
        includesMicrophone: Bool = true,
        language: String? = nil,
        meetingMode: String? = nil,
        appVersion: String = "0.1.0"
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = nil
        self.status = .recording
        self.source = source
        self.isolation = isolation
        self.includesMicrophone = includesMicrophone
        self.language = language
        self.meetingMode = meetingMode
        self.concurrentWith = []
        self.micRouting = []
        self.pausedSpans = []
        self.appVersion = appVersion
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(createdAt) }
    }
}

// MARK: - Transcript

public struct Speaker: Codable, Sendable, Hashable, Identifiable {
    public static let meID = "me"

    public var id: String
    public var displayName: String
    public var isMe: Bool
    /// Where the name came from: "user", "screenshot", "transcript", "calendar", or nil for unnamed.
    public var nameSource: String?

    public init(id: String, displayName: String, isMe: Bool = false, nameSource: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.isMe = isMe
        self.nameSource = nameSource
    }

    public static func me(named name: String) -> Speaker {
        Speaker(id: meID, displayName: name, isMe: true, nameSource: "user")
    }
}

public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var speakerID: String
    public var track: Track
    /// Seconds from session start.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [TranscriptWord]
    public var confidence: Float
    public var isEdited: Bool
    /// True for segments produced by the live pass (replaced by the final pass).
    public var isLive: Bool

    public init(
        id: UUID = UUID(),
        speakerID: String,
        track: Track,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TranscriptWord] = [],
        confidence: Float = 1,
        isEdited: Bool = false,
        isLive: Bool = false
    ) {
        self.id = id
        self.speakerID = speakerID
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.confidence = confidence
        self.isEdited = isEdited
        self.isLive = isLive
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var sessionID: SessionID
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]

    public init(sessionID: SessionID, speakers: [Speaker] = [], segments: [TranscriptSegment] = []) {
        self.sessionID = sessionID
        self.speakers = speakers
        self.segments = segments
    }

    public func speaker(_ id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    public func displayName(for speakerID: String) -> String {
        speaker(speakerID)?.displayName ?? speakerID
    }

    /// Renames a speaker everywhere. Returns false if the speaker doesn't exist.
    @discardableResult
    public mutating func renameSpeaker(_ id: String, to name: String, source: String = "user") -> Bool {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return false }
        speakers[index].displayName = name
        speakers[index].nameSource = source
        return true
    }

    /// Reassigns one segment to another speaker (creating the speaker if needed).
    public mutating func reassign(segment segmentID: UUID, to speakerID: String, displayName: String? = nil) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        if speaker(speakerID) == nil {
            speakers.append(Speaker(id: speakerID, displayName: displayName ?? speakerID, isMe: speakerID == Speaker.meID))
        }
        segments[index].speakerID = speakerID
        segments[index].isEdited = true
    }

    public mutating func sortSegments() {
        segments.sort { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Plain-text rendering used as LLM input: "[00:01:02] Maria: text".
    public func plainText(range: ClosedRange<TimeInterval>? = nil) -> String {
        segments
            .filter { range?.contains($0.start) ?? true }
            .map { "[\(Timecode.format($0.start))] \(displayName(for: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n")
    }

    public var duration: TimeInterval { segments.map(\.end).max() ?? 0 }
}

// MARK: - Screen context

public struct ScreenshotRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        case interval
        case screenChange
        case manual
    }

    public var id: UUID
    public var index: Int
    /// Seconds from session start.
    public var offset: TimeInterval
    /// Path relative to the session folder, e.g. "screenshots/0007_00-12-00.jpg".
    public var relativePath: String
    public var reason: Reason
    public var ocrText: String
    /// Short text lines that look like participant name labels.
    public var nameCandidates: [String]
    public var perceptualHash: UInt64

    public init(
        id: UUID = UUID(),
        index: Int,
        offset: TimeInterval,
        relativePath: String,
        reason: Reason,
        ocrText: String = "",
        nameCandidates: [String] = [],
        perceptualHash: UInt64 = 0
    ) {
        self.id = id
        self.index = index
        self.offset = offset
        self.relativePath = relativePath
        self.reason = reason
        self.ocrText = ocrText
        self.nameCandidates = nameCandidates
        self.perceptualHash = perceptualHash
    }
}

public struct SessionNote: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var offset: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), offset: TimeInterval, text: String) {
        self.id = id
        self.offset = offset
        self.text = text
    }
}

// MARK: - Timecodes

public enum Timecode {
    /// "HH:MM:SS".
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Parses "HH:MM:SS", "MM:SS" or "[HH:MM:SS]".
    public static func parse(_ string: String) -> TimeInterval? {
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + TimeInterval($1) }
    }
}
