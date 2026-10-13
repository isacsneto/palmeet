import BrowserBridge
import CaptureKit
import CopilotKit
import KeyboardShortcuts
import LLMKit
import PalMeetCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettings().tabItem { Label("AI Providers", systemImage: "sparkles") }
            CopilotSettingsView().tabItem { Label("Copilot", systemImage: "brain.head.profile") }
            HotkeySettings().tabItem { Label("Hotkeys", systemImage: "keyboard") }
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "eye.slash") }
            AppearanceSettingsView().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            BrowserExtensionSettings().tabItem { Label("Browser Extension", systemImage: "puzzlepiece.extension") }
            PermissionsView().tabItem { Label("Permissions", systemImage: "lock.shield") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 680, height: 560)
    }
}

/// Binding into `AppSettings` that persists on every change.
@MainActor
private func setting<T>(_ app: AppState, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { app.manager.settings[keyPath: keyPath] },
        set: { value in
            app.manager.updateSettings { $0[keyPath: keyPath] = value }
            app.windows.applyAll()
        }
    )
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section("About you (used to spot questions addressed to you)") {
                TextField("Name", text: setting(app, \.profile.name))
                CommaListField(title: "Also called (comma separated)", values: app.manager.settings.profile.aliases) { values in
                    app.manager.updateSettings { $0.profile.aliases = values }
                }
                TextField("Role", text: setting(app, \.profile.role))
                TextField("Team", text: setting(app, \.profile.team))
                TextField("Expertise", text: setting(app, \.profile.expertise))
                TextField("Answer style", text: setting(app, \.profile.communicationStyle))
            }
            Section("Transcription") {
                Picker("Meeting language", selection: setting(app, \.language)) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag(Optional($0.0)) }
                }
                Picker("Speech model (on-device)", selection: setting(app, \.asrModel)) {
                    Text("Parakeet Ultra: most accurate, 25 languages").tag("ultra")
                    Text("Parakeet v3: 25 languages").tag("v3")
                    Text("Parakeet v2: English only").tag("v2English")
                }
                Toggle("Live transcript while recording", isOn: setting(app, \.liveTranscription))
                CommaListField(title: "Glossary (names, product terms; comma separated)", values: app.manager.settings.glossary) { values in
                    app.manager.updateSettings { $0.glossary = values }
                }
            }
            Section("Recording") {
                Toggle("Include my microphone by default", isOn: setting(app, \.includeMicByDefault))
                Picker("Mic routing with several meetings", selection: setting(app, \.micRouting)) {
                    Text("Automatic (mute state, mic use, focus)").tag(MicRoutingMode.auto)
                    Text("Manual (per-meeting toggle)").tag(MicRoutingMode.manual)
                }
                LabeledContent("Screenshot at least every") {
                    Stepper("\(Int(app.manager.settings.screenshotInterval)) s", value: setting(app, \.screenshotInterval), in: 10...120, step: 5)
                }
                LabeledContent("Max meetings at once") {
                    Stepper("\(app.manager.settings.maxConcurrentSessions)", value: setting(app, \.maxConcurrentSessions), in: 1...6)
                }
                LabeledContent("Saved to") {
                    Text(app.manager.store.rootURL.path(percentEncoded: false)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Show") { NSWorkspace.shared.open(app.manager.store.rootURL) }
                }
            }
        }
        .formStyle(.grouped)
    }

    static let languages = [("pt", "Portuguese"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish")]
}

// MARK: - Providers

private struct ProviderSettings: View {
    @Environment(AppState.self) private var app
    @State private var availability: [LLMProviderKind: String] = [:]

    var body: some View {
        Form {
            Section("Which AI to use") {
                Picker("Summaries", selection: setting(app, \.summaryProvider)) {
                    ForEach(LLMProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Live copilot", selection: setting(app, \.copilotProvider)) {
                    ForEach(LLMProviderKind.allCases) { Text($0.displayName + ($0.isCLI ? " (slower)" : "")).tag($0) }
                }
                Text("CLI options reuse your existing login (`claude`, `codex`, `gemini`, `cursor-agent`), so no API key is needed. API providers are faster for the live copilot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(LLMProviderKind.allCases) { kind in
                Section(kind.displayName) {
                    ProviderRow(kind: kind, status: availability[kind]) { status in availability[kind] = status }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderRow: View {
    @Environment(AppState.self) private var app
    let kind: LLMProviderKind
    let status: String?
    let report: (String) -> Void
    @State private var apiKey = ""
    @State private var checking = false

    var body: some View {
        let config = app.manager.settings.providerConfig(kind)
        TextField("Model (summaries)", text: binding(config, \.model), prompt: Text(kind.isCLI ? "CLI default" : kind.defaultModel))
        TextField("Fast model (copilot)", text: binding(config, \.fastModel), prompt: Text(kind.defaultFastModel))
        if kind.needsAPIKey {
            HStack {
                SecureField("API key", text: $apiKey, prompt: Text(hasKey ? "•••••••• (saved in Keychain)" : "Paste API key"))
                Button("Save") {
                    try? app.manager.secrets.setSecret(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.secretAccount)
                    apiKey = ""
                }
                .disabled(apiKey.isEmpty)
                if hasKey {
                    Button("Remove") { try? app.manager.secrets.deleteSecret(for: kind.secretAccount) }
                }
            }
        }
        if kind == .localOpenAICompatible {
            TextField("Server URL", text: Binding(
                get: { config.baseURL ?? "" },
                set: { value in var c = config; c.baseURL = value.isEmpty ? nil : value; app.manager.updateSettings { $0.setProviderConfig(c) } }
            ), prompt: Text("http://localhost:11434/v1"))
        }
        if kind.isCLI {
            TextField("CLI path", text: Binding(
                get: { config.cliPath ?? "" },
                set: { value in var c = config; c.cliPath = value.isEmpty ? nil : value; app.manager.updateSettings { $0.setProviderConfig(c) } }
            ), prompt: Text("Auto-detect"))
        }
        HStack {
            Button(checking ? "Checking…" : "Check") {
                checking = true
                Task {
                    let result = await app.manager.provider(kind).checkAvailability()
                    report(result.isReady ? "✅ Ready" : "⚠️ \(result.userMessage)")
                    checking = false
                }
            }
            .disabled(checking)
            if let status { Text(status).font(.caption) }
        }
    }

    private var hasKey: Bool {
        !(app.manager.secrets.secret(for: kind.secretAccount) ?? "").isEmpty
    }

    private func binding(_ config: LLMProviderConfig, _ keyPath: WritableKeyPath<LLMProviderConfig, String>) -> Binding<String> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in
                var updated = config
                updated[keyPath: keyPath] = value
                app.manager.updateSettings { $0.setProviderConfig(updated) }
            }
        )
    }
}

// MARK: - Copilot

private struct CopilotSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var mode: MeetingMode = .grooming

    var body: some View {
        Form {
            Section {
                Text("The copilot is OFF by default for every meeting. Turn it on per meeting with its 🧠 button or ⌃⌥C. While it's off, nothing is analysed or sent.")
                    .font(.callout)
            }
            Section("Turn on automatically for these meeting types") {
                ForEach(MeetingMode.allCases) { mode in
                    Toggle(mode.displayName, isOn: Binding(
                        get: { app.manager.settings.copilot.autoEnableModes.contains(mode) },
                        set: { on in app.manager.updateSettings { s in
                            if on { s.copilot.autoEnableModes.append(mode) } else { s.copilot.autoEnableModes.removeAll { $0 == mode } }
                        } }
                    ))
                }
            }
            Section("Behaviour") {
                Toggle("Suggest questions to ask proactively", isOn: setting(app, \.copilot.proactiveQuestions))
                LabeledContent("At most one question card every") {
                    Stepper("\(Int(app.manager.settings.copilot.proactiveInterval)) s", value: setting(app, \.copilot.proactiveInterval), in: 30...600, step: 30)
                }
                LabeledContent("Max AI calls per minute") {
                    Stepper("\(app.manager.settings.copilot.maxCallsPerMinute)", value: setting(app, \.copilot.maxCallsPerMinute), in: 1...20)
                }
            }
            Section("Playbooks") {
                Picker("Meeting type", selection: $mode) {
                    ForEach(MeetingMode.allCases) { Text($0.displayName).tag($0) }
                }
                TextEditor(text: Binding(
                    get: { app.manager.settings.copilot.playbook(for: mode) },
                    set: { value in app.manager.updateSettings { $0.copilot.playbookOverrides[mode.rawValue] = value } }
                ))
                .frame(minHeight: 120)
                .font(.callout)
                Button("Reset to default") { app.manager.updateSettings { $0.copilot.playbookOverrides[mode.rawValue] = nil } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys

private struct HotkeySettings: View {
    var body: some View {
        Form {
            ForEach(HotkeyCatalog.groups, id: \.0) { group, entries in
                Section(group) {
                    ForEach(entries) { entry in
                        KeyboardShortcuts.Recorder(entry.title, name: entry.name)
                    }
                }
            }
            Section {
                Button("Reset all to defaults") {
                    KeyboardShortcuts.reset(HotkeyCatalog.groups.flatMap { $0.1.map(\.name) })
                }
                Text("Hotkeys work in any app and don't need the Accessibility permission. With several meetings, they act on the meeting whose window is in front.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettingsView: View {
    @Environment(AppState.self) private var app
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section("Screen sharing") {
                Toggle("Hide PalMeet windows from screen sharing and recording", isOn: setting(app, \.privacy.hideFromScreenCapture))
                Toggle("Also hide them while I'm presenting (detected via the extension)", isOn: setting(app, \.privacy.autoHideWhileSharing))
                HStack {
                    Button(checking ? "Checking…" : "Run invisibility check") {
                        checking = true
                        Task {
                            let outcome = await InvisibilityCheck.run(sharingType: app.manager.settings.privacy.hideFromScreenCapture ? .none : .readOnly)
                            checkResult = outcome.message
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
                if let checkResult { Text(checkResult).font(.callout) }
                Text("Panic hide (⌃⌥\\) hides every PalMeet window instantly; recording continues. Sharing a single window or tab instead of the whole screen always keeps PalMeet out of the share.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Low profile") {
                Toggle("Show Dock icon", isOn: Binding(
                    get: { app.manager.settings.privacy.showDockIcon },
                    set: { value in app.manager.updateSettings { $0.privacy.showDockIcon = value }; app.applyActivationPolicy() }
                ))
                Toggle("Show menu bar icon (otherwise reach PalMeet with hotkeys)", isOn: setting(app, \.privacy.showMenuBarIcon))
            }
            Section("Recordings") {
                Toggle("Keep mic audio that was routed to another meeting", isOn: setting(app, \.privacy.keepUnroutedMicAudio))
                Picker("Delete audio (keep text) after", selection: setting(app, \.privacy.deleteAudioAfterDays)) {
                    Text("Never").tag(Int?.none)
                    Text("7 days").tag(Int?.some(7))
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                }
                Text("Off: when a meeting stops, the parts of your mic track that belonged to other meetings are silenced in this meeting's files.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recording laws differ (one-party vs all-party consent). Tell participants when you record.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            ForEach([AppWindowRole.copilotPanel, .main], id: \.self) { role in
                Section(role.displayName) {
                    slider("Opacity", role, \.contentOpacity, 0.2...1)
                    slider("Background opacity", role, \.backgroundOpacity, 0...1)
                    Toggle("Click-through (clicks go to the window behind)", isOn: appearanceBinding(role, \.clickThrough))
                    Toggle("Always on top", isOn: appearanceBinding(role, \.alwaysOnTop))
                    Toggle("Fade when the mouse is away", isOn: appearanceBinding(role, \.autoFade))
                    if app.manager.settings.appearance[role].autoFade {
                        slider("Faded opacity", role, \.fadedOpacity, 0.1...0.8)
                    }
                }
            }
            Section("Text") {
                slider("Text size", nil, nil, 0.8...1.5)
            }
            Section {
                Text("Hotkeys: ⌃⌥↑ / ⌃⌥↓ opacity, ⌃⌥0 reset, ⌃⌥T click-through. They act on the copilot panel when it's visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func appearanceBinding<T>(_ role: AppWindowRole, _ keyPath: WritableKeyPath<WindowAppearance, T>) -> Binding<T> {
        Binding(
            get: { app.manager.settings.appearance[role][keyPath: keyPath] },
            set: { value in
                app.manager.updateSettings { $0.appearance[role][keyPath: keyPath] = value }
                app.windows.applyAll()
            }
        )
    }

    private func slider(_ title: String, _ role: AppWindowRole?, _ keyPath: WritableKeyPath<WindowAppearance, Double>?, _ range: ClosedRange<Double>) -> some View {
        let binding: Binding<Double> = if let role, let keyPath {
            appearanceBinding(role, keyPath)
        } else {
            setting(app, \.appearance.fontScale)
        }
        return LabeledContent(title) {
            HStack {
                Slider(value: binding, in: range)
                Text("\(Int(binding.wrappedValue * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Browser extension

private struct BrowserExtensionSettings: View {
    @Environment(AppState.self) private var app
    @State private var installMessage: String?

    var body: some View {
        Form {
            Section("Why") {
                Text("Chrome (and Edge, Brave, Arc) play every tab's audio through one shared process, even across profiles. To record a meeting tab in one Chrome window and another meeting in a different window or profile, install the PalMeet extension in each profile. It captures only the tab you choose.")
                    .font(.callout)
            }
            Section("Setup") {
                LabeledContent("1. Connect PalMeet to your browsers") {
                    Button("Install connector") {
                        do {
                            let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
                            let written = try NativeHostInstaller.install(hostExecutablePath: path)
                            installMessage = written.isEmpty ? "No supported browser found." : "Installed for: \(NativeHostInstaller.installedBrowsers().joined(separator: ", "))"
                        } catch {
                            installMessage = "Failed: \(error.localizedDescription)"
                        }
                    }
                }
                if let installMessage { Text(installMessage).font(.caption) }
                LabeledContent("2. Load the extension in each profile") {
                    Button("Show extension folder") { revealExtension() }
                }
                Text("In chrome://extensions turn on Developer mode → Load unpacked → pick the folder. Repeat in every profile you use for meetings. Then click the PalMeet icon in a meeting tab, or start from the PalMeet picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Local bridge") {
                    Text(app.manager.bridgePort.map { "Listening on 127.0.0.1:\($0)" } ?? "Not running")
                }
                if app.manager.browserProfiles.isEmpty {
                    Text("No browser profile connected yet.").foregroundStyle(.secondary)
                }
                ForEach(app.manager.browserProfiles) { profile in
                    LabeledContent("\(profile.browser) · \(profile.label)") {
                        Text("\(profile.windows.count) window(s), \(profile.windows.flatMap(\.meetingTabs).count) meeting tab(s)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func revealExtension() {
        let bundled = ["ChromeExtension", "chromium"].compactMap { Bundle.main.resourceURL?.appending(path: $0) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../Extension/chromium").standardized
        let url = (bundled + [source]).first { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @State private var states: [PermissionKind: PermissionState] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    let state = states[kind] ?? Permissions.state(of: kind)
                    HStack(alignment: .top) {
                        Image(systemName: icon(state)).foregroundStyle(color(state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.callout.weight(.medium))
                            Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(state == .granted ? "Granted" : "Grant…") {
                            Task {
                                await Permissions.request(kind)
                                refresh()
                            }
                        }
                        .disabled(state == .granted)
                    }
                }
            } footer: {
                Text("System audio recording is requested the first time PalMeet records a meeting app.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        let latest = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, Permissions.state(of: $0)) })
        if latest != states { states = latest }
    }

    private func icon(_ state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .notDetermined: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(_ state: PermissionState) -> Color {
        switch state {
        case .granted: .green
        case .denied: .red
        default: .secondary
        }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @Environment(AppState.self) private var app
    @State private var token = ""
    @State private var automaticChecks = false
    @State private var automaticDownloads = false

    var body: some View {
        let updates = app.updates
        Form {
            Section {
                LabeledContent("Installed version", value: updates.currentVersion)
                if updates.isAvailable {
                    HStack {
                        Button("Check for Updates…") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                        if let lastCheck = updates.lastCheck {
                            Text("Last checked \(lastCheck.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = updates.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Check for updates automatically", isOn: $automaticChecks)
                        .onChange(of: automaticChecks) { updates.automaticallyChecks = automaticChecks }
                    Toggle("Download and install updates automatically", isOn: $automaticDownloads)
                        .onChange(of: automaticDownloads) { updates.automaticallyDownloads = automaticDownloads }
                } else {
                    Text("Updates are available in the installed app (/Applications/PalMeet.app), not in development builds.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Access to the private update feed") {
                LabeledContent("Feed") {
                    Text(updates.feedURL).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                LabeledContent("Using") {
                    switch updates.accessSource {
                    case .savedToken: Text("Saved token (Keychain)")
                    case .githubCLI: Text("Your GitHub CLI login (gh)")
                    case .none: Text("No access: log in with `gh auth login` or save a token").foregroundStyle(.orange)
                    }
                }
                HStack {
                    SecureField("GitHub token (read-only access to the repo)", text: $token, prompt: Text(updates.hasSavedToken ? "•••••••• saved" : "Optional"))
                    Button("Save") { updates.saveToken(token); token = "" }.disabled(token.isEmpty)
                    if updates.hasSavedToken {
                        Button("Remove") { updates.saveToken("") }
                    }
                }
                Text("Updates are signed (EdDSA) and verified before installing. If the repository becomes public, no token is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            automaticChecks = updates.automaticallyChecks
            automaticDownloads = updates.automaticallyDownloads
        }
    }
}
