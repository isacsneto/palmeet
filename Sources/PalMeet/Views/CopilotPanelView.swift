import CopilotKit
import KeyboardShortcuts
import PalMeetCore
import SessionKit
import SwiftUI

/// Floating, non-activating panel with live suggestions. Hidden from screen sharing like every PalMeet window.
struct CopilotPanelView: View {
    @Environment(AppState.self) private var app
    @State private var collapsed = false

    var body: some View {
        let appearance = app.manager.settings.appearance[.copilotPanel]
        VStack(alignment: .leading, spacing: 8) {
            header(appearance)
            if !collapsed {
                if let session {
                    content(for: session)
                } else {
                    ContentUnavailableView("No meeting is recording", systemImage: "waveform.slash",
                                           description: Text("Start a recording, then turn on the copilot for it (⌃⌥C)."))
                }
            }
        }
        .padding(10)
        .padding(.top, 14)
        .background(GlassBackground(opacity: appearance.backgroundOpacity).ignoresSafeArea())
        .font(.system(size: 13 * app.manager.settings.appearance.fontScale))
        .onHover { app.windows.setHovering(.copilotPanel, $0) }
        .onChange(of: newestSuggestionID) { app.windows.boostVisibility() }
    }

    private var sessions: [MeetingSession] { app.manager.activeSessions }

    /// The picked session, else the meeting in front (refreshed by the window controller once a second).
    private var session: MeetingSession? {
        if let picked = app.windows.panelSessionID, let match = sessions.first(where: { $0.id == picked }) { return match }
        if let front = app.windows.frontmostSessionID, let match = sessions.first(where: { $0.id == front }) { return match }
        return sessions.last
    }

    private var newestSuggestionID: UUID? {
        session?.suggestions.last?.id
    }

    private func header(_ appearance: WindowAppearance) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile").foregroundStyle(.secondary)
                if sessions.count > 1 {
                    Picker("", selection: Binding(get: { session?.id }, set: { app.windows.panelSessionID = $0; app.windows.focusedCardIndex = 0 })) {
                        ForEach(sessions) { s in
                            Text(s.title).tag(Optional(s.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                } else {
                    Text(session?.title ?? "Copilot").font(.headline).lineLimit(1)
                }
                Spacer()
                Button {
                    app.windows.toggleClickThrough()
                } label: {
                    Image(systemName: appearance.clickThrough ? "cursorarrow.slash" : "cursorarrow")
                }
                .help("Click-through (⌃⌥T)")
                Button {
                    collapsed.toggle()
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                }
                .help("Collapse")
            }
            .buttonStyle(.borderless)

            if !collapsed {
                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { appearance.contentOpacity },
                        set: { value in
                            app.manager.updateSettings { $0.appearance[.copilotPanel].contentOpacity = value }
                            app.windows.applyAll()
                        }
                    ), in: 0.2...1)
                    .controlSize(.mini)
                    .help("Opacity (⌃⌥↑ / ⌃⌥↓)")
                    Image(systemName: "square.on.square.dashed").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { appearance.backgroundOpacity },
                        set: { value in app.manager.updateSettings { $0.appearance[.copilotPanel].backgroundOpacity = value } }
                    ), in: 0...1)
                    .controlSize(.mini)
                    .help("Background opacity")
                }
            }
        }
    }

    @ViewBuilder
    private func content(for session: MeetingSession) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { session.copilotEnabled }, set: { session.setCopilot(enabled: $0) })) {
                Text(session.copilotEnabled ? "Copilot ON" : "Copilot OFF").font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            if session.copilotEnabled {
                Button("Help me now") { session.copilotHelpNow() }
                    .controlSize(.small)
                    .help("⌃⌥H")
            }
        }

        if !session.copilotEnabled {
            Text("Off: nothing from this meeting is analysed or sent to an AI provider. Turn it on to get suggested answers and questions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            let cards = session.visibleCards
            let focused = min(app.windows.focusedCardIndex, max(0, cards.count - 1))
            if cards.isEmpty {
                Text("Listening… Suggestions appear when someone asks you something or when there's a good moment to ask a question.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                // Copy hotkeys (⌃⌥1/2/3) act on the focused card; ⌃⌥[ / ⌃⌥] move the focus.
                                SuggestionCard(session: session, suggestion: card, number: index == focused && card.kind != .reminder ? 1 : nil)
                                    .id(card.id)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.accentColor, lineWidth: index == focused && cards.count > 1 ? 1.5 : 0)
                                    )
                            }
                        }
                    }
                    .onChange(of: app.windows.focusedCardIndex) {
                        guard !cards.isEmpty else { return }
                        let index = min(app.windows.focusedCardIndex, cards.count - 1)
                        withAnimation { proxy.scrollTo(cards[index].id, anchor: .top) }
                    }
                    .onChange(of: cards.first?.id) { app.windows.focusedCardIndex = 0 }
                }
            }
            if session.copilotUsage.inputTokens > 0 {
                Text("Usage: \(session.copilotUsage.inputTokens + session.copilotUsage.outputTokens) tokens")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

}

struct SuggestionCard: View {
    let session: MeetingSession
    let suggestion: Suggestion
    /// Shows ⌃⌥1/2/3 hints on the newest card.
    let number: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(Timecode.format(suggestion.offset)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }

            ForEach(Array(suggestion.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    Text(number != nil && index < 3 ? "⌃⌥\(index + 1)" : "\(index + 1).")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).textSelection(.enabled)
                        if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if let confidence = item.confidence {
                        Circle().fill(confidenceColor(confidence)).frame(width: 6, height: 6).help("\(confidence) confidence")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        session.updateSuggestion(suggestion.id, status: .used)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }

            ForEach(suggestion.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(suggestion.followUps, id: \.self) { followUp in
                Label(followUp, systemImage: "arrow.uturn.left").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { session.updateSuggestion(suggestion.id, status: suggestion.status == .pinned ? .ready : .pinned) } label: {
                    Image(systemName: suggestion.status == .pinned ? "pin.fill" : "pin")
                }
                .help("Pin")
                Button { session.updateSuggestion(suggestion.id, feedback: 1) } label: {
                    Image(systemName: suggestion.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                Button { session.updateSuggestion(suggestion.id, feedback: -1) } label: {
                    Image(systemName: suggestion.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                Spacer()
                if suggestion.status == .streaming { ProgressView().controlSize(.mini) }
                if suggestion.status == .used { Text("used").font(.caption2).foregroundStyle(.secondary) }
                Button { session.updateSuggestion(suggestion.id, status: .dismissed) } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch suggestion.kind {
        case .answer: "bubble.left.and.text.bubble.right"
        case .questions: "lightbulb"
        case .reminder: "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch suggestion.kind {
        case .answer: .blue
        case .questions: .yellow
        case .reminder: .orange
        }
    }

    private var title: String {
        switch suggestion.kind {
        case .answer: "\(suggestion.askedBy ?? "Someone") asked: “\(suggestion.triggerText ?? "")”"
        case .questions: "Questions to ask"
        case .reminder: "Still unanswered, from \(suggestion.askedBy ?? "someone")"
        }
    }

    private func confidenceColor(_ value: String) -> Color {
        switch value {
        case "high": .green
        case "medium": .yellow
        default: .gray
        }
    }
}

struct QuickNoteView: View {
    @Environment(AppState.self) private var app
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Image(systemName: "note.text").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if let id = app.quickNoteSessionID { app.manager.session(id)?.addNote(text) }
                    text = ""
                    close()
                }
                .onExitCommand(perform: close)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground(opacity: 0.95).ignoresSafeArea())
        .onAppear { focused = true }
    }

    private var placeholder: String {
        let title = app.quickNoteSessionID.flatMap { app.manager.session($0)?.title } ?? "meeting"
        return "Note for “\(title)” (Return to save, Esc to cancel)"
    }
}

struct CheatSheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PalMeet shortcuts").font(.title3.bold())
                ForEach(HotkeyCatalog.groups, id: \.0) { group, entries in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group).font(.headline)
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text(KeyboardShortcuts.getShortcut(for: entry.name)?.description ?? "—")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Change them in Settings → Hotkeys.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .padding(.top, 10)
        }
        .background(GlassBackground(opacity: 0.95).ignoresSafeArea())
    }
}
