import AppKit
import CaptureKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    private static let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: ctrlOpt))
    static let addMeeting = Self("addMeeting", default: .init(.n, modifiers: ctrlOpt))
    static let pauseResume = Self("pauseResume", default: .init(.p, modifiers: ctrlOpt))
    static let stopAndSummarize = Self("stopAndSummarize", default: .init(.e, modifiers: ctrlOpt))
    static let markMoment = Self("markMoment", default: .init(.s, modifiers: ctrlOpt))
    static let quickNote = Self("quickNote", default: .init(.k, modifiers: ctrlOpt))
    static let cycleMic = Self("cycleMic", default: .init(.m, modifiers: ctrlOpt))
    static let toggleCopilot = Self("toggleCopilot", default: .init(.c, modifiers: ctrlOpt))
    static let helpNow = Self("helpNow", default: .init(.h, modifiers: ctrlOpt))
    static let copySuggestion1 = Self("copySuggestion1", default: .init(.one, modifiers: ctrlOpt))
    static let copySuggestion2 = Self("copySuggestion2", default: .init(.two, modifiers: ctrlOpt))
    static let copySuggestion3 = Self("copySuggestion3", default: .init(.three, modifiers: ctrlOpt))
    static let nextCard = Self("nextCard", default: .init(.rightBracket, modifiers: ctrlOpt))
    static let previousCard = Self("previousCard", default: .init(.leftBracket, modifiers: ctrlOpt))
    static let toggleCopilotPanel = Self("toggleCopilotPanel", default: .init(.space, modifiers: ctrlOpt))
    static let toggleMainWindow = Self("toggleMainWindow", default: .init(.w, modifiers: ctrlOpt))
    static let panicHide = Self("panicHide", default: .init(.backslash, modifiers: ctrlOpt))
    static let opacityUp = Self("opacityUp", default: .init(.upArrow, modifiers: ctrlOpt))
    static let opacityDown = Self("opacityDown", default: .init(.downArrow, modifiers: ctrlOpt))
    static let opacityReset = Self("opacityReset", default: .init(.zero, modifiers: ctrlOpt))
    static let clickThrough = Self("clickThrough", default: .init(.t, modifiers: ctrlOpt))
    static let cheatSheet = Self("cheatSheet", default: .init(.slash, modifiers: ctrlOpt))
}

/// Every hotkey, grouped as in Settings → Hotkeys and the cheat sheet.
enum HotkeyCatalog {
    struct Entry: Identifiable {
        let name: KeyboardShortcuts.Name
        let title: String
        var id: String { name.rawValue }
    }

    static let groups: [(String, [Entry])] = [
        ("Recording", [
            Entry(name: .toggleRecording, title: "Record frontmost meeting / stop"),
            Entry(name: .addMeeting, title: "Add another meeting"),
            Entry(name: .pauseResume, title: "Pause / resume"),
            Entry(name: .stopAndSummarize, title: "Stop & summarize"),
        ]),
        ("Context", [
            Entry(name: .markMoment, title: "Mark moment + screenshot"),
            Entry(name: .quickNote, title: "Quick note"),
        ]),
        ("Mic", [
            Entry(name: .cycleMic, title: "My mic on/off (cycles between meetings when several)"),
        ]),
        ("Copilot", [
            Entry(name: .toggleCopilot, title: "Copilot on / off"),
            Entry(name: .helpNow, title: "Help me now"),
            Entry(name: .copySuggestion1, title: "Copy suggestion 1"),
            Entry(name: .copySuggestion2, title: "Copy suggestion 2"),
            Entry(name: .copySuggestion3, title: "Copy suggestion 3"),
            Entry(name: .nextCard, title: "Next card"),
            Entry(name: .previousCard, title: "Previous card"),
        ]),
        ("Windows", [
            Entry(name: .toggleCopilotPanel, title: "Show / hide copilot panel"),
            Entry(name: .toggleMainWindow, title: "Show / hide main window"),
            Entry(name: .panicHide, title: "Panic hide (all windows)"),
        ]),
        ("Appearance", [
            Entry(name: .opacityUp, title: "Opacity up"),
            Entry(name: .opacityDown, title: "Opacity down"),
            Entry(name: .opacityReset, title: "Reset opacity"),
            Entry(name: .clickThrough, title: "Click-through mode"),
        ]),
        ("Help", [
            Entry(name: .cheatSheet, title: "Shortcut cheat sheet"),
        ]),
    ]
}

@MainActor
enum Hotkeys {
    static func register(app: AppState) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { app.toggleRecordingFrontmost() }
        KeyboardShortcuts.onKeyUp(for: .addMeeting) { app.presentPicker() }
        KeyboardShortcuts.onKeyUp(for: .pauseResume) { app.togglePauseTarget() }
        KeyboardShortcuts.onKeyUp(for: .stopAndSummarize) { app.stopTarget() }
        KeyboardShortcuts.onKeyUp(for: .markMoment) { app.markMomentTarget() }
        KeyboardShortcuts.onKeyUp(for: .quickNote) { app.quickNoteTarget() }
        KeyboardShortcuts.onKeyUp(for: .cycleMic) { app.manager.cycleMicRouting() }
        KeyboardShortcuts.onKeyUp(for: .toggleCopilot) { app.toggleCopilotTarget() }
        KeyboardShortcuts.onKeyUp(for: .helpNow) { app.helpNowTarget() }
        KeyboardShortcuts.onKeyUp(for: .copySuggestion1) { app.copySuggestion(0) }
        KeyboardShortcuts.onKeyUp(for: .copySuggestion2) { app.copySuggestion(1) }
        KeyboardShortcuts.onKeyUp(for: .copySuggestion3) { app.copySuggestion(2) }
        KeyboardShortcuts.onKeyUp(for: .nextCard) { app.windows.moveCardFocus(by: 1) }
        KeyboardShortcuts.onKeyUp(for: .previousCard) { app.windows.moveCardFocus(by: -1) }
        KeyboardShortcuts.onKeyUp(for: .toggleCopilotPanel) { app.windows.toggleCopilotPanel() }
        KeyboardShortcuts.onKeyUp(for: .toggleMainWindow) { app.windows.toggleMainWindow() }
        KeyboardShortcuts.onKeyUp(for: .panicHide) { app.windows.togglePanicHide() }
        KeyboardShortcuts.onKeyUp(for: .opacityUp) { app.windows.adjustOpacity(by: 0.1) }
        KeyboardShortcuts.onKeyUp(for: .opacityDown) { app.windows.adjustOpacity(by: -0.1) }
        KeyboardShortcuts.onKeyUp(for: .opacityReset) { app.windows.resetOpacity() }
        KeyboardShortcuts.onKeyUp(for: .clickThrough) { app.windows.toggleClickThrough() }
        KeyboardShortcuts.onKeyUp(for: .cheatSheet) { app.windows.toggleCheatSheet() }
    }
}

enum CaptureKitFrontmost {
    static func windowID() -> CGWindowID? {
        ShareableSources.frontmostWindowID()
    }
}
