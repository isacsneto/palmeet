import CaptureKit
import CopilotKit
import CoreGraphics
import Foundation
import LLMKit
import Observation
import os
import SessionKit
import TranscriptKit
import VisionContext

/// Shared services a session may use. Every call carries the session's own data, so nothing leaks between
/// sessions through them.
struct SessionServices: Sendable {
    let store: SessionStore
    let microphone: any MicrophoneSource
    let asr: any ASREngine
    let diarizer: any Diarizer
    let scheduler: ASRScheduler
    /// The library of learned voices.
    let voices: VoiceProfileStore
    let makeProvider: @Sendable (LLMProviderKind) -> any LLMProvider
    /// Which AI providers work right now, so a provider that doesn't is swapped for one that does.
    var providers = ProviderReadiness(hasAPIKey: { _ in true })
    /// Asks for microphone access when it hasn't been decided yet; false when denied.
    var ensureMicrophoneAccess: @Sendable () async -> Bool = {
        switch MicrophoneCapture.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await MicrophoneCapture.requestAccess()
        default: return false
        }
    }
}

/// One meeting being recorded (or already processed). Owns all of the meeting's capture, transcript, screenshot,
/// copilot and summary state; nothing here is shared with other sessions.
@MainActor
@Observable
public final class MeetingSession: Identifiable {
    public enum Stage: Equatable, Sendable {
        case recording
        case paused
        case finishing
        case transcribing(String)
        case summarizing
        case ready
        case failed(String)

        public var isCapturing: Bool { self == .recording || self == .paused }

        public var label: String {
            switch self {
            case .recording: "Recording"
            case .paused: "Paused"
            case .finishing: "Finishing…"
            case .transcribing(let step): step
            case .summarizing: "Writing summary…"
            case .ready: "Ready"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    public nonisolated let id: SessionID
    public private(set) var metadata: SessionMetadata
    public let folder: SessionFolder
    public private(set) var stage: Stage = .recording
    public private(set) var liveSegments: [TranscriptSegment] = []
    public private(set) var transcript: Transcript?
    public private(set) var summary: MeetingSummary?
    public private(set) var screenshots: [ScreenshotRecord] = []
    public private(set) var notes: [SessionNote] = []
    public private(set) var suggestions: [Suggestion] = []
    public private(set) var warnings: [String] = []
    public private(set) var themLevel: Float = 0
    public private(set) var meLevel: Float = 0
    public private(set) var isMicRouted = false
    public private(set) var copilotEnabled = false
    public private(set) var copilotUsage = LLMUsage()
    /// Manual mic routing override (nil = follow automatic routing).
    public var micOverride: Bool?
    /// From the browser extension / Accessibility, when known.
    public var knownMuted: Bool? {
        didSet {
            if oldValue == true, knownMuted == false { unmutedAt = clock.offset() }
        }
    }
    /// When the meeting last reported you unmuted (session offset); used to back-date the mic span.
    private var unmutedAt: TimeInterval?
    /// Mute is detected by polling (≈1 s), so you were already talking when it's noticed.
    static let unmuteLeadIn: TimeInterval = 1.5
    public var isPresenting: Bool?
    /// Captions and speaking indicators reported by the meeting page (browser tabs with the extension).
    public private(set) var speakerTimeline = MeetingSpeakerTimeline()
    private var timelineSavedAt: Date?
    public var meetingMode: MeetingMode
    /// What the user tells PalMeet about this meeting (agenda, ticket, who's who, terms), editable while it's
    /// recorded. The copilot uses it live; the summary and proofreading use it afterwards. Saved as context.md.
    public var context: String = "" {
        didSet {
            guard context != oldValue else { return }
            Task { await copilotEngine?.update(configuration: copilotConfiguration()) }
            scheduleContextSave()
        }
    }
    private var contextSaveTask: Task<Void, Never>?
    public var colorIndex: Int

    let clock: SessionClock
    let services: SessionServices
    let settings: () -> AppSettings
    private let remoteAudio: RemoteAudioSource?
    private var sampler: FrameProvider?
    private var themWriter: AudioTrackWriter?
    private var meWriter: AudioTrackWriter?
    private var tasks: [Task<Void, Never>] = []
    private var liveTasks: [Task<Void, Never>] = []
    private var copilotEngine: CopilotEngine?
    private var copilotEventsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var stopRequested = false
    private var lastKeptHash: UInt64?
    private var lastKeptOffset: TimeInterval?
    private var screenshotInFlight = false
    private let logger = Logger(subsystem: "app.palmeet", category: "Session")

    init(
        metadata: SessionMetadata,
        folder: SessionFolder,
        remoteAudio: RemoteAudioSource?,
        services: SessionServices,
        settings: @escaping () -> AppSettings,
        colorIndex: Int
    ) {
        self.id = metadata.id
        self.metadata = metadata
        self.folder = folder
        self.remoteAudio = remoteAudio
        self.services = services
        self.settings = settings
        self.colorIndex = colorIndex
        self.clock = SessionClock(start: metadata.createdAt)
        self.meetingMode = metadata.meetingMode.flatMap(MeetingMode.init(rawValue:)) ?? MeetingMode.guess(from: metadata.title)
    }

    /// A finished session loaded from disk (library).
    init(loadedFrom folder: SessionFolder, metadata: SessionMetadata, services: SessionServices, settings: @escaping () -> AppSettings) {
        self.id = metadata.id
        self.metadata = metadata
        self.folder = folder
        self.remoteAudio = nil
        self.services = services
        self.settings = settings
        self.colorIndex = 0
        self.clock = SessionClock(start: metadata.createdAt)
        self.meetingMode = metadata.meetingMode.flatMap(MeetingMode.init(rawValue:)) ?? .generic
        self.transcript = try? services.store.loadTranscript(in: folder)
        self.summary = try? services.store.loadSummary(in: folder)
        self.screenshots = services.store.loadScreenshots(in: folder)
        self.notes = services.store.loadNotes(in: folder)
        self.context = (try? String(contentsOf: folder.contextURL, encoding: .utf8)) ?? ""
        self.suggestions = (try? SessionStore.readJSON([Suggestion].self, from: folder.copilotURL)) ?? []
        self.speakerTimeline = (try? SessionStore.readJSON(MeetingSpeakerTimeline.self, from: folder.meetingSpeakersURL)) ?? MeetingSpeakerTimeline()
        switch metadata.status {
        case .ready: stage = .ready
        case .failed: stage = .failed(metadata.lastError ?? "Unknown error")
        default: stage = .failed("Interrupted (the app quit while recording or processing).")
        }
    }

    public var title: String { metadata.title }
    public var elapsed: TimeInterval { stage.isCapturing ? clock.offset() : (metadata.duration ?? transcript?.duration ?? 0) }

    /// Transcript to show: final when available, live otherwise.
    public var displaySegments: [TranscriptSegment] { transcript?.segments ?? liveSegments }

    public func displayName(for speakerID: String) -> String {
        if let transcript { return transcript.displayName(for: speakerID) }
        if speakerID == Speaker.meID { return meName }
        return "Participant"
    }

    var meName: String {
        let name = settings().profile.name
        return name.split(separator: " ").first.map(String.init) ?? (name.isEmpty ? "Me" : name)
    }

    // MARK: - Lifecycle

    private func makeWindowSampler(_ windowID: CGWindowID) -> FrameProvider {
        WindowFrameSampler(windowID: windowID, maxWidth: 1600, frameInterval: 1) { [weak self] error in
            Task { @MainActor in self?.warn("Window capture stopped: \(error?.localizedDescription ?? "window closed")") }
        }
    }

    /// Starts capture. `frames` overrides the default window sampler (browser tabs stream their own frames).
    /// A `stop()` that arrives while starting waits for start to finish, then tears everything down.
    func start(windowID: CGWindowID?, frames: FrameProvider? = nil) async {
        let task = Task { await performStart(windowID: windowID, frames: frames) }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart(windowID: CGWindowID?, frames: FrameProvider?) async {
        let settings = settings()
        do {
            try folder.createDirectories()
            if let remoteAudio {
                let writer = try AudioTrackWriter(url: folder.audioURL(for: .them), gapTolerance: remoteAudio.gapTolerance)
                themWriter = writer
                let clock = self.clock
                try await remoteAudio.start { samples, time in
                    guard !clock.isPaused else { return }
                    writer.append(samples, at: clock.offset(at: time))
                }
            }
        } catch {
            warn("Remote audio could not start: \(error.localizedDescription)")
        }

        if metadata.includesMicrophone {
            if await services.ensureMicrophoneAccess() {
                startMicrophone()
            } else {
                warn("Microphone access is off, so your voice isn't recorded. Enable PalMeet in System Settings → Privacy & Security → Microphone.")
            }
        }

        if let frames = frames ?? windowID.map(makeWindowSampler) {
            do {
                try await frames.start()
                self.sampler = frames
            } catch {
                warn("Screenshots unavailable: \(error.localizedDescription)")
            }
        }

        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        })

        if settings.liveTranscription { startLiveTranscription() }
        if settings.copilot.autoEnableModes.contains(meetingMode), !stopRequested { setCopilot(enabled: true) }
        persistMetadata()
    }

    private func startMicrophone() {
        do {
            let writer = try AudioTrackWriter(url: folder.audioURL(for: .me), gapTolerance: 0.2)
            meWriter = writer
            let stream = try services.microphone.subscribe()
            let clock = self.clock
            tasks.append(Task.detached(priority: .userInitiated) {
                for await chunk in stream {
                    guard !clock.isPaused else { continue }
                    writer.append(chunk.samples, at: clock.offset(at: chunk.time))
                }
            })
        } catch {
            warn("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    public func pause() {
        guard stage == .recording else { return }
        clock.pause()
        metadata.pausedSpans.append(MicRouteSpan(start: clock.offset()))
        stage = .paused
        persistMetadata()
    }

    public func resume() {
        guard stage == .paused else { return }
        if var last = metadata.pausedSpans.popLast() {
            last.end = clock.offset()
            metadata.pausedSpans.append(last)
        }
        clock.resume()
        stage = .recording
        persistMetadata()
    }

    /// Stops capture and (by default) runs the final transcription + summary pipeline. On app quit the pipeline is
    /// skipped; the session can be processed later from the library.
    func stop(processAfterwards: Bool = true) async {
        guard stage.isCapturing, !stopRequested else { return }
        stopRequested = true
        if let startTask { await startTask.value }
        if stage == .paused { resume() }
        stage = .finishing
        setMicRouted(false)
        setCopilot(enabled: false)
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        stopLiveTranscription()
        await sampler?.stop()
        sampler = nil
        await remoteAudio?.stop()
        themWriter?.finish()
        meWriter?.finish()
        metadata.endedAt = Date()
        metadata.status = .processing
        speakerTimeline.finish(at: clock.offset())
        saveSpeakerTimeline()
        persistMetadata()
        persistSecondaryFiles()
        if processAfterwards {
            await process()
        } else {
            stage = .failed("Not transcribed yet (PalMeet quit during the meeting).")
        }
    }

    /// Shown while an imported recording waits to be processed.
    func markQueued() {
        stage = .transcribing("Queued…")
    }

    /// Processes an imported recording (audio and screenshots already written to the folder).
    public func processImport() async {
        stage = .transcribing("Preparing…")
        await process()
    }

    /// Runs transcription + summary again from the saved audio (interrupted or failed sessions).
    public func reprocess() async {
        guard !stage.isCapturing else { return }
        await process()
    }

    // MARK: - Who is speaking (meeting page)

    /// Captions / speaking indicators from the meeting page. Ignored while paused (that audio isn't recorded).
    func recordSpeakerActivity(at date: Date, captions: [(id: String, name: String?, text: String)], speaking: [String]?) {
        guard stage == .recording else { return }
        // Page reads carry the browser's clock, like the tab's audio frames, so both land on the same timeline.
        let offset = clock.offset(at: min(date, Date().addingTimeInterval(120)))
        for caption in captions {
            speakerTimeline.recordCaption(id: caption.id, name: caption.name, text: caption.text, at: offset)
        }
        speakerTimeline.recordSpeaking(speaking, at: offset)
        if timelineSavedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            saveSpeakerTimeline()
        }
    }

    private func saveSpeakerTimeline() {
        guard !speakerTimeline.isEmpty else { return }
        timelineSavedAt = Date()
        try? SessionStore.writeJSON(speakerTimeline, to: folder.meetingSpeakersURL)
    }

    /// Diagnostics about the meeting page, appended to `page-diagnostics.jsonl` in the session folder.
    func recordPageDiagnostics(_ payload: Data, at date: Date) {
        guard stage.isCapturing, let json = String(data: payload, encoding: .utf8) else { return }
        let line = #"{"offset":\#(Int(clock.offset(at: date))),"payload":\#(json)}"# + "\n"
        let url = folder.pageDiagnosticsURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    /// For the live view: whether the meeting is telling PalMeet who is talking.
    public var meetingSpeakerStatus: String? {
        guard metadata.source.kind == .browserTab else { return nil }
        let names = speakerTimeline.names
        if !speakerTimeline.captions.isEmpty {
            return "Names from the meeting's captions: \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? " +\(names.count - 4)" : "")"
        }
        if !names.isEmpty {
            return "Speaking indicators seen for \(names.prefix(4).joined(separator: ", "))"
        }
        return elapsed > 60 ? "Turn on live captions in the meeting (CC) so PalMeet knows exactly who said what." : nil
    }

    // MARK: - Periodic work

    private func tick() async {
        themLevel = themWriter?.level ?? 0
        meLevel = isMicRouted ? (meWriter?.level ?? 0) : 0
        guard stage == .recording else { return }
        await sampleScreenshot(reason: nil)
    }

    // MARK: - Screenshots

    public func markMoment() async {
        guard stage.isCapturing else { return }
        guard let sampler else {
            warn("No window is being captured for this session.")
            return
        }
        do {
            let image = try await sampler.captureNow()
            await keepScreenshot(WindowFrameSampler.Frame(image: image, time: Date()), reason: .manual)
        } catch {
            warn("Screenshot failed: \(error.localizedDescription)")
        }
    }

    private func sampleScreenshot(reason forced: ScreenshotRecord.Reason?) async {
        guard !screenshotInFlight, let frame = sampler?.latestFrame else { return }
        let settings = settings()
        let policy = FrameKeepPolicy(changeThreshold: settings.screenshotChangeThreshold, maxInterval: settings.screenshotInterval)
        let offset = clock.offset()
        let image = UncheckedImage(image: frame.image)
        let hash = await Task.detached(priority: .utility) { PerceptualHash.dHash(image.image) }.value
        switch policy.decide(hash: hash, at: offset, lastKeptHash: lastKeptHash, lastKeptTime: lastKeptOffset) {
        case .skip: return
        case .keepInterval: await keepScreenshot(frame, reason: forced ?? .interval, hash: hash)
        case .keepChange: await keepScreenshot(frame, reason: forced ?? .screenChange, hash: hash)
        }
    }

    private func keepScreenshot(_ frame: WindowFrameSampler.Frame, reason: ScreenshotRecord.Reason, hash knownHash: UInt64? = nil) async {
        screenshotInFlight = true
        defer { screenshotInFlight = false }
        let offset = clock.offset()
        let index = screenshots.count + 1
        let relativePath = SessionFolder.screenshotRelativePath(index: index, offset: offset)
        let url = folder.url.appending(path: relativePath)
        let image = UncheckedImage(image: frame.image)

        let result = await Task.detached(priority: .utility) { () -> (UInt64, OCRResult?, Bool) in
            let hash = knownHash ?? PerceptualHash.dHash(image.image)
            var saved = false
            if let data = ImageEncoding.jpegData(image.image) {
                saved = (try? data.write(to: url, options: .atomic)) != nil
            }
            let ocr = try? TextRecognizer.recognize(image.image)
            return (hash, ocr, saved)
        }.value

        guard result.2 else { return }
        lastKeptHash = result.0
        lastKeptOffset = offset
        let record = ScreenshotRecord(
            index: index,
            offset: offset,
            relativePath: relativePath,
            reason: reason,
            ocrText: result.1?.text ?? "",
            nameCandidates: result.1?.nameCandidates ?? [],
            perceptualHash: result.0
        )
        screenshots.append(record)
        try? services.store.save(screenshots, in: folder)
        if let engine = copilotEngine, !record.ocrText.isEmpty {
            await engine.updateScreenText(record.ocrText)
        }
    }

    // MARK: - Notes

    public func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(SessionNote(offset: clock.offset(), text: trimmed))
        try? services.store.save(notes, in: folder)
    }

    // MARK: - Mic routing

    /// Called by the SessionManager's router; records routing spans in session time.
    func setMicRouted(_ routed: Bool) {
        guard metadata.includesMicrophone, routed != isMicRouted else { return }
        let offset = clock.offset()
        if routed {
            var start = offset
            if let unmutedAt, offset - unmutedAt < 3 {
                // Unmuted just now: include the words spoken before the poll noticed, never overlapping the last span.
                start = max(unmutedAt - Self.unmuteLeadIn, metadata.micRouting.last?.end ?? 0, 0)
            }
            unmutedAt = nil
            metadata.micRouting.append(MicRouteSpan(start: start))
        } else if var last = metadata.micRouting.popLast() {
            last.end = offset
            metadata.micRouting.append(last)
        }
        isMicRouted = routed
    }

    // MARK: - Live transcription

    private var liveTranscriptionRunning: Bool { !liveTasks.isEmpty }

    func startLiveTranscription() {
        guard !liveTranscriptionRunning, stage.isCapturing else { return }
        let language = settings().language
        let scheduler = services.scheduler
        let engine = services.asr
        let copilotPriority: @Sendable () -> Int = { [weak self] in
            // Read on a background thread; a stale value only affects ordering.
            (self?.copilotFlag.withLock { $0 } ?? false) ? 0 : 10
        }
        for (track, writer) in [(Track.them, themWriter), (Track.me, meWriter)] {
            guard let writer else { continue }
            let transcriber = LiveTranscriber(
                track: track,
                speakerID: track == .me ? Speaker.meID : TranscriptAssembler.unknownRemoteID,
                engine: engine,
                scheduler: scheduler,
                language: language,
                priority: copilotPriority
            )
            let chunks = AsyncStream<PCMChunk> { continuation in
                let source = writer.chunks()
                let forward = Task.detached {
                    for await chunk in source {
                        continuation.yield(PCMChunk(samples: chunk.samples, startOffset: chunk.startOffset))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in forward.cancel() }
            }
            let events = transcriber.events(from: chunks)
            liveTasks.append(Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    if case .segment(let segment) = event {
                        await self.handleLive(segment)
                    }
                }
            })
        }
    }

    private func stopLiveTranscription() {
        liveTasks.forEach { $0.cancel() }
        liveTasks.removeAll()
    }

    private func handleLive(_ segment: TranscriptSegment) async {
        // Your words only belong to this meeting while the mic is routed here.
        if segment.track == .me {
            let mid = (segment.start + segment.end) / 2
            guard metadata.micRouting.contains(where: { $0.contains(mid) }) else { return }
        }
        liveSegments.append(segment)
        if let engine = copilotEngine {
            await engine.ingest(segment, speakerName: displayName(for: segment.speakerID))
        }
    }

    // MARK: - Copilot (strict on/off)

    /// Mirrors `copilotEnabled` for background readers (ASR priority).
    nonisolated let copilotFlag = OSAllocatedUnfairLock(initialState: false)

    public func setCopilot(enabled: Bool) {
        guard enabled != copilotEnabled else { return }
        if enabled {
            guard stage.isCapturing else { return }
            if !liveTranscriptionRunning { startLiveTranscription() }
            let settings = settings()
            let provider = services.makeProvider(settings.workingProvider(settings.copilotProvider, ready: services.providers.isReady))
            let engine = CopilotEngine(provider: provider, configuration: copilotConfiguration(), now: { [clock] in clock.offset() })
            copilotEngine = engine
            copilotEnabled = true
            copilotFlag.withLock { $0 = true }
            let priming = liveSegments.map { (speaker: displayName(for: $0.speakerID), segment: $0) }
            copilotEventsTask = Task { [weak self] in
                await engine.start(priming: priming)
                for await event in engine.events {
                    self?.handleCopilot(event)
                }
            }
        } else {
            // Tear down immediately: cancels in-flight requests; no further provider calls can happen.
            let engine = copilotEngine
            copilotEngine = nil
            copilotEnabled = false
            copilotFlag.withLock { $0 = false }
            copilotEventsTask?.cancel()
            copilotEventsTask = nil
            Task { await engine?.shutdown() }
            // In-flight cards will never finish now; don't leave spinners behind.
            for index in suggestions.indices where suggestions[index].status == .streaming {
                suggestions[index].status = suggestions[index].items.isEmpty ? .failed : .ready
            }
            saveSuggestions()
            if !settings().liveTranscription { stopLiveTranscription() }
        }
    }

    public func toggleCopilot() {
        setCopilot(enabled: !copilotEnabled)
    }

    public func copilotHelpNow() {
        guard let engine = copilotEngine else { return }
        Task { await engine.helpNow() }
    }

    /// Cards in display order: pinned first, then newest first; dismissed and empty cards hidden.
    public var visibleCards: [Suggestion] {
        let visible = suggestions.filter { $0.status != .dismissed && !$0.items.isEmpty }
        return visible.filter { $0.status == .pinned } + visible.filter { $0.status != .pinned }.reversed()
    }

    /// The card the copy hotkeys act on (the focused one, clamped), never a reminder.
    public func copyTarget(focusedIndex: Int) -> Suggestion? {
        let cards = visibleCards
        guard !cards.isEmpty else { return nil }
        let card = cards[min(max(0, focusedIndex), cards.count - 1)]
        return card.kind == .reminder ? nil : card
    }

    public func updateSuggestion(_ id: UUID, status: Suggestion.Status? = nil, feedback: Int? = nil) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        if let status { suggestions[index].status = status }
        if let feedback { suggestions[index].feedback = feedback }
        saveSuggestions()
    }

    private func handleCopilot(_ event: CopilotEvent) {
        switch event {
        case .suggestion(let suggestion):
            if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
                // Keep user-set status (pinned/used/dismissed) when late deltas arrive.
                let userStatus = suggestions[index].status
                suggestions[index] = suggestion
                if [.pinned, .used, .dismissed].contains(userStatus) { suggestions[index].status = userStatus }
            } else {
                suggestions.append(suggestion)
            }
            if suggestion.status == .ready { saveSuggestions() }
        case .usage(let usage):
            copilotUsage.inputTokens += usage.inputTokens
            copilotUsage.outputTokens += usage.outputTokens
            copilotUsage.cacheReadTokens += usage.cacheReadTokens
        case .error(let message):
            warn("Copilot: \(message)")
        }
    }

    func copilotConfiguration() -> CopilotConfiguration {
        let settings = settings()
        let providerConfig = settings.providerConfig(settings.workingProvider(settings.copilotProvider, ready: services.providers.isReady))
        return CopilotConfiguration(
            profile: settings.profile,
            mode: meetingMode,
            playbook: settings.copilot.playbook(for: meetingMode),
            prepNotes: context,
            meetingTitle: metadata.title,
            model: providerConfig.fastModel.isEmpty ? nil : providerConfig.fastModel,
            proactiveQuestions: settings.copilot.proactiveQuestions,
            proactiveInterval: settings.copilot.proactiveInterval,
            maxCallsPerMinute: settings.copilot.maxCallsPerMinute,
            remindUnanswered: metadata.includesMicrophone
        )
    }

    /// Pushes changed settings (profile, playbooks, limits) to a running copilot.
    func refreshCopilotConfiguration() {
        guard let engine = copilotEngine else { return }
        let configuration = copilotConfiguration()
        Task { await engine.update(configuration: configuration) }
    }

    public func setMeetingMode(_ mode: MeetingMode) {
        meetingMode = mode
        metadata.meetingMode = mode.rawValue
        persistMetadata()
        Task { await copilotEngine?.update(configuration: copilotConfiguration()) }
    }

    // MARK: - Post-processing

    private func process() async {
        let settings = settings()
        do {
            let finalTranscript = try await transcribeFinal(settings: settings)
            transcript = finalTranscript
            try services.store.save(finalTranscript, metadata: metadata, in: folder)

            if !settings.privacy.keepUnroutedMicAudio, metadata.includesMicrophone {
                stage = .transcribing("Removing mic audio routed to other meetings…")
                let url = folder.audioURL(for: .me)
                let routing = metadata.micRouting
                try? await Task.detached { try AudioRedaction.silence(url, keeping: routing) }.value
            }
        } catch {
            fail("Transcription failed: \(error.localizedDescription)")
            return
        }
        await summarize(using: settings.workingProvider(settings.summaryProvider, ready: services.providers.isReady), proofread: settings.aiTranscriptCorrection)
    }

    /// Shorter tracks hold no speech worth a model run (the ASR pads short audio itself).
    static let minimumTranscribableAudio: TimeInterval = 0.25

    private func transcribeFinal(settings: AppSettings) async throws -> Transcript {
        let language = settings.language
        let asr = services.asr
        let scheduler = services.scheduler

        stage = .transcribing("Loading speech model…")
        try await asr.prepare()

        var themWords: [TranscriptWord] = []
        let themURL = folder.audioURL(for: .them)
        if AudioRedaction.duration(of: themURL) > Self.minimumTranscribableAudio {
            stage = .transcribing("Transcribing participants…")
            themWords = try await scheduler.run(priority: 100) { try await asr.transcribe(fileURL: themURL, language: language).words }
        }

        var meWords: [TranscriptWord] = []
        let meURL = folder.audioURL(for: .me)
        if metadata.includesMicrophone, AudioRedaction.duration(of: meURL) > Self.minimumTranscribableAudio {
            stage = .transcribing("Transcribing your microphone…")
            meWords = try await scheduler.run(priority: 100) { try await asr.transcribe(fileURL: meURL, language: language).words }
        }

        var diarization = DiarizationOutput(spans: [])
        if !themWords.isEmpty {
            stage = .transcribing("Identifying speakers…")
            let diarizer = services.diarizer
            do {
                diarization = try await scheduler.run(priority: 100) { try await diarizer.diarizeWithVoiceprints(fileURL: themURL) }
            } catch {
                warn("Speaker separation failed; remote speech is labelled as one speaker. (\(error.localizedDescription))")
            }
        }

        // Who spoke: the meeting's own captions/speaking indicators first, then voices learned in earlier meetings,
        // then the diarizer's clusters. Remaining speakers are named by the summarizer from what people say.
        let knownVoices = settings.recognizeVoices ? services.voices.load() : []
        let assembled = TranscriptAssembler.assembleDetailed(
            sessionID: id,
            input: .init(
                themWords: themWords, meWords: meWords, diarization: diarization.spans, micRouting: metadata.micRouting,
                meName: meName, timeline: speakerTimeline.isEmpty ? nil : speakerTimeline,
                voiceprints: diarization.voiceprints, knownVoices: knownVoices
            )
        )
        if !assembled.voices.isEmpty {
            try? SessionStore.writeJSON(assembled.voices, to: folder.speakerVoicesURL)
        }
        if settings.recognizeVoices {
            for speakerID in assembled.learnableVoices.sorted() {
                guard let voice = assembled.voices[speakerID], voice.seconds >= VoiceMatcher.Thresholds().minimumSeconds,
                      let speaker = assembled.transcript.speaker(speakerID)
                else { continue }
                try? services.voices.learn(name: speaker.displayName, voice: voice, sessionID: id.uuidString)
            }
        }
        let recognized = assembled.transcript.speakers.filter { $0.nameSource == "voice" }.map(\.displayName)
        if !recognized.isEmpty {
            logger.info("Recognized by voice: \(recognized.joined(separator: ", "), privacy: .private)")
        }
        return assembled.transcript
    }

    /// Voiceprints of this meeting's remote speakers.
    private func speakerVoices() -> [String: SpeakerVoice] {
        (try? SessionStore.readJSON([String: SpeakerVoice].self, from: folder.speakerVoicesURL)) ?? [:]
    }

    /// Naming a speaker teaches PalMeet their voice (when the speaker talked long enough to be recognizable).
    private func learnVoice(of speakerID: String, as name: String) {
        guard settings().recognizeVoices, !name.isEmpty, speakerID != Speaker.meID,
              let voice = speakerVoices()[speakerID], voice.seconds >= VoiceMatcher.Thresholds().minimumSeconds
        else { return }
        try? services.voices.learn(name: name, voice: voice, sessionID: id.uuidString)
    }

    /// Generates (or regenerates) the summary with the given provider. Transcript edits and speaker renames made
    /// while the model is writing are kept and applied to the new summary. With `proofread`, the same provider
    /// also corrects misheard words in the transcript (in parallel, so it adds no waiting time).
    public func summarize(using kind: LLMProviderKind, model: String? = nil, proofread: Bool = false) async {
        guard let snapshot = transcript else { return }
        let settings = settings()
        stage = .summarizing
        let provider = services.makeProvider(kind)
        let config = settings.providerConfig(kind)
        var summarizer = Summarizer(provider: provider, model: model ?? (config.model.isEmpty ? nil : config.model))
        if kind == .localOpenAICompatible {
            // Local models have small context windows: summarize in chunks much earlier.
            summarizer.singlePassLimit = 40_000
            summarizer.chunkDuration = 10 * 60
        }
        let requestNames = Dictionary(snapshot.speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let corrector = TranscriptCorrector(provider: provider, model: summarizer.model)
        let screenNames = Array(Set(screenshots.flatMap(\.nameCandidates))).sorted()
        let title = metadata.title
        let glossary = settings.glossary
        let context = context
        // Best effort: a failed proofreading pass never blocks the summary.
        async let proofreading: [TranscriptCorrector.Fix] = proofread
            ? ((try? await corrector.corrections(transcript: snapshot, glossary: glossary, screenNames: screenNames, title: title, context: context)) ?? [])
            : []
        do {
            let output = try await summarizer.summarize(
                metadata: metadata, transcript: snapshot, screenshots: screenshots,
                notes: notes, folder: folder, glossary: settings.glossary, context: context
            )
            var current = transcript ?? snapshot
            let fixes = await proofreading
            if !fixes.isEmpty {
                let applied = TranscriptCorrector.apply(fixes, to: &current)
                logger.info("Proofreading fixed \(applied, privacy: .public) of \(fixes.count, privacy: .public) proposed words")
            }
            // LLM-proposed names never override names the user set.
            // …nor names the meeting itself or a known voice gave.
            for (speakerID, name) in output.speakerNames where !Self.authoritativeNameSources.contains(current.speaker(speakerID)?.nameSource ?? "") {
                current.renameSpeaker(speakerID, to: name, source: "transcript")
            }
            var newSummary = output.summary
            for speaker in current.speakers where speaker.nameSource == "user" {
                if let old = requestNames[speaker.id], old != speaker.displayName {
                    newSummary = newSummary.replacingName(old, with: speaker.displayName)
                }
            }
            transcript = current
            summary = newSummary
            if metadata.title == "Meeting" || metadata.title.isEmpty, !newSummary.title.isEmpty {
                metadata.title = newSummary.title
            }
            metadata.summaryProvider = kind.rawValue
            metadata.summaryModel = summarizer.model
            metadata.status = .ready
            metadata.lastError = nil
            try services.store.save(current, metadata: metadata, in: folder)
            try services.store.save(newSummary, metadata: metadata, transcript: current, in: folder)
            persistMetadata()
            stage = .ready
        } catch {
            // The transcript is already saved; the summary can be regenerated from the review screen.
            let fixes = await proofreading
            if !fixes.isEmpty, var current = transcript {
                TranscriptCorrector.apply(fixes, to: &current)
                transcript = current
                try? services.store.save(current, metadata: metadata, in: folder)
            }
            metadata.status = .ready
            metadata.lastError = "Summary failed: \(error.localizedDescription)"
            persistMetadata()
            warn(metadata.lastError ?? "")
            stage = .ready
        }
    }

    /// Name sources the summarizer's guesses never override.
    static let authoritativeNameSources: Set<String> = ["user", "meeting", "voice"]

    // MARK: - Review edits

    /// Renames a speaker everywhere, including the summary text ("Speaker 2" → "John Park").
    public func renameSpeaker(_ speakerID: String, to name: String) {
        guard var transcript else { return }
        let oldName = transcript.displayName(for: speakerID)
        transcript.renameSpeaker(speakerID, to: name)
        self.transcript = transcript
        learnVoice(of: speakerID, as: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if let summary, oldName != name, !oldName.isEmpty {
            self.summary = Self.replacingName(oldName, with: name, in: summary)
        }
        saveTranscriptAndSummary()
    }

    nonisolated static func replacingName(_ old: String, with new: String, in summary: MeetingSummary) -> MeetingSummary {
        summary.replacingName(old, with: new)
    }

    public func editSegment(_ segmentID: UUID, text: String) {
        guard var transcript, let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        transcript.segments[index].text = text
        transcript.segments[index].isEdited = true
        self.transcript = transcript
        saveTranscriptAndSummary()
    }

    public func reassignSegment(_ segmentID: UUID, to speakerID: String) {
        guard var transcript else { return }
        transcript.reassign(segment: segmentID, to: speakerID)
        self.transcript = transcript
        saveTranscriptAndSummary()
    }

    private func saveTranscriptAndSummary() {
        guard let transcript else { return }
        try? services.store.save(transcript, metadata: metadata, in: folder)
        if let summary {
            try? services.store.save(summary, metadata: metadata, transcript: transcript, in: folder)
        }
    }

    // MARK: - Persistence

    func addConcurrent(_ other: SessionID) {
        guard !metadata.concurrentWith.contains(other) else { return }
        metadata.concurrentWith.append(other)
        persistMetadata()
    }

    private func persistMetadata() {
        try? services.store.save(metadata, in: folder)
    }

    private func persistSecondaryFiles() {
        try? services.store.save(screenshots, in: folder)
        try? services.store.save(notes, in: folder)
        saveContext()
        saveSuggestions()
    }

    /// Typing saves a moment after the last keystroke.
    private func scheduleContextSave() {
        contextSaveTask?.cancel()
        contextSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveContext()
        }
    }

    private func saveContext() {
        contextSaveTask?.cancel()
        let text = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            try? FileManager.default.removeItem(at: folder.contextURL)
        } else {
            try? Data((text + "\n").utf8).write(to: folder.contextURL, options: .atomic)
        }
    }

    private func saveSuggestions() {
        guard !suggestions.isEmpty else { return }
        try? SessionStore.writeJSON(suggestions, to: folder.copilotURL)
    }

    func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        if warnings.last != message { warnings.append(message) }
    }

    private func fail(_ message: String) {
        metadata.status = .failed
        metadata.lastError = message
        persistMetadata()
        stage = .failed(message)
    }
}

/// CGImage is immutable and thread-safe; this lets it cross into detached tasks.
struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
}
