import BrowserBridge
import Foundation

// When Chrome launches PalMeet as the native-messaging host for the companion extension, answer the pairing
// request and exit without starting the UI.
if NativeMessagingHost.runIfInvoked(arguments: CommandLine.arguments) {
    exit(0)
}

// `PalMeet --install-connector`: register this binary as the browsers' native-messaging host (used by the
// installer so the connector points at /Applications/PalMeet.app).
if CommandLine.arguments.contains("--install-connector") {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    do {
        let written = try NativeHostInstaller.install(hostExecutablePath: path)
        print("Browser connector installed for: \(NativeHostInstaller.installedBrowsers().joined(separator: ", ")) (\(written.count) manifest(s))")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Connector install failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

PalMeetApp.main()
