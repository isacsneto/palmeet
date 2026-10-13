import BrowserBridge
import CaptureKit
import PalMeetCore
import SwiftUI

/// Pick one or more meetings to record. Shows each source's audio-isolation status before starting.
struct SourcePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [CapturableWindow] = []
    @State private var selection: [SourceChoice] = []
    @State private var includeMic = true
    @State private var showAllWindows = false
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Record meetings").font(.title2.bold())
                Spacer()
                Toggle("Show all windows", isOn: $showAllWindows).toggleStyle(.switch).controlSize(.small)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }

            if let loadError {
                PermissionHint(message: loadError)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !browserChoices.isEmpty {
                        section("Browser meeting tabs (via extension, one per window)", browserChoices)
                    }
                    section("Meeting apps", appChoices.filter(isMeeting))
                    if showAllWindows {
                        section("Other windows", appChoices.filter { !isMeeting($0) })
                    }
                    ExtensionStatusView()
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if loading { ProgressView() }
            }

            Divider()

            HStack {
                Toggle("Include my microphone", isOn: $includeMic)
                Spacer()
                Text(selection.isEmpty ? "Select one or more meetings" : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    app.start(selection, includeMicrophone: includeMic)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 820, height: 620)
        .task {
            includeMic = app.manager.settings.includeMicByDefault
            await load()
        }
    }

    private var browserChoices: [SourceChoice] {
        app.manager.browserMeetingChoices(windows: windows)
    }

    /// Browser windows already offered as extension tabs are not repeated as plain windows.
    private var appChoices: [SourceChoice] {
        let tabWindowIDs = Set(browserChoices.compactMap { choice -> CGWindowID? in
            if case .browserTab(_, _, _, let id) = choice { return id }
            return nil
        })
        return windows.filter { !tabWindowIDs.contains($0.id) }.map(SourceChoice.window)
    }

    private func isMeeting(_ choice: SourceChoice) -> Bool {
        if case .window(let window) = choice { return window.isMeetingApp }
        return true
    }

    @ViewBuilder
    private func section(_ title: String, _ choices: [SourceChoice]) -> some View {
        if !choices.isEmpty {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(choices) { choice in
                    SourceCard(choice: choice, isSelected: selection.contains(choice), preview: app.manager.isolationPreview(for: choice)) {
                        if let index = selection.firstIndex(of: choice) {
                            selection.remove(at: index)
                        } else {
                            selection.append(choice)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            windows = try await app.manager.availableWindows()
            loadError = nil
        } catch {
            loadError = "PalMeet needs Screen & System Audio Recording permission to list windows. \(error.localizedDescription)"
        }
    }
}

private struct SourceCard: View {
    let choice: SourceChoice
    let isSelected: Bool
    let preview: IsolationPreview
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quinary)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primary).font(.callout.weight(.medium)).lineLimit(1)
                        Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(preview.symbol).help(preview.explanation)
                }
                Text(preview.explanation).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: choice.id) { await loadThumbnail() }
    }

    private var icon: String {
        if case .browserTab = choice { return "globe" }
        return "macwindow"
    }

    private var primary: String {
        switch choice {
        case .window(let window): window.appName
        case .browserTab(let profile, _, _, _): "\(profile.browser) · \(profile.label)"
        }
    }

    private var secondary: String {
        switch choice {
        case .window(let window): window.title.isEmpty ? "Untitled window" : window.title
        case .browserTab(_, _, let tab, _): tab.title
        }
    }

    private func loadThumbnail() async {
        let windowID: CGWindowID? = switch choice {
        case .window(let window): window.id
        case .browserTab(_, _, _, let id): id
        }
        guard let windowID, let image = try? await ShareableSources.thumbnail(windowID: windowID) else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Explains the companion extension and shows which browser profiles are paired.
struct ExtensionStatusView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if app.manager.browserProfiles.isEmpty {
                    Text("Recording two meetings in the same browser (e.g. two Chrome profiles)? Install the PalMeet extension in each profile so every meeting tab's audio stays separate. Settings → Browser Extension.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.manager.browserProfiles) { profile in
                        Label("\(profile.browser) · \(profile.label): \(profile.windows.flatMap(\.meetingTabs).count) meeting tab(s)", systemImage: "puzzlepiece.extension.fill")
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Browser extension", systemImage: "puzzlepiece.extension")
        }
    }
}

struct PermissionHint: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button("Open Settings") {
                Task { await Permissions.request(.screenRecording) }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
