import CopilotKit
import LLMKit
import PalMeetCore
import SessionKit
import SwiftUI

/// Finished (or processing) meeting: summary, editable transcript, screenshots, copilot history, files.
struct ReviewView: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession
    @State private var tab = Tab.summary
    /// summary.md read once per summary change, not on every render.
    @State private var summaryMarkdown: String?

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case screenshots = "Screenshots"
        case copilot = "Copilot"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            WarningBanner(messages: session.warnings + (session.metadata.lastError.map { [$0] } ?? []))
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            switch tab {
            case .summary: summaryTab
            case .transcript: transcriptTab
            case .screenshots: screenshotsTab
            case .copilot: copilotTab
            }
        }
        .padding(16)
        .task(id: session.summary) {
            summaryMarkdown = session.summary == nil ? nil : try? String(contentsOf: session.folder.summaryMarkdownURL, encoding: .utf8)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.title2.bold()).lineLimit(1)
                Text("\(session.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Timecode.format(session.elapsed)) · \(session.metadata.source.displayName)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isProcessing {
                ProgressView().controlSize(.small)
                Text(session.stage.label).foregroundStyle(.secondary)
            }
            if canReprocess {
                Button("Transcribe now") { Task { await session.reprocess() } }
            }
            Menu {
                ForEach(LLMProviderKind.allCases) { kind in
                    Button(kind.displayName) { Task { await session.summarize(using: kind) } }
                }
                Divider()
                Button("Fix misheard words, then regenerate") {
                    Task { await session.summarize(using: app.manager.workingSummaryProvider, proofread: true) }
                }
            } label: {
                Label("Regenerate summary", systemImage: "sparkles")
            }
            .disabled(session.transcript == nil || isProcessing)
            .fixedSize()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([session.folder.summaryMarkdownURL])
            } label: {
                Label("Show files", systemImage: "folder")
            }
        }
    }

    private var isProcessing: Bool {
        switch session.stage {
        case .finishing, .transcribing, .summarizing: true
        default: false
        }
    }

    private var canReprocess: Bool {
        if case .failed = session.stage { return true }
        return false
    }

    // MARK: Tabs

    @ViewBuilder
    private var summaryTab: some View {
        if let markdown = summaryMarkdown, session.summary != nil {
            ScrollView {
                MarkdownView(markdown: markdown, baseURL: session.folder.url)
                    .padding(.horizontal, 4)
            }
            HStack {
                Button("Copy Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                Button("Open summary.md") { NSWorkspace.shared.open(session.folder.summaryMarkdownURL) }
            }
        } else if isProcessing {
            ContentUnavailableView(session.stage.label, systemImage: "hourglass", description: Text("The transcript and summary appear here when processing finishes."))
        } else {
            ContentUnavailableView("No summary yet", systemImage: "doc.text", description: Text("Use “Regenerate summary” to create one with any configured AI provider."))
        }
    }

    @ViewBuilder
    private var transcriptTab: some View {
        if let transcript = session.transcript {
            SpeakerChips(session: session, transcript: transcript)
            TranscriptList(session: session, segments: transcript.segments, editable: true)
        } else {
            TranscriptList(session: session, segments: session.liveSegments, editable: false)
        }
    }

    private var screenshotsTab: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(session.screenshots) { shot in
                    VStack(alignment: .leading, spacing: 4) {
                        ThumbnailImage(url: session.folder.url.appending(path: shot.relativePath))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("[\(Timecode.format(shot.offset))] \(shot.reason.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                    .help(shot.ocrText)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(session.folder.url.appending(path: shot.relativePath)) }
                }
            }
        }
    }

    @ViewBuilder
    private var copilotTab: some View {
        if session.suggestions.isEmpty {
            ContentUnavailableView("No copilot suggestions", systemImage: "brain.head.profile", description: Text("The copilot was off for this meeting."))
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(session.suggestions.reversed()) { SuggestionCard(session: session, suggestion: $0, number: nil) }
                }
            }
        }
    }
}

/// Speakers with click-to-rename (one rename updates the whole transcript and summary).
private struct SpeakerChips: View {
    let session: MeetingSession
    let transcript: Transcript
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(transcript.speakers) { speaker in
                    Button {
                        draft = speaker.displayName
                        renaming = speaker.id
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(SessionPalette.speakerColor(speaker.id)).frame(width: 8, height: 8)
                            Text(speaker.displayName)
                            if let source = speaker.nameSource, source != "user" {
                                Image(systemName: Self.icon(for: source))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help(Self.explanation(for: source))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quinary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { renaming == speaker.id }, set: { if !$0 { renaming = nil } })) {
                        HStack {
                            TextField("Name", text: $draft).frame(width: 180).onSubmit(commit)
                            Button("Rename", action: commit)
                        }
                        .padding()
                    }
                }
            }
        }
    }

    private func commit() {
        if let renaming, !draft.isEmpty { session.renameSpeaker(renaming, to: draft) }
        renaming = nil
    }

    static func icon(for source: String) -> String {
        switch source {
        case "meeting": "captions.bubble"
        case "voice": "waveform"
        case "screenshot": "camera.viewfinder"
        default: "sparkles"
        }
    }

    static func explanation(for source: String) -> String {
        switch source {
        case "meeting": "Named by the meeting itself (its live captions). Click to change."
        case "voice": "Recognized by voice from an earlier meeting. Click to correct; PalMeet learns from it."
        case "screenshot": "Name seen on screen. Click to change."
        default: "Name suggested by AI from what was said. Click to change; naming someone teaches PalMeet their voice."
        }
    }
}
