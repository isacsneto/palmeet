import AppKit
import Observation
import PalMeetCore
import SessionKit
import SwiftUI

/// Owns PalMeet's AppKit windows and enforces window privacy and appearance:
/// - every window is excluded from screen capture (`sharingType = .none`) when enabled,
/// - per-window opacity, background opacity, click-through, always-on-top and auto-fade,
/// - panic hide and auto-hide while a session reports you're presenting (rules in `HideCoordinator`).
@MainActor
@Observable
final class WindowController {
    private(set) var hiding = HideCoordinator<ObjectIdentifier>()
    var focusedCardIndex = 0
    private(set) var hovering: Set<AppWindowRole> = []
    /// Session shown in the copilot panel (picked there, else the meeting in front). Hotkeys use the same one.
    var panelSessionID: SessionID?
    /// Refreshed once a second; avoids window-server queries during SwiftUI renders.
    private(set) var frontmostSessionID: SessionID?

    var isPanicHidden: Bool { hiding.isPanicActive }

    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var mainWindow: NSWindow?
    @ObservationIgnored private var copilotPanel: NSPanel?
    @ObservationIgnored private var quickNotePanel: NSPanel?
    @ObservationIgnored private var cheatSheetPanel: NSPanel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fadeBoostUntil: Date = .distantPast

    func attach(to app: AppState) {
        self.app = app
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPrivacyToAllWindows() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
        applyAll()
    }

    private var settings: AppSettings { app?.manager.settings ?? AppSettings() }

    // MARK: - Windows

    /// Shows a window unless panic/auto-hide is active, in which case it is remembered and shown afterwards.
    private func present(_ window: NSWindow, makeKey: Bool) {
        guard hiding.allowsShowing else {
            hiding.adopt(ObjectIdentifier(window))
            return
        }
        if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        applyAll()
    }

    func showMainWindow() {
        if mainWindow == nil, let app {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "PalMeet"
            window.identifier = NSUserInterfaceItemIdentifier(AppWindowRole.main.rawValue)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView().environment(app))
            window.setFrameAutosaveName("PalMeetMain")
            if window.frame.origin == .zero { window.center() }
            mainWindow = window
        }
        if let mainWindow { present(mainWindow, makeKey: true) }
    }

    func toggleMainWindow() {
        if let mainWindow, mainWindow.isVisible {
            mainWindow.orderOut(nil)
        } else {
            NSApp.activate()
            showMainWindow()
        }
    }

    func showCopilotPanel() {
        if copilotPanel == nil, let app {
            let panel = makePanel(role: .copilotPanel, size: NSSize(width: 380, height: 520), title: "Copilot")
            panel.contentView = NSHostingView(rootView: CopilotPanelView().environment(app))
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 400, y: frame.maxY - 560))
            }
            panel.setFrameAutosaveName("PalMeetCopilotPanel")
            copilotPanel = panel
        }
        if let copilotPanel { present(copilotPanel, makeKey: false) }
    }

    func toggleCopilotPanel() {
        if let copilotPanel, copilotPanel.isVisible {
            copilotPanel.orderOut(nil)
        } else {
            showCopilotPanel()
        }
    }

    /// Quick note panel: becomes key without activating PalMeet, so focus returns to the meeting after Return/Esc.
    func showQuickNote() {
        guard let app else { return }
        let panel = quickNotePanel ?? makePanel(role: .hud, size: NSSize(width: 420, height: 64), title: "Quick note")
        panel.contentView = NSHostingView(rootView: QuickNoteView { [weak self] in self?.quickNotePanel?.orderOut(nil) }.environment(app))
        panel.becomesKeyOnlyIfNeeded = false
        quickNotePanel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 140))
        }
        present(panel, makeKey: true)
    }

    func toggleCheatSheet() {
        if let cheatSheetPanel, cheatSheetPanel.isVisible {
            cheatSheetPanel.orderOut(nil)
            return
        }
        guard let app else { return }
        let panel = cheatSheetPanel ?? makePanel(role: .hud, size: NSSize(width: 460, height: 560), title: "Shortcuts")
        panel.contentView = NSHostingView(rootView: CheatSheetView().environment(app))
        cheatSheetPanel = panel
        panel.center()
        present(panel, makeKey: false)
    }

    private func makePanel(role: AppWindowRole, size: NSSize, title: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = title
        panel.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and full-screen meetings; stay out of ⌘-` window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    // MARK: - Privacy

    func applyAll() {
        applyPrivacyToAllWindows()
        for (role, window) in managedWindows() { applyAppearance(role, to: window) }
    }

    /// Cheap enough for window notifications: only touches windows whose sharing type is wrong.
    private func applyPrivacyToAllWindows() {
        let desired: NSWindow.SharingType = settings.privacy.hideFromScreenCapture ? .none : .readOnly
        for window in NSApp.windows where window.sharingType != desired {
            window.sharingType = desired
        }
    }

    private func managedWindows() -> [(AppWindowRole, NSWindow)] {
        var result: [(AppWindowRole, NSWindow)] = []
        if let mainWindow { result.append((.main, mainWindow)) }
        if let copilotPanel { result.append((.copilotPanel, copilotPanel)) }
        if let quickNotePanel { result.append((.hud, quickNotePanel)) }
        if let cheatSheetPanel { result.append((.hud, cheatSheetPanel)) }
        return result
    }

    private func applyAppearance(_ role: AppWindowRole, to window: NSWindow) {
        let appearance = settings.appearance[role]
        let faded = appearance.autoFade && !hovering.contains(role) && Date() > fadeBoostUntil
        let alpha = max(0.2, faded ? min(appearance.fadedOpacity, appearance.contentOpacity) : appearance.contentOpacity)
        if window.alphaValue != alpha { window.alphaValue = alpha }
        window.ignoresMouseEvents = appearance.clickThrough
        let level: NSWindow.Level = appearance.alwaysOnTop ? .floating : .normal
        if window.level != level { window.level = level }
        if role != .main {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    func setHovering(_ role: AppWindowRole, _ isHovering: Bool) {
        guard hovering.contains(role) != isHovering else { return }
        if isHovering { hovering.insert(role) } else { hovering.remove(role) }
        applyAll()
    }

    /// Briefly returns a faded panel to full opacity (new suggestion arrived).
    func boostVisibility(seconds: TimeInterval = 6) {
        fadeBoostUntil = Date().addingTimeInterval(seconds)
        applyAll()
    }

    // MARK: - Opacity & click-through hotkeys

    /// The window appearance hotkeys act on: the copilot panel when visible, else the main window.
    private var appearanceTarget: AppWindowRole {
        (copilotPanel?.isVisible ?? false) ? .copilotPanel : .main
    }

    static func steppedOpacity(_ current: Double, by delta: Double) -> Double {
        min(1, max(0.2, ((current + delta) * 10).rounded() / 10))
    }

    func adjustOpacity(by delta: Double) {
        let role = appearanceTarget
        app?.manager.updateSettings { s in
            s.appearance[role].contentOpacity = Self.steppedOpacity(s.appearance[role].contentOpacity, by: delta)
        }
        applyAll()
    }

    func resetOpacity() {
        let role = appearanceTarget
        app?.manager.updateSettings { $0.appearance[role].contentOpacity = 1 }
        applyAll()
    }

    func toggleClickThrough() {
        let role = appearanceTarget
        app?.manager.updateSettings { $0.appearance[role].clickThrough.toggle() }
        applyAll()
    }

    // MARK: - Panic hide & auto-hide

    /// Every visible PalMeet window except the menu bar icon itself.
    private func visibleAppWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !$0.className.contains("StatusBar") }
    }

    private func apply(_ actions: HideCoordinator<ObjectIdentifier>.Actions, among windows: [NSWindow]) {
        for window in windows where actions.hide.contains(ObjectIdentifier(window)) { window.orderOut(nil) }
        for window in windows where actions.show.contains(ObjectIdentifier(window)) { window.orderFrontRegardless() }
        applyAll()
    }

    func togglePanicHide() {
        let visible = visibleAppWindows()
        let actions = hiding.togglePanic(visible: Set(visible.map(ObjectIdentifier.init)))
        apply(actions, among: NSApp.windows)
    }

    private func periodic() {
        guard let app else { return }
        // Assign observable state only on change, so idle ticks don't re-render views.
        let front = app.manager.targetSession()?.id
        if front != frontmostSessionID { frontmostSessionID = front }
        let presenting = app.manager.isPresentingAnywhere && settings.privacy.autoHideWhileSharing
        if presenting != hiding.isAutoHideActive {
            let visible = visibleAppWindows()
            let actions = hiding.presentingChanged(presenting, visible: Set(visible.map(ObjectIdentifier.init)))
            if !actions.isEmpty { apply(actions, among: NSApp.windows) }
        }
        if AppWindowRole.allCases.contains(where: { settings.appearance[$0].autoFade }) { applyAll() }
    }

    func moveCardFocus(by delta: Int) {
        let count = app.flatMap { app in (panelSessionID ?? frontmostSessionID).flatMap { app.manager.session($0) } }?.visibleCards.count ?? 0
        focusedCardIndex = min(max(0, focusedCardIndex + delta), max(0, count - 1))
        showCopilotPanel()
    }
}
