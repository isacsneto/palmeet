import AppKit
import UniformTypeIdentifiers
import Observation
import PalMeetCore
import SessionKit
import SwiftUI

/// App-wide UI state on top of the `SessionManager`.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let manager = SessionManager()
    let windows = WindowController()
    @ObservationIgnored private(set) lazy var updates = UpdateController(secrets: manager.secrets)
    var selectedSessionID: SessionID?
    var isPickerPresented = false
    var quickNoteSessionID: SessionID?
    var lastError: String?
    var showCheatSheet = false

    private init() {}

    func bootstrap() {
        // The extension folder is refreshed before the bridge starts, so an outdated extension that is asked to
        // reload itself picks up this version's files.
        ChromeExtensionFolder.refresh()
        if let version = ChromeExtensionFolder.bundledVersion { manager.bridge.setLatestExtensionVersion(version) }
        manager.start()
        windows.attach(to: self)
        Hotkeys.register(app: self)
        applyActivationPolicy()
        updates.isRecording = { [manager] in !manager.activeSessions.isEmpty }
        updates.start()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(manager.settings.privacy.showDockIcon ? .regular : .accessory)
    }

    // MARK: - Actions shared by menus, buttons and hotkeys

    func openMainWindow() {
        NSApp.activate()
        windows.showMainWindow()
    }

    func presentPicker() {
        openMainWindow()
        isPickerPresented = true
    }

    /// ⌃⌥R: stop the target session if its window is frontmost and recording; otherwise record the frontmost
    /// meeting window, or open the picker.
    /// True while the record hotkey is starting a session (starting takes a moment; repeated presses are ignored).
    private var startingFromHotkey = false

    func toggleRecordingFrontmost() {
        guard !startingFromHotkey else { return }
        if let frontmostID = CaptureKitBridge.frontmostWindowID(),
           let session = manager.activeSessions.first(where: { $0.metadata.source.windowID == frontmostID }) {
            stop(session)
            return
        }
        startingFromHotkey = true
        Task {
            defer { startingFromHotkey = false }
            do {
                let windows = try await manager.availableWindows()
                guard let frontmostID = CaptureKitBridge.frontmostWindowID(),
                      let window = windows.first(where: { $0.id == frontmostID && $0.isMeetingApp })
                else {
                    presentPicker()
                    return
                }
                let tabChoice = manager.browserMeetingChoices(windows: windows).first { choice in
                    if case .browserTab(_, _, _, let scID) = choice { return scID == window.id }
                    return false
                }
                // A browser window without a matching extension tab would record the whole browser (every tab and
                // profile, mute state unknown): let the user choose in the picker instead of doing that silently.
                guard let choice = tabChoice ?? (window.isBrowser ? nil : .window(window)) else {
                    presentPicker()
                    return
                }
                if let existing = manager.sessionRecording(choice) {
                    selectedSessionID = existing.id
                    openMainWindow()
                    return
                }
                let session = try await manager.startSession(choice)
                selectedSessionID = session.id
            } catch {
                lastError = error.localizedDescription
                presentPicker()
            }
        }
    }

    func start(_ choices: [SourceChoice], includeMicrophone: Bool) {
        Task {
            for choice in choices {
                // Picking a meeting's tab and its whole browser window records it once, through the tab.
                if case .window(let window) = choice, window.isBrowser, choices.contains(where: { other in
                    if case .browserTab(_, _, _, let scID) = other { return scID == window.id }
                    return false
                }) { continue }
                do {
                    let session = try await manager.startSession(choice, includeMicrophone: includeMicrophone)
                    selectedSessionID = session.id
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    /// File → Import: pick an audio/video recording and process it like a meeting.
    func presentImportPanel() {
        openMainWindow()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingImporter.supportedTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose meeting recordings (video or audio) to transcribe and summarize"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importRecording(url) }
    }

    func importRecording(_ url: URL) {
        Task {
            do {
                let session = try await manager.importRecording(from: url)
                selectedSessionID = session.id
                await session.processImport()
            } catch {
                lastError = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    func stop(_ session: MeetingSession) {
        selectedSessionID = session.id
        Task { await manager.stop(session) }
    }

    func stopTarget() {
        guard let session = manager.targetSession() else { return }
        stop(session)
    }

    func togglePauseTarget() {
        guard let session = manager.targetSession() else { return }
        session.stage == .paused ? session.resume() : session.pause()
    }

    func markMomentTarget() {
        guard let session = manager.targetSession() else { return }
        manager.markUsed(session)
        Task { await session.markMoment() }
    }

    func quickNoteTarget() {
        guard let session = manager.targetSession() else { return }
        quickNoteSessionID = session.id
        windows.showQuickNote()
    }

    func toggleCopilotTarget() {
        guard let session = manager.targetSession() else { return }
        manager.markUsed(session)
        session.toggleCopilot()
        if session.copilotEnabled { windows.showCopilotPanel() }
    }

    func helpNowTarget() {
        guard let session = manager.targetSession() else { return }
        if !session.copilotEnabled {
            session.setCopilot(enabled: true)
            windows.showCopilotPanel()
        }
        session.copilotHelpNow()
    }

    /// ⌃⌥1/2/3: copies the n-th option of the card focused in the copilot panel (same session, same order).
    func copySuggestion(_ index: Int) {
        let sessionID = windows.panelSessionID ?? windows.frontmostSessionID ?? manager.targetSession()?.id
        guard let session = sessionID.flatMap(manager.session),
              let card = session.copyTarget(focusedIndex: windows.focusedCardIndex),
              card.items.indices.contains(index)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.items[index].text, forType: .string)
        session.updateSuggestion(card.id, status: .used)
    }
}

/// Small indirection so the app target doesn't need to import CaptureKit everywhere.
enum CaptureKitBridge {
    static func frontmostWindowID() -> CGWindowID? {
        CaptureKitFrontmost.windowID()
    }
}
