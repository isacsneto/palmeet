import Foundation

/// File layout of one session folder:
///
///     2026-10-13 1500 – Weekly sync/
///       session.json  transcript.json  transcript.md  summary.json  summary.md  copilot.json  notes.json
///       meeting-speakers.json (captions / speaking indicators)  speaker-voices.json (voiceprints)
///       audio/them.caf  audio/me.caf
///       screenshots/0001_00-00-30.jpg  screenshots/index.json
public struct SessionFolder: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var metadataURL: URL { url.appending(path: "session.json") }
    public var transcriptJSONURL: URL { url.appending(path: "transcript.json") }
    public var transcriptMarkdownURL: URL { url.appending(path: "transcript.md") }
    public var summaryJSONURL: URL { url.appending(path: "summary.json") }
    public var summaryMarkdownURL: URL { url.appending(path: "summary.md") }
    public var copilotURL: URL { url.appending(path: "copilot.json") }
    public var notesURL: URL { url.appending(path: "notes.json") }
    /// Context the user typed for the meeting (agenda, ticket, who's who); used by the copilot and the summary.
    public var contextURL: URL { url.appending(path: "context.md") }
    /// Who the meeting app showed as talking (captions, speaking indicators).
    public var meetingSpeakersURL: URL { url.appending(path: "meeting-speakers.json") }
    /// Voiceprint of each remote speaker, used to learn voices when speakers are named.
    public var speakerVoicesURL: URL { url.appending(path: "speaker-voices.json") }
    /// Which meeting-page elements changed while recording (diagnostics for speaker detection).
    public var pageDiagnosticsURL: URL { url.appending(path: "page-diagnostics.jsonl") }
    public var audioDirectory: URL { url.appending(path: "audio", directoryHint: .isDirectory) }
    public var screenshotsDirectory: URL { url.appending(path: "screenshots", directoryHint: .isDirectory) }
    public var screenshotIndexURL: URL { screenshotsDirectory.appending(path: "index.json") }

    public func audioURL(for track: Track) -> URL {
        audioDirectory.appending(path: "\(track.rawValue).caf")
    }

    /// "screenshots/0007_00-12-00.jpg"
    public static func screenshotRelativePath(index: Int, offset: TimeInterval) -> String {
        let stamp = Timecode.format(offset).replacingOccurrences(of: ":", with: "-")
        return "screenshots/" + String(format: "%04d_", index) + stamp + ".jpg"
    }

    public func createDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case notFound(SessionID)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "Session \(id) was not found on disk."
        }
    }
}

/// Reads and writes sessions under a root directory (default `~/Documents/PalMeet`).
/// All writes are atomic; the store holds no in-memory state besides the root URL.
public struct SessionStore: Sendable {
    public let rootURL: URL

    public static var defaultRootURL: URL {
        URL.documentsDirectory.appending(path: "PalMeet", directoryHint: .isDirectory)
    }

    public init(rootURL: URL = SessionStore.defaultRootURL) {
        self.rootURL = rootURL
    }

    // MARK: Folders

    public func createFolder(for metadata: SessionMetadata) throws -> SessionFolder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let base = "\(formatter.string(from: metadata.createdAt)) – \(Self.sanitize(metadata.title))"
        var url = rootURL.appending(path: base, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rootURL.appending(path: "\(base) (\(suffix))", directoryHint: .isDirectory)
            suffix += 1
        }
        let folder = SessionFolder(url: url)
        try folder.createDirectories()
        try save(metadata, in: folder)
        return folder
    }

    /// Lists every session folder (newest first) whose `session.json` decodes.
    public func listSessions() -> [(SessionMetadata, SessionFolder)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.compactMap { url in
            let folder = SessionFolder(url: url)
            guard let metadata = try? loadMetadata(in: folder) else { return nil }
            return (metadata, folder)
        }
        .sorted { $0.0.createdAt > $1.0.createdAt }
    }

    public func folder(for id: SessionID) throws -> SessionFolder {
        guard let match = listSessions().first(where: { $0.0.id == id }) else { throw SessionStoreError.notFound(id) }
        return match.1
    }

    public func delete(_ folder: SessionFolder) throws {
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
    }

    // MARK: Documents

    public func save(_ metadata: SessionMetadata, in folder: SessionFolder) throws {
        try Self.writeJSON(metadata, to: folder.metadataURL)
    }

    public func loadMetadata(in folder: SessionFolder) throws -> SessionMetadata {
        try Self.readJSON(SessionMetadata.self, from: folder.metadataURL)
    }

    public func save(_ transcript: Transcript, metadata: SessionMetadata, in folder: SessionFolder) throws {
        try Self.writeJSON(transcript, to: folder.transcriptJSONURL)
        let markdown = TranscriptMarkdownRenderer.render(transcript, metadata: metadata)
        try Data(markdown.utf8).write(to: folder.transcriptMarkdownURL, options: .atomic)
    }

    public func loadTranscript(in folder: SessionFolder) throws -> Transcript {
        try Self.readJSON(Transcript.self, from: folder.transcriptJSONURL)
    }

    public func save(_ summary: MeetingSummary, metadata: SessionMetadata, transcript: Transcript, in folder: SessionFolder) throws {
        try Self.writeJSON(summary, to: folder.summaryJSONURL)
        let markdown = SummaryMarkdownRenderer.render(summary, metadata: metadata, transcript: transcript)
        try Data(markdown.utf8).write(to: folder.summaryMarkdownURL, options: .atomic)
    }

    public func loadSummary(in folder: SessionFolder) throws -> MeetingSummary {
        try Self.readJSON(MeetingSummary.self, from: folder.summaryJSONURL)
    }

    public func save(_ screenshots: [ScreenshotRecord], in folder: SessionFolder) throws {
        try Self.writeJSON(screenshots, to: folder.screenshotIndexURL)
    }

    public func loadScreenshots(in folder: SessionFolder) -> [ScreenshotRecord] {
        (try? Self.readJSON([ScreenshotRecord].self, from: folder.screenshotIndexURL)) ?? []
    }

    public func save(_ notes: [SessionNote], in folder: SessionFolder) throws {
        try Self.writeJSON(notes, to: folder.notesURL)
    }

    public func loadNotes(in folder: SessionFolder) -> [SessionNote] {
        (try? Self.readJSON([SessionNote].self, from: folder.notesURL)) ?? []
    }

    // MARK: Helpers

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    /// Makes a title safe for a folder name.
    public static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        let limited = String(collapsed.prefix(80))
        return limited.isEmpty ? "Meeting" : limited
    }
}
