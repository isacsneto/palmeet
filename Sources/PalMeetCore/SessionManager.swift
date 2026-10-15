import AppKit
import BrowserBridge
import CaptureKit
import CoreGraphics
import Foundation
import LLMKit
import Observation
import os
import SessionKit
import TranscriptKit

/// What the user picked in the source picker.
public enum SourceChoice: Sendable, Hashable, Identifiable {
    case window(CapturableWindow)
    /// A meeting tab captured through the extension. `scWindowID` is the matching on-screen window for screenshots.
    case browserTab(profile: BrowserProfile, window: BrowserWindow, tab: BrowserTab, scWindowID: CGWindowID?)

    public var id: String {
        switch self {
        case .window(let window): "window-\(window.id)"
        case .browserTab(let profile, let window, let tab, _): "tab-\(profile.id)-\(window.windowID)-\(tab.tabID)"
        }
    }

    public var title: String {
        switch self {
        case .window(let window): window.title.isEmpty ? window.appName : window.title
        case .browserTab(_, _, let tab, _): tab.title
        }
    }
}

/// How well a source's audio can be separated from other sessions, shown in the picker before starting.
public enum IsolationPreview: Equatable, Sendable {
    case isolated(String)
    /// Browser window without the extension while another session uses the same browser.
    case needsExtension(String)
    /// Would capture audio already captured by another session.
    case shared(conflictsWith: String)

    public var symbol: String {
        switch self {
        case .isolated: "✅"
        case .needsExtension: "🧩"
        case .shared: "⚠️"
        }
    }

    public var explanation: String {
        switch self {
        case .isolated(let how): "Isolated · \(how)"
        case .needsExtension(let detail): detail
        case .shared(let other): "Shares audio with “\(other)”. Use the browser extension or another app to keep them separate."
        }
    }
}

/// A call app on this Mac that PalMeet isn't recording but that is using the microphone (e.g. Teams while you
/// record a Google Meet). `muted` comes from Accessibility when available.
public struct OtherCall: Equatable, Sendable {
    public var appName: String
    public var muted: Bool?

    public init(appName: String, muted: Bool?) {
        self.appName = appName
        self.muted = muted
    }
}

public enum SessionError: Error, LocalizedError {
    case tooManySessions(Int)
    case alreadyRecording(String)

    public var errorDescription: String? {
        switch self {
        case .tooManySessions(let max): "You're already recording \(max) meetings (the limit is set in Settings)."
        case .alreadyRecording(let title): "“\(title)” is already being recorded."
        }
    }
}

@MainActor
@Observable
public final class SessionManager {
    public private(set) var settings: AppSettings
    public private(set) var activeSessions: [MeetingSession] = []
    /// Sessions finished during this app run plus those loaded from disk, newest first.
    public internal(set) var library: [MeetingSession] = []
    public private(set) var browserProfiles: [BrowserProfile] = []
    public private(set) var bridgePort: UInt16?
    /// Call apps not recorded by PalMeet that are using the mic (refreshed every 2 s while recording with the mic).
    public internal(set) var otherCalls: [OtherCall] = []
    public private(set) var lastUsedSessionID: SessionID?

    public let secrets: SecretStore
    @ObservationIgnored let services: SessionServices
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored public let bridge: BrowserBridgeServer
    @ObservationIgnored private var routingTask: Task<Void, Never>?
    @ObservationIgnored private var bridgeTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "app.palmeet", category: "SessionManager")
    @ObservationIgnored private var colorCounter = 0
    @ObservationIgnored private var pendingAdoptions: Set<SessionID> = []

    public convenience init(settingsStore: SettingsStore = SettingsStore(), secrets: SecretStore = KeychainSecretStore()) {
        let settings = settingsStore.load()
        let box = SettingsBox(settings)
        let store = SessionStore(rootURL: settings.storageRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SessionStore.defaultRootURL)
        let services = SessionServices(
            store: store,
            microphone: MicrophoneCapture(),
            asr: ParakeetEngine(model: ParakeetEngine.Model(rawValue: settings.asrModel) ?? .ultra),
            diarizer: OfflineSpeakerDiarizer(),
            scheduler: ASRScheduler(),
            voices: VoiceProfileStore(),
            makeProvider: { kind in
                LLMProviderFactory.make(config: box.value.providerConfig(kind), secrets: secrets)
            },
            providers: ProviderReadiness(hasAPIKey: { secrets.apiKey(for: $0) != nil })
        )
        self.init(settingsStore: settingsStore, secrets: secrets, settingsBox: box, services: services, bridge: BrowserBridgeServer())
    }

    /// Designated initializer; tests inject fake services and a private bridge.
    init(settingsStore: SettingsStore, secrets: SecretStore, settingsBox: SettingsBox, services: SessionServices, bridge: BrowserBridgeServer) {
        self.settings = settingsBox.value
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settingsBox = settingsBox
        self.services = services
        self.bridge = bridge
    }

    /// Thread-safe snapshot of settings for background provider construction.
    @ObservationIgnored let settingsBox: SettingsBox

    public func start() {
        bridge.setPageDiagnostics(settings.meetingPageDiagnostics)
        Task { await refreshProviders() }
        do {
            try bridge.start()
            bridgePort = bridge.port
        } catch {
            logger.error("Browser bridge failed to start: \(error.localizedDescription, privacy: .public)")
        }
        let events = bridge.events()
        bridgeTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        routingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                if tick.isMultiple(of: 2) { await self?.refreshDesktopMeetingStates() }
                // The app runs for days: delete expired audio without waiting for a relaunch.
                if tick.isMultiple(of: 6 * 3_600) { self?.applyRetentionPolicy() }
                self?.updateMicRouting()
            }
        }
        refreshLibrary()
        applyRetentionPolicy()
        tidyLibrary()
    }

    /// Meetings recorded before screenshots were compacted and audio compressed get the same treatment once,
    /// one at a time in the background.
    func tidyLibrary() {
        let pending = library.filter { session in
            session.metadata.status == .ready
                && ((settings.compactScreenshots && session.metadata.screenshotsCompacted != true)
                    || (settings.audioStorage != .original && session.metadata.audioCompressed != true))
        }
        guard !pending.isEmpty else { return }
        Task(priority: .background) {
            for session in pending {
                await session.compactScreenshots()
                await session.compressAudio()
            }
        }
    }

    /// Deletes audio (keeping transcripts, summaries and screenshots) of sessions older than the configured age.
    func applyRetentionPolicy() {
        guard let days = settings.privacy.deleteAudioAfterDays, days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for session in library where session.metadata.createdAt < cutoff && session.metadata.status == .ready {
            try? FileManager.default.removeItem(at: session.folder.audioDirectory)
        }
    }

    /// Finalizes every recording's files without transcribing (app quit).
    public func shutdown() async {
        for session in activeSessions {
            activeSessions.removeAll { $0.id == session.id }
            await session.stop(processAfterwards: false)
        }
        routingTask?.cancel()
        bridgeTask?.cancel()
        bridge.stop()
    }

    // MARK: - Settings

    /// Applies a change and persists it. A no-op when nothing changes: SwiftUI bindings may write back the
    /// same value on every render, and re-publishing settings would re-render every view in a loop.
    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        settings = updated
        settingsStore.save(updated)
        settingsBox.value = updated
        bridge.setPageDiagnostics(updated.meetingPageDiagnostics)
        activeSessions.forEach { $0.refreshCopilotConfiguration() }
    }

    public func provider(_ kind: LLMProviderKind) -> any LLMProvider {
        services.makeProvider(kind)
    }

    /// Last check of each provider (Settings shows it; failures make PalMeet use one that works).
    public private(set) var providerStatus: [LLMProviderKind: LLMAvailability] = [:]

    /// Checks every provider (CLI installed and logged in, API key saved, local server up), all at once.
    public func refreshProviders() async {
        let results = await withTaskGroup(of: (LLMProviderKind, LLMAvailability).self) { group in
            for kind in LLMProviderKind.allCases {
                let provider = services.makeProvider(kind)
                group.addTask { (kind, await provider.checkAvailability()) }
            }
            var results: [LLMProviderKind: LLMAvailability] = [:]
            for await (kind, status) in group { results[kind] = status }
            return results
        }
        for (kind, status) in results { services.providers.record(kind, ready: status.isReady) }
        providerStatus = results
    }

    /// The provider summaries (and proofreading) will use: the chosen one, or one that works.
    public var workingSummaryProvider: LLMProviderKind {
        settings.workingProvider(settings.summaryProvider, ready: services.providers.isReady)
    }

    /// The provider the live copilot will use: the chosen one, or one that works.
    public var workingCopilotProvider: LLMProviderKind {
        settings.workingProvider(settings.copilotProvider, ready: services.providers.isReady)
    }

    public var store: SessionStore { services.store }

    // MARK: - Voices

    /// People PalMeet recognizes by voice.
    public func voiceProfiles() -> [VoiceProfile] {
        services.voices.load().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func deleteVoice(_ id: UUID) {
        try? services.voices.delete(id)
    }

    public func renameVoice(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? services.voices.rename(id, to: trimmed)
    }

    public func forgetAllVoices() {
        try? services.voices.deleteAll()
    }

    // MARK: - Sources

    public func availableWindows() async throws -> [CapturableWindow] {
        try await ShareableSources.windows()
    }

    /// Browser meeting tabs (one entry per window, the meeting tab in it) from every connected profile.
    public func browserMeetingChoices(windows: [CapturableWindow]) -> [SourceChoice] {
        browserProfiles.flatMap { profile in
            profile.windows.compactMap { window -> SourceChoice? in
                let meetingTabs = window.tabs.filter(\.isMeeting)
                guard let tab = meetingTabs.first(where: \.active) ?? meetingTabs.first else { return nil }
                return .browserTab(profile: profile, window: window, tab: tab, scWindowID: matchWindow(window, in: windows))
            }
        }
    }

    /// Finds the on-screen window for a browser window by bounds (same point coordinates) or title.
    func matchWindow(_ browserWindow: BrowserWindow, in windows: [CapturableWindow]) -> CGWindowID? {
        let bounds = browserWindow.bounds
        let target = CGRect(x: bounds.left, y: bounds.top, width: bounds.width, height: bounds.height)
        let candidates = windows.filter(\.isBrowser)
        if let byFrame = candidates.first(where: { abs($0.frame.minX - target.minX) < 6 && abs($0.frame.minY - target.minY) < 6 && abs($0.frame.width - target.width) < 6 }) {
            return byFrame.id
        }
        let activeTitle = browserWindow.tabs.first(where: \.active)?.title ?? ""
        return candidates.first { !activeTitle.isEmpty && $0.title.contains(activeTitle) }?.id
    }

    /// Bundle ID for a browser name reported by the extension (Arc reports itself as Chrome).
    nonisolated static func bundleID(forBrowser name: String) -> String? {
        let lowered = name.lowercased()
        if lowered.contains("edge") { return "com.microsoft.edgemac" }
        if lowered.contains("brave") { return "com.brave.Browser" }
        if lowered.contains("arc") { return "company.thebrowser.Browser" }
        if lowered.contains("chrom") { return "com.google.Chrome" }
        return nil
    }

    public func isolationPreview(for choice: SourceChoice) -> IsolationPreview {
        switch choice {
        case .browserTab(let profile, _, _, _):
            // The tab itself is isolated, but a whole-browser tap running for another meeting would hear it too.
            let bundle = Self.bundleID(forBrowser: profile.browser)
            if let tapSession = activeSessions.first(where: { $0.metadata.isolation != .browserExtension && $0.metadata.source.bundleID == bundle && bundle != nil }) {
                return .shared(conflictsWith: tapSession.title)
            }
            return .isolated("browser extension (this tab only)")
        case .window(let window):
            // Same browser as a running session: the extension separates tabs, a process tap can't.
            if window.isBrowser, let other = activeSessions.first(where: { $0.metadata.source.bundleID == window.bundleID }) {
                if other.metadata.isolation == .browserExtension {
                    return .needsExtension("“\(other.title)” is recorded as a \(window.appName) tab; recording the whole window would also capture it. Pick this meeting's tab from the extension list instead.")
                }
                return .needsExtension("“\(other.title)” is already recording in \(window.appName). Install the PalMeet extension so each tab's audio stays separate.")
            }
            let family = MeetingApp.audioFamily(bundleID: window.bundleID, pid: window.pid)
            for session in activeSessions where session.metadata.isolation != .browserExtension {
                let other = MeetingApp.audioFamily(bundleID: session.metadata.source.bundleID, pid: session.metadata.source.processID)
                if family.overlaps(other) { return .shared(conflictsWith: session.title) }
            }
            if window.isBrowser {
                // A browser plays every tab of every profile through one audio process, and its page contents
                // (the mute button) aren't visible to PalMeet without the extension.
                return .needsExtension("Records ALL \(window.appName) audio: every tab in every profile (videos, other calls), and can't see when you're muted. Add the PalMeet extension to this profile to record just the meeting tab.")
            }
            return .isolated("\(window.appName) audio only")
        }
    }

    // MARK: - Sessions

    @discardableResult
    public func startSession(_ choice: SourceChoice, title: String? = nil, includeMicrophone: Bool? = nil, adoptingBridgeSession: UUID? = nil) async throws -> MeetingSession {
        if adoptingBridgeSession == nil, let existing = sessionRecording(choice) {
            throw SessionError.alreadyRecording(existing.title)
        }
        let sessionID = adoptingBridgeSession ?? SessionID()
        let preview = isolationPreview(for: choice)

        switch choice {
        case .window(let window):
            let source = CaptureSourceDescriptor(
                kind: .window, appName: window.appName, bundleID: window.bundleID, processID: window.pid,
                windowID: window.id, windowTitle: window.title
            )
            let shared: Bool = if case .shared = preview { true } else { false }
            let remote = ProcessTapRemoteAudio(family: MeetingApp.audioFamily(bundleID: window.bundleID, pid: window.pid), name: window.appName, shared: shared)
            return try await startSession(
                id: sessionID, source: source, title: title ?? choice.title, remote: remote,
                windowID: window.id, frames: nil, includeMicrophone: includeMicrophone, preview: preview
            )
        case .browserTab(let profile, let browserWindow, let tab, let scWindowID):
            let source = CaptureSourceDescriptor(
                kind: .browserTab, appName: profile.browser, bundleID: Self.bundleID(forBrowser: profile.browser),
                windowID: scWindowID, windowTitle: tab.title,
                browserProfileID: profile.id, browserProfileLabel: profile.label,
                browserWindowID: browserWindow.windowID, browserTabID: tab.tabID, tabURL: tab.url
            )
            let remote = BrowserTabRemoteAudio(
                bridge: bridge, sessionID: sessionID, profileID: profile.id, windowID: browserWindow.windowID,
                tabID: tab.tabID, alreadyCapturing: adoptingBridgeSession != nil
            )
            return try await startSession(
                id: sessionID, source: source, title: title ?? choice.title, remote: remote,
                windowID: scWindowID, frames: BrowserTabFrames(bridge: bridge, sessionID: sessionID),
                includeMicrophone: includeMicrophone, preview: preview
            )
        }
    }

    /// The running session that already records `choice`'s meeting: the same window, the same tab, or a whole
    /// browser window that already contains the tab. Starting it again would record the meeting twice.
    public func sessionRecording(_ choice: SourceChoice) -> MeetingSession? {
        switch choice {
        case .window(let window):
            return activeSessions.first { $0.metadata.source.windowID == window.id }
        case .browserTab(let profile, _, let tab, let scWindowID):
            return activeSessions.first { session in
                let source = session.metadata.source
                if source.browserProfileID == profile.id, source.browserTabID == tab.tabID { return true }
                return session.metadata.isolation != .browserExtension && scWindowID != nil && source.windowID == scWindowID
            }
        }
    }

    /// Starts a session from already-built capture components (also the seam tests use).
    @discardableResult
    func startSession(
        id sessionID: SessionID,
        source: CaptureSourceDescriptor,
        title: String,
        remote: RemoteAudioSource?,
        windowID: CGWindowID?,
        frames: FrameProvider?,
        includeMicrophone: Bool?,
        preview: IsolationPreview
    ) async throws -> MeetingSession {
        guard activeSessions.count < settings.maxConcurrentSessions else {
            throw SessionError.tooManySessions(settings.maxConcurrentSessions)
        }
        var metadata = SessionMetadata(
            id: sessionID,
            title: Self.cleanTitle(title, appName: source.appName),
            source: source,
            isolation: remote?.isolation ?? .none,
            includesMicrophone: includeMicrophone ?? settings.includeMicByDefault,
            language: settings.language,
            appVersion: Self.appVersion
        )
        metadata.concurrentWith = activeSessions.map(\.id)
        let folder = try services.store.createFolder(for: metadata)
        colorCounter += 1
        let session = MeetingSession(
            metadata: metadata, folder: folder, remoteAudio: remote, services: services,
            settings: { [settingsBox] in settingsBox.value }, colorIndex: colorCounter
        )
        if case .shared(let other) = preview { session.warn("Audio is shared with “\(other)”; both transcripts may contain both meetings.") }
        for other in activeSessions { other.addConcurrent(sessionID) }
        activeSessions.append(session)
        lastUsedSessionID = sessionID
        await session.start(windowID: windowID, frames: frames)
        updateMicRouting()
        return session
    }

    nonisolated static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    public func stop(_ session: MeetingSession) async {
        guard activeSessions.contains(where: { $0.id == session.id }) else { return }
        activeSessions.removeAll { $0.id == session.id }
        library.insert(session, at: 0)
        updateMicRouting()
        await session.stop()
    }

    public func session(_ id: SessionID) -> MeetingSession? {
        activeSessions.first { $0.id == id } ?? library.first { $0.id == id }
    }

    /// The session hotkeys act on: the one whose window is frontmost, else the last one used.
    public func targetSession() -> MeetingSession? {
        if let frontmost = ShareableSources.frontmostWindowID(),
           let match = activeSessions.first(where: { $0.metadata.source.windowID == frontmost }) {
            return match
        }
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            let matches = activeSessions.filter { $0.metadata.source.bundleID == bundle }
            if matches.count == 1 { return matches[0] }
        }
        return activeSessions.first { $0.id == lastUsedSessionID } ?? activeSessions.last
    }

    public func markUsed(_ session: MeetingSession) {
        lastUsedSessionID = session.id
    }

    public func refreshLibrary() {
        let activeIDs = Set(activeSessions.map(\.id))
        let inMemory = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        library = services.store.listSessions()
            .filter { !activeIDs.contains($0.0.id) }
            .map { metadata, folder in
                inMemory[metadata.id] ?? MeetingSession(loadedFrom: folder, metadata: metadata, services: services, settings: { [settingsBox] in settingsBox.value })
            }
    }

    public func deleteFromLibrary(_ session: MeetingSession) {
        try? services.store.delete(session.folder)
        library.removeAll { $0.id == session.id }
    }

    nonisolated static func cleanTitle(_ raw: String, appName: String) -> String {
        var title = raw
        for suffix in [" - Google Chrome", " – Google Chrome", " - Microsoft Edge", " - Brave", " | Microsoft Teams", " - Zoom"] {
            if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "\(appName) meeting" : title
    }

    // MARK: - Mic routing

    /// Decides which sessions hear your mic. One session: yes unless you're muted in that meeting. Several: manual
    /// overrides win, then sessions known to be unmuted, then the only meeting app using the mic, then the frontmost
    /// meeting window. A meeting that can't report its mute state doesn't get the mic while you're unmuted in
    /// another call app that PalMeet isn't recording (e.g. talking in Teams while recording a Meet). What you say while muted never reaches the transcript (live or final) or the kept audio.
    func updateMicRouting() {
        let candidates = activeSessions.filter { $0.metadata.includesMicrophone && $0.stage.isCapturing }
        guard !candidates.isEmpty else { return }
        let talkingElsewhere = otherCalls.first { $0.muted == false }
        for session in candidates {
            session.otherCallUsingMic = session.knownMuted == nil ? (talkingElsewhere ?? otherCalls.first) : nil
        }
        if candidates.count == 1 {
            let session = candidates[0]
            // Unknown mute here while you're unmuted in another call: you're talking there, not here.
            let automatic = session.knownMuted == false || (session.knownMuted == nil && talkingElsewhere == nil)
            session.setMicRouted(session.micOverride ?? automatic)
            return
        }

        var routed = Set<SessionID>()
        let overridden = candidates.filter { $0.micOverride != nil }
        if settings.micRouting == .manual || !overridden.isEmpty {
            routed = Set(candidates.filter { $0.micOverride ?? false }.map(\.id))
            // Sessions without an override in auto mode still follow the automatic rules below.
            if settings.micRouting == .auto {
                let automatic = automaticRouting(candidates.filter { $0.micOverride == nil })
                routed.formUnion(automatic)
            }
        } else {
            routed = automaticRouting(candidates)
        }
        for session in candidates { session.setMicRouted(routed.contains(session.id)) }
    }

    private func automaticRouting(_ all: [MeetingSession]) -> Set<SessionID> {
        // A paused meeting isn't listening; never send your voice there automatically.
        let sessions = all.filter { $0.stage == .recording }
        guard !sessions.isEmpty else { return [] }
        let unmuted = sessions.filter { $0.knownMuted == false }
        if !unmuted.isEmpty { return Set(unmuted.map(\.id)) }
        let unknownMute = sessions.filter { $0.knownMuted == nil }
        guard !unknownMute.isEmpty else { return [] }
        // You're unmuted in a call PalMeet isn't recording, and these meetings can't say whether you're muted.
        if otherCalls.contains(where: { $0.muted == false }) { return [] }

        let processes = AudioProcessInspector.processes().filter(\.isRunningInput)
        let usingMic = unknownMute.filter { session in
            guard session.metadata.isolation != .browserExtension else { return false }
            let family = MeetingApp.audioFamily(bundleID: session.metadata.source.bundleID, pid: session.metadata.source.processID)
            return processes.contains { family.contains($0) }
        }
        if usingMic.count == 1 { return [usingMic[0].id] }

        if let target = targetSession(), unknownMute.contains(where: { $0.id == target.id }) {
            return [target.id]
        }
        return Set(unknownMute.filter(\.isMicRouted).map(\.id))
    }

    /// Mute / presenting state of desktop Zoom and Teams sessions via Accessibility (browser tabs report their own),
    /// and other call apps using the mic. Only needed when it changes something: a session with your mic (mute,
    /// other calls) or auto-hide while presenting.
    private func refreshDesktopMeetingStates() async {
        let withMic = activeSessions.contains(where: \.metadata.includesMicrophone)
        guard withMic || settings.privacy.autoHideWhileSharing else {
            otherCalls = []
            return
        }
        let accessibility = MeetingStateInspector.isAvailable
        let targets = activeSessions.compactMap { session -> (SessionID, String?, pid_t)? in
            guard accessibility, session.metadata.isolation != .browserExtension, let pid = session.metadata.source.processID else { return nil }
            return (session.id, session.metadata.source.bundleID, pid)
        }
        let recorded = activeSessions.filter { $0.metadata.isolation != .browserExtension }
            .map { MeetingApp.audioFamily(bundleID: $0.metadata.source.bundleID, pid: $0.metadata.source.processID) }
        let (states, others) = await Task.detached(priority: .utility) {
            let states = targets.map { ($0.0, MeetingStateInspector.state(bundleID: $0.1, pid: $0.2)) }
            let others = withMic ? Self.otherCallsUsingMic(excluding: recorded, accessibility: accessibility) : []
            return (states, others)
        }.value
        for (id, state) in states {
            guard let session = activeSessions.first(where: { $0.id == id }) else { continue }
            session.knownMuted = state.muted
            session.isPresenting = state.presenting
        }
        otherCalls = others
    }

    /// Desktop call apps (Teams, Zoom, Slack, …) using the mic that no session records.
    nonisolated static func otherCallsUsingMic(excluding recorded: [AppAudioFamily], accessibility: Bool) -> [OtherCall] {
        let usingMic = AudioProcessInspector.processes().filter { process in
            process.isRunningInput && !recorded.contains { $0.contains(process) }
        }
        var claimed = Set<pid_t>()
        var calls: [OtherCall] = []
        for app in MeetingApp.known where !app.isBrowser {
            let family = MeetingApp.audioFamily(bundleID: app.bundleID, pid: nil)
            let processes = usingMic.filter { family.contains($0) && !claimed.contains($0.pid) }
            guard !processes.isEmpty else { continue }
            claimed.formUnion(processes.map(\.pid))
            // Mute state lives in the app's main process (helpers have no UI).
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.processIdentifier
            let muted = accessibility ? pid.flatMap { MeetingStateInspector.state(bundleID: app.bundleID, pid: $0).muted } : nil
            calls.append(OtherCall(appName: app.name, muted: muted))
        }
        return calls
    }

    /// Hotkey: cycles mic routing manually (A → B → … → all → A). With one meeting it toggles your mic for it
    /// (off ↔ automatic), e.g. while muted in a browser window PalMeet can't read the mute state from.
    public func cycleMicRouting() {
        let sessions = activeSessions.filter { $0.metadata.includesMicrophone }
        if sessions.count == 1 {
            let session = sessions[0]
            session.micOverride = session.isMicRouted ? false : nil
            updateMicRouting()
            return
        }
        guard sessions.count > 1 else { return }
        let routedIndices = sessions.indices.filter { sessions[$0].isMicRouted }
        let next: Int? = routedIndices.count == 1 ? (routedIndices[0] + 1 < sessions.count ? routedIndices[0] + 1 : nil) : 0
        for (index, session) in sessions.enumerated() {
            session.micOverride = next.map { $0 == index } ?? true
        }
        updateMicRouting()
    }

    public func setMicOverride(_ session: MeetingSession, routed: Bool?) {
        session.micOverride = routed
        updateMicRouting()
    }

    // MARK: - Browser bridge

    private func handle(_ event: BrowserBridgeEvent) {
        switch event {
        case .profilesChanged(let profiles):
            browserProfiles = profiles
        case .captureState(let sessionID, let state):
            guard let session = activeSessions.first(where: { $0.id == sessionID }) else { return }
            switch state {
            case .awaitingGesture:
                session.waitingForBrowserClick = true
            case .capturing:
                session.waitingForBrowserClick = false
            case .stopped(let reason):
                session.waitingForBrowserClick = false
                // Closed tab, navigated away, clicked "stop" in the browser: the meeting is over for this tab.
                session.warn("Tab capture stopped\(reason.map { ": \($0)" } ?? ""). The recording was stopped.")
                Task { await self.stop(session) }
            case .error(let message):
                session.waitingForBrowserClick = false
                session.warn("Tab capture error: \(message)")
            }
        case .userInitiatedCapture(let sessionID, let profileID, let windowID, let tabID):
            adoptUserInitiatedCapture(sessionID: sessionID, profileID: profileID, windowID: windowID, tabID: tabID)
        case .meetingState(let sessionID, let muted, let presenting):
            guard let session = activeSessions.first(where: { $0.id == sessionID }) else { return }
            session.knownMuted = muted
            session.isPresenting = presenting
            updateMicRouting()
        case .speakerActivity(let report):
            activeSessions.first { $0.id == report.sessionId }?.recordSpeakerActivity(
                at: Date(timeIntervalSince1970: report.at / 1000),
                captions: report.captions.map { ($0.id, $0.name, $0.text) },
                speaking: report.speaking
            )
        case .pageDiagnostics(let sessionID, let at, let payload):
            activeSessions.first { $0.id == sessionID }?.recordPageDiagnostics(payload, at: at)
        }
    }

    /// The user clicked the extension icon on a meeting tab without starting from the app: start a session for it.
    private func adoptUserInitiatedCapture(sessionID: UUID, profileID: String, windowID: Int, tabID: Int) {
        guard activeSessions.first(where: { $0.id == sessionID }) == nil, !pendingAdoptions.contains(sessionID) else { return }
        guard let profile = (bridge.profiles().first { $0.id == profileID } ?? browserProfiles.first { $0.id == profileID }),
              let window = profile.windows.first(where: { $0.windowID == windowID }),
              let tab = window.tabs.first(where: { $0.tabID == tabID })
        else {
            // Never leave a capture running that no session will record.
            bridge.stopCapture(sessionID: sessionID)
            return
        }
        pendingAdoptions.insert(sessionID)
        Task {
            defer { pendingAdoptions.remove(sessionID) }
            let windows = (try? await availableWindows()) ?? []
            let choice = SourceChoice.browserTab(profile: profile, window: window, tab: tab, scWindowID: matchWindow(window, in: windows))
            do {
                try await startSession(choice, adoptingBridgeSession: sessionID)
            } catch {
                logger.error("Could not adopt browser capture: \(error.localizedDescription, privacy: .public)")
                bridge.stopCapture(sessionID: sessionID)
            }
        }
    }

    /// True while any session reports that you're presenting (drives auto-hide).
    public var isPresentingAnywhere: Bool {
        activeSessions.contains { $0.isPresenting == true }
    }
}

/// Lock-protected settings snapshot readable from any thread.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AppSettings

    init(_ value: AppSettings) {
        _value = value
    }

    var value: AppSettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
