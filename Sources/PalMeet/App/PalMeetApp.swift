import AppKit
import PalMeetCore
import SwiftUI

struct PalMeetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarView()
                .environment(app)
        } label: {
            MenuBarLabel(count: app.manager.activeSessions.count)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { app.updates.checkForUpdates() }
                    .disabled(!app.updates.canCheckForUpdates)
            }
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { app.manager.settings.privacy.showMenuBarIcon },
            set: { value in
                // MenuBarExtra writes this binding back on every render; only real changes count.
                guard value != app.manager.settings.privacy.showMenuBarIcon else { return }
                app.manager.updateSettings { $0.privacy.showMenuBarIcon = value }
            }
        )
    }
}

private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "waveform.and.mic")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DemoRecorder.isRequested {
            MainActor.assumeIsolated { DemoRecorder.start() }
            return
        }
        #endif
        if let file = MainActor.assumeIsolated({ CommandLineImport.file }) {
            Task { @MainActor in
                await CommandLineImport.run(file)
                NSApp.terminate(nil)
            }
            return
        }
        if let reportPath = MainActor.assumeIsolated({ UpdateProbe.reportPath }) {
            Task { @MainActor in await UpdateProbe(reportPath: reportPath).run() }
            return
        }
        if let reportPath = MainActor.assumeIsolated({ SelfTest.reportPath }) {
            Task { @MainActor in
                await SelfTest.run(reportPath: reportPath)
                NSApp.terminate(nil)
            }
            return
        }
        MainActor.assumeIsolated {
            let app = AppState.shared
            app.bootstrap()
            if !app.manager.settings.hasCompletedOnboarding || app.manager.settings.privacy.showDockIcon {
                app.openMainWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppState.shared.openMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Stops capture cleanly so audio files are finalized; transcription resumes from the library next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActive = MainActor.assumeIsolated { !AppState.shared.manager.activeSessions.isEmpty }
        guard hasActive else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.manager.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
