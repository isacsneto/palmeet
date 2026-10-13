import PalMeetCore
import SessionKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var search = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selectedSessionID) {
                if !app.manager.activeSessions.isEmpty {
                    Section("Recording") {
                        ForEach(app.manager.activeSessions) { session in
                            SidebarRow(session: session).tag(session.id)
                        }
                    }
                }
                Section("Library") {
                    ForEach(filteredLibrary) { session in
                        SidebarRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.folder.url]) }
                                Button("Move to Trash", role: .destructive) { app.manager.deleteFromLibrary(session) }
                            }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .toolbar {
                ToolbarItem {
                    Button {
                        app.isPickerPresented = true
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .help("Record a meeting (⌃⌥N)")
                }
            }
        } detail: {
            if !app.manager.settings.hasCompletedOnboarding {
                OnboardingView()
            } else if let id = app.selectedSessionID, let session = app.manager.session(id) {
                SessionDetailView(session: session)
                    .id(session.id)
            } else {
                EmptyStateView()
            }
        }
        .sheet(isPresented: $app.isPickerPresented) {
            SourcePickerView()
                .environment(app)
        }
        .alert("PalMeet", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK") { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
        .background(GlassBackground(opacity: app.manager.settings.appearance[.main].backgroundOpacity, material: .windowBackground).ignoresSafeArea())
        .frame(minWidth: 860, minHeight: 560)
        .onHover { app.windows.setHovering(.main, $0) }
        .onAppear { app.manager.refreshLibrary() }
    }

    private var filteredLibrary: [MeetingSession] {
        guard !search.isEmpty else { return app.manager.library }
        let query = search.lowercased()
        return app.manager.library.filter { session in
            session.title.lowercased().contains(query)
                || session.metadata.source.appName.lowercased().contains(query)
                || (session.transcript?.segments.contains { $0.text.lowercased().contains(query) } ?? false)
        }
    }
}

private struct SidebarRow: View {
    let session: MeetingSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.stage.isCapturing ? SessionPalette.color(session.colorIndex) : .secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        let date = session.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch session.stage {
        case .ready: return "\(date) · \(session.metadata.source.appName)"
        default: return session.stage.label
        }
    }
}

private struct EmptyStateView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("No meeting selected", systemImage: "waveform.and.mic")
        } description: {
            Text("Record a Zoom, Teams, Slack or browser meeting. PalMeet transcribes who said what and writes a summary.")
        } actions: {
            Button("Record a meeting") { app.isPickerPresented = true }
                .buttonStyle(.borderedProminent)
            Text("Tip: ⌃⌥R records the meeting window in front.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SessionDetailView: View {
    let session: MeetingSession

    var body: some View {
        if session.stage.isCapturing {
            LiveSessionView(session: session)
        } else {
            ReviewView(session: session)
        }
    }
}
