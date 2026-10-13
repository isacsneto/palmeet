import PalMeetCore
import SessionKit
import SwiftUI

/// Menu bar HUD: one row per active meeting plus the main actions.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PalMeet").font(.headline)
                Spacer()
                if app.windows.isPanicHidden {
                    Label("Hidden", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                }
            }

            if app.manager.activeSessions.isEmpty {
                Text("No meetings are being recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.manager.activeSessions) { session in
                    SessionControlRow(session: session)
                }
            }

            Divider()

            Button {
                app.presentPicker()
            } label: {
                Label(app.manager.activeSessions.isEmpty ? "Record a meeting…" : "Add another meeting…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)

            Button {
                app.presentImportPanel()
            } label: {
                Label("Import a recording…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)

            HStack {
                Button("Open PalMeet") { app.openMainWindow() }
                Button("Copilot panel") { app.windows.toggleCopilotPanel() }
                Spacer()
                if app.updates.isAvailable {
                    Button {
                        app.updates.checkForUpdates()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .help("Check for updates")
                    .disabled(!app.updates.canCheckForUpdates)
                }
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit PalMeet")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// Compact controls for one recording session (menu bar and sidebar).
struct SessionControlRow: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(SessionPalette.color(session.colorIndex))
                    .frame(width: 9, height: 9)
                    .opacity(session.stage == .paused ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).lineLimit(1).font(.callout.weight(.medium))
                    Text(session.metadata.source.appName + isolationSuffix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                ElapsedText(session: session).font(.caption)
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.wave.2").font(.caption2)
                    LevelMeter(level: session.themLevel, tint: SessionPalette.color(session.colorIndex))
                }
                .help("Meeting audio")

                Button {
                    app.manager.setMicOverride(session, routed: !session.isMicRouted)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: session.isMicRouted ? "mic.fill" : "mic.slash")
                        LevelMeter(level: session.meLevel)
                    }
                }
                .buttonStyle(.borderless)
                .help(session.isMicRouted ? "Your mic goes to this meeting (click to stop)" : "Your mic is not routed here (click to route)")
                .disabled(!session.metadata.includesMicrophone)

                Spacer()

                Button {
                    session.toggleCopilot()
                    if session.copilotEnabled { app.windows.showCopilotPanel() }
                } label: {
                    Image(systemName: session.copilotEnabled ? "brain.head.profile.fill" : "brain.head.profile")
                        .foregroundStyle(session.copilotEnabled ? Color.accentColor : .secondary)
                }
                .help(session.copilotEnabled ? "Copilot is ON (⌃⌥C to turn off)" : "Copilot is OFF (⌃⌥C to turn on)")

                Button {
                    Task { await session.markMoment() }
                } label: {
                    Image(systemName: "camera")
                }
                .help("Mark moment + screenshot (⌃⌥S)")

                Button {
                    session.stage == .paused ? session.resume() : session.pause()
                } label: {
                    Image(systemName: session.stage == .paused ? "play.fill" : "pause.fill")
                }
                .help("Pause / resume (⌃⌥P)")

                Button {
                    app.stop(session)
                } label: {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                }
                .help("Stop & summarize")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isolationSuffix: String {
        switch session.metadata.isolation {
        case .browserExtension: " · tab audio"
        case .processTap: " · app audio"
        case .sharedAudio: " · ⚠️ shared audio"
        case .screenCaptureKit: " · app audio"
        case .none: " · mic only"
        }
    }
}
