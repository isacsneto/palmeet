import LLMKit
import PalMeetCore
import SwiftUI

/// First-run setup: permissions, who you are, and which AI to use.
struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to PalMeet").font(.largeTitle.bold())
                Text("Record any meeting window (Zoom, Teams, Slack, Meet), get a speaker-attributed transcript, a Markdown summary, and optional live suggestions. Audio is transcribed on this Mac.")
                    .foregroundStyle(.secondary)

                GroupBox("1. Permissions") {
                    PermissionsView().frame(height: 260)
                }

                GroupBox("2. About you") {
                    VStack(alignment: .leading) {
                        TextField("Your name", text: Binding(
                            get: { app.manager.settings.profile.name },
                            set: { value in app.manager.updateSettings { $0.profile.name = value } }
                        ))
                        Text("Used to label your lines and to notice when someone asks you something.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("3. AI for summaries") {
                    VStack(alignment: .leading) {
                        Picker("Provider", selection: Binding(
                            get: { app.manager.settings.summaryProvider },
                            set: { value in app.manager.updateSettings { $0.summaryProvider = value } }
                        )) {
                            ForEach(LLMProviderKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        Text("Claude Code, Codex, Gemini and Cursor CLIs reuse your existing login. API providers need a key (Settings → AI Providers).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        app.manager.updateSettings { $0.hasCompletedOnboarding = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: 720)
        }
    }
}
