import CaptureKit
import CopilotKit
import PalMeetCore
import SessionKit
import SwiftUI

struct LiveSessionView: View {
    @Environment(AppState.self) private var app
    @Bindable var session: MeetingSession
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if session.waitingForBrowserClick { browserClickBanner }
            WarningBanner(messages: session.warnings)
            HSplitView {
                TranscriptList(session: session, segments: session.liveSegments, editable: false)
                    .frame(minWidth: 380)
                sidePanel
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Circle().fill(SessionPalette.color(session.colorIndex)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.stage.label)
                    Text("·")
                    ElapsedText(session: session)
                    Text("·")
                    Text(session.metadata.source.displayName).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()

            Picker("Meeting type", selection: Binding(get: { session.meetingMode }, set: { session.setMeetingMode($0) })) {
                ForEach(MeetingMode.allCases) { Text($0.displayName).tag($0) }
            }
            .frame(width: 210)

            Toggle(isOn: Binding(get: { session.copilotEnabled }, set: { enabled in
                session.setCopilot(enabled: enabled)
                if enabled { app.windows.showCopilotPanel() }
            })) {
                Label("Copilot", systemImage: "brain.head.profile")
            }
            .toggleStyle(.button)
            .help("Live suggestions. When off, nothing is analysed or sent. (⌃⌥C)")

            Button {
                Task { await session.markMoment() }
            } label: {
                Label("Mark", systemImage: "camera")
            }
            .help("Mark moment + screenshot (⌃⌥S)")

            Button {
                session.stage == .paused ? session.resume() : session.pause()
            } label: {
                Label(session.stage == .paused ? "Resume" : "Pause", systemImage: session.stage == .paused ? "play.fill" : "pause.fill")
            }

            Button(role: .destructive) {
                app.stop(session)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    /// Chrome only lets an extension record a tab after you click its icon (or press its shortcut) in that window.
    private var browserClickBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.tap.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("The meeting audio isn't being recorded yet").font(.headline)
                Text("In \(session.metadata.source.appName), click the PalMeet icon in the toolbar (it blinks “REC?”) or press ⌥⇧R in the meeting window. Chrome needs this one click per meeting before PalMeet can hear the tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel recording", role: .destructive) { app.stop(session) }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Meeting").frame(width: 70, alignment: .leading)
                            LevelMeter(level: session.themLevel, tint: SessionPalette.color(session.colorIndex))
                            Spacer()
                        }
                        HStack {
                            Text("My mic").frame(width: 70, alignment: .leading)
                            LevelMeter(level: session.meLevel)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { session.micOverride.map { $0 ? 1 : 2 } ?? 0 },
                                set: { app.manager.setMicOverride(session, routed: $0 == 0 ? nil : $0 == 1) }
                            )) {
                                Text("Auto").tag(0)
                                Text("On").tag(1)
                                Text("Off").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                            .disabled(!session.metadata.includesMicrophone)
                        }
                        Text(micStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        if let speakers = session.meetingSpeakerStatus {
                            Label(speakers, systemImage: "captions.bubble")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Meeting context") {
                    TextEditor(text: $session.context)
                        .font(.callout)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                    Text("Agenda, ticket, who's who, names and terms. Add to it anytime. The copilot uses it while on; the summary and spelling fixes use it after. Saved with the meeting.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                GroupBox("Quick note") {
                    HStack {
                        TextField("Timestamped note…", text: $note)
                            .onSubmit(addNote)
                        Button("Add", action: addNote).disabled(note.isEmpty)
                    }
                    ForEach(session.notes.reversed()) { note in
                        Text("[\(Timecode.format(note.offset))] \(note.text)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Screenshots (\(session.screenshots.count))") {
                    ScreenshotStrip(session: session)
                }
            }
        }
    }

    private func addNote() {
        session.addNote(note)
        note = ""
    }

    private var micStatus: String {
        if session.micOverride == false { return "Your mic is off for this meeting (⌃⌥M or “Auto” to turn it back on)." }
        if let call = session.otherCallUsingMic, session.micOverride == nil {
            if call.muted == false {
                return "You're unmuted in \(call.appName), which PalMeet isn't recording, so what you say is left out here. Choose “On” if you're talking in this meeting."
            }
            if session.isMicRouted {
                return "\(call.appName) is also using your mic and PalMeet can't tell which call you're talking in. If you speak in \(call.appName), press ⌃⌥M or choose “Off”."
            }
        }
        if session.knownMuted == true, session.micOverride == nil {
            return "You're muted in the meeting, so PalMeet leaves out what you say until you unmute."
        }
        if session.isMicRouted {
            let blindBrowser = session.metadata.isolation != .browserExtension
                && (MeetingApp.lookup(bundleID: session.metadata.source.bundleID)?.isBrowser ?? false)
            if blindBrowser, session.knownMuted == nil {
                return "Your mic is going to this meeting. PalMeet can't see your mute state in a browser window: press ⌃⌥M while muted, or record the tab with the PalMeet extension."
            }
            return "Your microphone is going to this meeting."
        }
        return "Your microphone is not routed here."
    }
}

struct ScreenshotStrip: View {
    let session: MeetingSession

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(session.screenshots.suffix(12).reversed()) { shot in
                    ThumbnailImage(url: session.folder.url.appending(path: shot.relativePath), maxPixel: 240)
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help("[\(Timecode.format(shot.offset))] \(shot.reason.rawValue)\n\(shot.ocrText.prefix(200))")
                }
            }
        }
    }
}

/// Speaker-attributed transcript list; auto-scrolls while live, editable in review.
struct TranscriptList: View {
    let session: MeetingSession
    let segments: [TranscriptSegment]
    let editable: Bool
    @State private var editing: UUID?
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if segments.isEmpty {
                    Text(session.stage.isCapturing ? "Listening… live text appears here as people speak." : "No speech was transcribed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(segments) { segment in
                    row(segment).id(segment.id)
                }
            }
            .listStyle(.inset)
            .onChange(of: segments.count) {
                if session.stage.isCapturing, let last = segments.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayName(for: segment.speakerID))
                    .font(.callout.bold())
                    .foregroundStyle(SessionPalette.speakerColor(segment.speakerID))
                Text(Timecode.format(segment.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if segment.isEdited { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary) }
                if let original = segment.originalText, !segment.isEdited {
                    Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.secondary)
                        .help("Misheard words corrected by AI. Recognized as: “\(original)”")
                }
            }
            if editing == segment.id {
                TextField("", text: $draft, axis: .vertical)
                    .onSubmit {
                        session.editSegment(segment.id, text: draft)
                        editing = nil
                    }
            } else {
                Text(segment.text).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if editable {
                Button("Edit text") {
                    draft = segment.text
                    editing = segment.id
                }
                if let original = segment.originalText, original != segment.text {
                    Button("Restore original (before AI correction)") { session.editSegment(segment.id, text: original) }
                }
                if let transcript = session.transcript {
                    Menu("Assign to speaker") {
                        ForEach(transcript.speakers) { speaker in
                            Button(speaker.displayName) { session.reassignSegment(segment.id, to: speaker.id) }
                        }
                    }
                }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(Timecode.format(segment.start))] \(session.displayName(for: segment.speakerID)): \(segment.text)", forType: .string)
            }
        }
    }
}
