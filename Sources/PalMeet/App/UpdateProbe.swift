import AppKit
import Foundation
import Sparkle

/// `PalMeet --update-probe <report.json>`: checks the update feed without UI (feed access, appcast parsing,
/// version comparison) and writes what it found. Used by the release script to verify a published update.
@MainActor
final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    private let reportPath: String
    private var updater: SPUUpdater?
    private var report: [String: String] = [:]

    static var reportPath: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--update-probe"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    init(reportPath: String) {
        self.reportPath = reportPath
    }

    func run() async {
        let info = Bundle.main.infoDictionary ?? [:]
        report["installedVersion"] = info["CFBundleShortVersionString"] as? String
        report["installedBuild"] = info["CFBundleVersion"] as? String
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SilentUserDriver(), delegate: self)
        self.updater = updater
        let token = await UpdateController.githubCLIToken()
        report["access"] = token == nil ? "none" : "github-cli"
        updater.httpHeaders = token.map { ["Authorization": "Bearer \($0)"] }
        do {
            try updater.start()
            updater.checkForUpdateInformation()
        } catch {
            finish(["result": "error", "error": error.localizedDescription])
        }
        try? await Task.sleep(for: .seconds(60))
        finish(["result": "timeout"])
    }

    private func finish(_ values: [String: String]) {
        report.merge(values) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath))
        }
        NSApp.terminate(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateController.freshFeedURL()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString, build = item.versionString
        MainActor.assumeIsolated { finish(["result": "updateAvailable", "availableVersion": version, "availableBuild": build]) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(["result": "upToDate", "detail": message]) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let message = (error as NSError).localizedDescription
        MainActor.assumeIsolated { finish(["result": "error", "error": message]) }
    }
}

/// A user driver that never shows UI (probe only performs information checks).
private final class SilentUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice { .dismiss }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error) async {}
    func showUpdaterError(_ error: any Error) async {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice { .dismiss }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
