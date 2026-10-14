import Foundation
import Testing
@testable import BrowserBridge

/// Reads a fake Chrome user-data folder laid out like the real one.
@Suite struct InstalledBrowserProfilesTests {
    let id = BrowserExtension.defaultExtensionID

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func findsProfilesAndExtensionState() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "palmeet-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let chrome = support.appending(path: "Google/Chrome")
        try write(["profile": ["info_cache": [
            "Default": ["name": "Isac", "user_name": "isac@example.com", "active_time": 1_700_000_000.0],
            "Profile 3": ["name": "Work", "active_time": 1_800_000_000.0],
            "Profile 7": ["name": "Old", "active_time": 1_600_000_000.0],
            "Profile 9": ["name": "Deleted folder"],
        ]]], to: chrome.appending(path: "Local State"))
        // Installed + enabled (Secure Preferences), disabled (Preferences, list form), not installed.
        try write(["extensions": ["settings": [id: ["path": "/x", "state": 1]]]], to: chrome.appending(path: "Profile 3/Secure Preferences"))
        try write(["extensions": ["settings": [id: ["path": "/x", "disable_reasons": [1]]]]], to: chrome.appending(path: "Default/Preferences"))
        try write(["extensions": ["settings": ["someotherextension": [:]]]], to: chrome.appending(path: "Profile 7/Secure Preferences"))

        let profiles = InstalledBrowserProfiles.scan(applicationSupport: support, extensionID: id)
        #expect(profiles.map(\.directory) == ["Profile 3", "Default", "Profile 7"], "most recently used first; missing folders skipped")
        #expect(profiles[0].extensionInstalled && profiles[0].extensionEnabled)
        #expect(profiles[1].extensionInstalled && !profiles[1].extensionEnabled)
        #expect(profiles[1].displayName == "Isac (isac@example.com)")
        #expect(!profiles[2].extensionInstalled)
        #expect(profiles.allSatisfy { $0.browser == "Google Chrome" && $0.bundleID == "com.google.Chrome" })
    }

    @Test func noBrowsersMeansNoProfiles() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "palmeet-none-\(UUID().uuidString)")
        #expect(InstalledBrowserProfiles.scan(applicationSupport: empty).isEmpty)
    }

    @Test func enabledFlagVariants() {
        #expect(InstalledBrowserProfiles.isEnabled([:]))
        #expect(InstalledBrowserProfiles.isEnabled(["state": 1, "disable_reasons": 0]))
        #expect(!InstalledBrowserProfiles.isEnabled(["disable_reasons": 8192]))
        #expect(!InstalledBrowserProfiles.isEnabled(["disable_reasons": [1]]))
        #expect(!InstalledBrowserProfiles.isEnabled(["state": 0]))
    }
}
