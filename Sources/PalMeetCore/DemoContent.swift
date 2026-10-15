#if DEBUG
import AppKit
import BrowserBridge
import CaptureKit
import CopilotKit
import Foundation
import LLMKit
import SessionKit
import TranscriptKit

/// Made-up meetings and silent devices for the README demo video (`PalMeet --demo-video`, debug builds only).
/// Everything lives in a temporary folder and a separate settings domain: no real meeting, setting, voice,
/// microphone or AI provider is touched.
@MainActor
public enum DemoContent {
    public static let userName = "Alex Morgan"
    public static let meetingTitle = "Checkout sync"

    /// A manager whose library holds the demo meetings, with fake capture and a scripted AI.
    public static func makeManager(root: URL) -> SessionManager {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.palmeet.demo"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        var settings = AppSettings()
        settings.profile = UserProfile(name: userName, role: "Engineering lead", team: "Payments")
        settings.storageRoot = root.path
        settings.hasCompletedOnboarding = true
        settings.copilot.proactiveQuestions = false
        settings.recognizeVoices = false
        settings.meetingPageDiagnostics = false
        settings.compactScreenshots = false
        settings.audioStorage = .original
        settings.privacy.showMenuBarIcon = false
        settings.privacy.hideFromScreenCapture = false
        let settingsStore = SettingsStore(suiteName: suite)
        settingsStore.save(settings)
        let store = SessionStore(rootURL: root)
        writeLibrary(to: store)
        let services = SessionServices(
            store: store,
            microphone: SilentMicrophone(),
            asr: SilentASR(),
            diarizer: SilentDiarizer(),
            scheduler: ASRScheduler(),
            voices: VoiceProfileStore(url: root.appending(path: "Voices.json")),
            makeProvider: { _ in ScriptedLLM() },
            ensureMicrophoneAccess: { true }
        )
        let bridge = BrowserBridgeServer(configuration: .init(portCandidates: [0], bridgeInfoStore: nil, token: "demo"))
        let manager = SessionManager(settingsStore: settingsStore, secrets: InMemorySecretStore(), settingsBox: SettingsBox(settings), services: services, bridge: bridge)
        manager.refreshLibrary()
        return manager
    }

    /// Starts the live "Checkout sync" meeting: a Google Meet tab recorded through the extension.
    public static func startLiveMeeting(in manager: SessionManager) async throws -> MeetingSession {
        let source = CaptureSourceDescriptor(
            kind: .browserTab, appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: meetingTitle,
            browserProfileID: "demo-work", browserProfileLabel: "Work", browserWindowID: 1, browserTabID: 1,
            tabURL: "https://meet.google.com/abc-defg-hij"
        )
        let session = try await manager.startSession(
            id: SessionID(), source: source, title: meetingTitle, remote: SilentRemoteAudio(),
            windowID: nil, frames: nil, includeMicrophone: true, preview: .isolated("browser extension (this tab only)")
        )
        session.context = "Agenda: 3-D Secure checkout bug (PAY-142), Friday beta\nMaria Silva – PM · John Park – payments"
        return session
    }

    /// Ends the live meeting without processing it and shows the finished copy (already in the library).
    public static func finish(_ live: MeetingSession, in manager: SessionManager) async -> MeetingSession? {
        manager.demoRemoveActive(live)
        await live.stop(processAfterwards: false)
        return manager.library.first { $0.title == meetingTitle }
    }

    // MARK: Library

    struct Line {
        var speaker: String
        var at: TimeInterval
        var text: String
    }

    static let speakers = [
        Speaker(id: "S1", displayName: "Maria Silva", nameSource: "meeting"),
        Speaker(id: "S2", displayName: "John Park", nameSource: "voice"),
        Speaker.me(named: userName),
    ]

    /// The meeting's lines, for the live part of the video.
    public static var demoLines: [(speaker: String, at: TimeInterval, text: String)] {
        checkoutLines.map { ($0.speaker, $0.at, $0.text) }
    }

    static let checkoutLines: [Line] = [
        Line(speaker: "S1", at: 2, text: "Morning! Let's start with the checkout bug from yesterday's release."),
        Line(speaker: "S2", at: 8, text: "Payments fail when the card needs 3-D Secure, mostly on Safari."),
        Line(speaker: "me", at: 15, text: "I reproduced it. The redirect back from the bank loses the session cookie."),
        Line(speaker: "S2", at: 23, text: "That matches the logs: about four percent of checkouts since Tuesday."),
        Line(speaker: "S1", at: 31, text: "Alex, can you own the fix and confirm by Thursday?"),
        Line(speaker: "me", at: 37, text: "Yes. I'll set SameSite=None on the cookie and add a regression test."),
        Line(speaker: "S1", at: 45, text: "Great. Then we keep the beta on Friday, with the fix behind a flag."),
        Line(speaker: "S2", at: 52, text: "I'll watch the payment dashboards over the weekend."),
    ]

    static func writeLibrary(to store: SessionStore) {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        writeMeeting(
            to: store, title: meetingTitle, app: "Chrome", createdAt: today, lines: checkoutLines,
            context: "Agenda: 3-D Secure checkout bug (PAY-142), Friday beta\nMaria Silva – PM · John Park – payments",
            summary: checkoutSummary, screenshot: true
        )
        let older: [(String, String, Int, String)] = [
            ("Design review – onboarding", "Zoom", -1, "New onboarding flow approved; copy changes before handoff."),
            ("1:1 with Maria", "Microsoft Teams", -2, "Q4 goals agreed; Alex leads the payments reliability work."),
            ("Customer call – Northwind", "Chrome", -3, "Northwind wants SSO in Q1; pricing follow-up next week."),
            ("Sprint planning", "Slack", -6, "Sprint 42 scoped: checkout reliability, refunds API, dashboards."),
        ]
        for (title, app, days, tldr) in older {
            let date = calendar.date(byAdding: .day, value: days, to: today) ?? today
            let summary = #"{"title":"\#(title)","tldr":"\#(tldr)","decisions":[],"action_items":[]}"#
            writeMeeting(to: store, title: title, app: app, createdAt: date.addingTimeInterval(Double(days) * 1_800),
                         lines: [Line(speaker: "S1", at: 3, text: tldr)], context: "", summary: summary, screenshot: false)
        }
    }

    static func writeMeeting(to store: SessionStore, title: String, app: String, createdAt: Date, lines: [Line],
                             context: String, summary json: String, screenshot: Bool) {
        let source = CaptureSourceDescriptor(kind: app == "Chrome" ? .browserTab : .window, appName: app, windowTitle: title,
                                             browserProfileLabel: app == "Chrome" ? "Work" : nil)
        var metadata = SessionMetadata(title: title, createdAt: createdAt, source: source,
                                       isolation: app == "Chrome" ? .browserExtension : .processTap, language: "en")
        metadata.endedAt = createdAt.addingTimeInterval(32 * 60)
        metadata.status = .ready
        metadata.summaryProvider = LLMProviderKind.claudeCLI.rawValue
        metadata.screenshotsCompacted = true
        guard let folder = try? store.createFolder(for: metadata) else { return }
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(
                speakerID: line.speaker == "me" ? Speaker.meID : line.speaker, track: line.speaker == "me" ? .me : .them,
                start: line.at, end: index + 1 < lines.count ? lines[index + 1].at - 0.5 : line.at + 6, text: line.text
            )
        }
        let transcript = Transcript(sessionID: metadata.id, speakers: speakers, segments: segments)
        try? store.save(metadata, in: folder)
        try? store.save(transcript, metadata: metadata, in: folder)
        if screenshot, let jpeg = slideJPEG() {
            let record = ScreenshotRecord(index: 1, offset: 26, relativePath: SessionFolder.screenshotRelativePath(index: 1, offset: 26),
                                          reason: .screenChange, ocrText: "Checkout success rate 3-D Secure Safari")
            try? FileManager.default.createDirectory(at: folder.screenshotsDirectory, withIntermediateDirectories: true)
            try? jpeg.write(to: folder.url.appending(path: record.relativePath))
            try? store.save([record], in: folder)
        }
        if !context.isEmpty { try? Data(context.utf8).write(to: folder.contextURL) }
        if let summary = try? JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8)) {
            try? store.save(summary, metadata: metadata, transcript: transcript, in: folder)
        }
    }

    static let checkoutSummary = #"""
    {
      "title": "Checkout sync",
      "tldr": "Yesterday's release broke checkout for cards that need 3-D Secure (about 4% of checkouts, mostly Safari): the bank redirect loses the session cookie. Alex fixes it by Thursday; the Friday beta stays, with the fix behind a flag.",
      "participants": [{"name": "Maria Silva", "role": "PM"}, {"name": "John Park", "role": "Payments"}, {"name": "Alex Morgan", "role": "Engineering lead"}],
      "decisions": [{"text": "Keep the beta on Friday, with the checkout fix behind a feature flag.", "ref": "00:00:45"}],
      "action_items": [
        {"owner": "Alex Morgan", "task": "Set SameSite=None on the session cookie and add a regression test", "due": "Thursday", "ref": "00:00:37"},
        {"owner": "John Park", "task": "Watch the payment dashboards over the weekend", "ref": "00:00:52"}
      ],
      "key_takeaways": ["The failures started with Tuesday's release and only affect 3-D Secure redirects."],
      "open_questions": ["Do other browsers drop the cookie in private mode?"],
      "risks": ["If the fix slips, the beta ships with failing 3-D Secure payments."],
      "topics": [{"title": "Checkout bug", "start": "00:00:02", "summary": "Cause found: the redirect loses the session cookie."}, {"title": "Friday beta", "start": "00:00:45", "summary": "Beta stays, fix behind a flag."}],
      "visual_context": [{"ref": "00:00:26", "screenshot": "screenshots/0001_00-00-26.jpg", "description": "Checkout success rate dropping for 3-D Secure payments on Safari."}],
      "my_questions_and_commitments": ["Alex: fix the 3-D Secure redirect and confirm by Thursday."]
    }
    """#

    /// A dashboard slide for the meeting's screenshot.
    static func slideJPEG() -> Data? {
        let size = NSSize(width: 1280, height: 720)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).setFill()
            rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor(white: 0.75, alpha: 1)]
            NSAttributedString(string: "Checkout success rate", attributes: title).draw(at: NSPoint(x: 70, y: 60))
            NSAttributedString(string: "3-D Secure payments · last 7 days", attributes: body).draw(at: NSPoint(x: 70, y: 125))
            let values: [CGFloat] = [0.97, 0.96, 0.97, 0.98, 0.81, 0.79, 0.80]
            for (index, value) in values.enumerated() {
                let height = (value - 0.6) / 0.4 * 380
                let bar = NSRect(x: 90 + CGFloat(index) * 160, y: 620 - height, width: 100, height: height)
                (value < 0.9 ? NSColor.systemRed : NSColor.systemGreen).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - Driving the live meeting

extension MeetingSession {
    /// Shows a line in the live transcript as if it had just been heard (the copilot hears it too).
    public func demoHear(_ text: String, speaker: String, at offset: TimeInterval) async {
        let isMe = speaker == "me"
        let segment = TranscriptSegment(speakerID: isMe ? Speaker.meID : "S1", track: isMe ? .me : .them,
                                        start: offset, end: offset + 4, text: text, isLive: true)
        await demoIngest(segment)
    }

    /// The meeting page's captions, as the extension reports them.
    public func demoCaptions(_ names: [String]) {
        recordSpeakerActivity(at: Date(), captions: names.enumerated().map { ("c\($0.offset)", $0.element, "…") }, speaking: names)
    }
}

// MARK: - Silent devices and a scripted AI

final class SilentMicrophone: MicrophoneSource, @unchecked Sendable {
    func subscribe() throws -> AsyncStream<MicrophoneCapture.Chunk> { AsyncStream { _ in } }
}

final class SilentRemoteAudio: RemoteAudioSource, @unchecked Sendable {
    let isolation: AudioIsolation = .browserExtension
    let gapTolerance: TimeInterval = 5
    func start(onSamples: @escaping @Sendable ([Float], Date) -> Void) async throws {}
    func stop() async {}
}

struct SilentASR: ASREngine {
    let id = "demo"
    func prepare() async throws {}
    func transcribe(samples: [Float], language: String?) async throws -> ASRTranscription { ASRTranscription(text: "", words: [], confidence: 1) }
    func transcribe(fileURL: URL, language: String?) async throws -> ASRTranscription { ASRTranscription(text: "", words: [], confidence: 1) }
}

struct SilentDiarizer: Diarizer {
    func prepare() async throws {}
    func diarize(fileURL: URL) async throws -> [DiarizedSpan] { [] }
}

/// Answers the copilot with prepared suggestions, streamed word by word like a real model.
struct ScriptedLLM: LLMProvider {
    let kind = LLMProviderKind.claudeCLI
    let capabilities: LLMCapabilities = [.streaming]
    let isSlow = false

    static let reply = """
    FOR_ME|yes
    OPTION|high|Yes — I'll own it. I can have the cookie fix and a regression test ready by Thursday.
    OPTION|medium|Yes, if John can pair on the 3-D Secure test cards tomorrow morning.
    OPTION|medium|I'll confirm by Wednesday whether it fits, and flag it right away if not.
    """

    func complete(_ request: LLMRequest) async throws -> LLMResponse { LLMResponse(text: Self.reply) }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for word in Self.reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(45))
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func checkAvailability() async -> LLMAvailability { .ready }
}
#endif
