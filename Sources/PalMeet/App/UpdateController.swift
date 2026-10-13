import AppKit
import LLMKit
import Observation
import Sparkle

/// In-app updates via Sparkle. Updates are EdDSA-signed archives listed in an appcast (Info.plist `SUFeedURL`).
///
/// The feed lives in a private GitHub repository, so requests carry a GitHub token: one saved in Settings →
/// Updates (Keychain) or, by default, the user's existing GitHub CLI login (`gh auth token`, read at check time
/// and never stored). A public feed needs no token.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    enum AccessSource: Equatable {
        case savedToken
        case githubCLI
        case none
    }

    private(set) var canCheckForUpdates = false
    private(set) var accessSource: AccessSource = .none
    private(set) var lastCheck: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let secrets: SecretStore

    static let tokenAccount = "updates.githubToken"

    init(secrets: SecretStore) {
        self.secrets = secrets
        super.init()
    }

    var updater: SPUUpdater? { controller?.updater }

    var feedURL: String { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "" }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Updates only work from a real app bundle with a feed configured (not from `swift run`).
    var isAvailable: Bool { !feedURL.isEmpty && Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Sparkle reports on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        Task {
            await refreshAccess()
            controller.startUpdater()
            lastCheck = controller.updater.lastUpdateCheckDate
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        Task {
            await refreshAccess()
            controller.checkForUpdates(nil)
        }
    }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: - Access to the private feed

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? secrets.deleteSecret(for: Self.tokenAccount)
        } else {
            try? secrets.setSecret(trimmed, for: Self.tokenAccount)
        }
        Task { await refreshAccess() }
    }

    var hasSavedToken: Bool { !(secrets.secret(for: Self.tokenAccount) ?? "").isEmpty }

    /// Sets the Authorization header Sparkle sends with the appcast and update downloads.
    func refreshAccess() async {
        var token = secrets.secret(for: Self.tokenAccount).flatMap { $0.isEmpty ? nil : $0 }
        var source: AccessSource = token == nil ? .none : .savedToken
        if token == nil, let cliToken = await Self.githubCLIToken() {
            token = cliToken
            source = .githubCLI
        }
        accessSource = source
        updater?.httpHeaders = token.map { ["Authorization": "Bearer \($0)"] }
    }

    /// The GitHub CLI's token, if `gh` is installed and logged in. GUI apps don't inherit the shell PATH.
    static func githubCLIToken() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(NSHomeDirectory())/.local/bin/gh"]
            guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }.value
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let message = error.map { ($0 as NSError).localizedDescription }
        MainActor.assumeIsolated {
            self.lastCheck = updater.lastUpdateCheckDate
            // "You're up to date" also arrives as an error code; only keep real failures.
            if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
                self.lastError = message
            } else {
                self.lastError = nil
            }
        }
    }
}
