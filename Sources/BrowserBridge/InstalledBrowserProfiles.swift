import Foundation

/// A browser profile on disk and whether the PalMeet extension is installed in it.
public struct BrowserProfileInstall: Identifiable, Sendable, Hashable {
    public var browser: String
    public var bundleID: String
    /// Profile folder name inside the browser's user-data directory ("Default", "Profile 3").
    public var directory: String
    /// The name shown in the browser's profile menu.
    public var name: String
    /// The signed-in account, if any (helps tell "Person 1" profiles apart).
    public var account: String?
    public var extensionInstalled: Bool
    public var extensionEnabled: Bool
    /// Last time the profile was used, for sorting.
    public var lastUsed: Date?

    public var id: String { "\(bundleID)/\(directory)" }

    public var displayName: String {
        var label = name.isEmpty ? directory : name
        if let account, !account.isEmpty { label += " (\(account))" }
        return label
    }
}

/// Reads Chromium browsers' profile list (`Local State`) and each profile's extension settings, so PalMeet can
/// show which profiles still need the extension. Read-only; nothing in the browser's folders is modified.
public enum InstalledBrowserProfiles {
    public struct Browser: Sendable {
        public var name: String
        public var bundleID: String
        /// User-data directory relative to `~/Library/Application Support`.
        public var userDataPath: String
    }

    public static let browsers: [Browser] = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", userDataPath: "Google/Chrome"),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", userDataPath: "Microsoft Edge"),
        Browser(name: "Brave", bundleID: "com.brave.Browser", userDataPath: "BraveSoftware/Brave-Browser"),
    ]

    /// All profiles of every installed Chromium browser, most recently used first within each browser.
    public static func scan(
        applicationSupport: URL = URL.applicationSupportDirectory,
        extensionID: String = BrowserExtension.defaultExtensionID
    ) -> [BrowserProfileInstall] {
        browsers.flatMap { browser in
            profiles(of: browser, userDataDirectory: applicationSupport.appending(path: browser.userDataPath), extensionID: extensionID)
        }
    }

    static func profiles(of browser: Browser, userDataDirectory: URL, extensionID: String) -> [BrowserProfileInstall] {
        guard let localState = readJSON(userDataDirectory.appending(path: "Local State")),
              let cache = (localState["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [] }
        let result = cache.compactMap { directory, value -> BrowserProfileInstall? in
            guard let info = value as? [String: Any] else { return nil }
            let folder = userDataDirectory.appending(path: directory, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            let state = extensionState(profileDirectory: folder, extensionID: extensionID)
            let account = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let lastUsed = (info["active_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return BrowserProfileInstall(
                browser: browser.name, bundleID: browser.bundleID, directory: directory,
                name: (info["name"] as? String) ?? directory, account: account,
                extensionInstalled: state.installed, extensionEnabled: state.enabled, lastUsed: lastUsed
            )
        }
        return result.sorted { ($0.lastUsed ?? .distantPast, $1.directory) > ($1.lastUsed ?? .distantPast, $0.directory) }
    }

    /// Chrome keeps extension settings in `Secure Preferences` (or `Preferences` on some setups).
    static func extensionState(profileDirectory: URL, extensionID: String) -> (installed: Bool, enabled: Bool) {
        for file in ["Secure Preferences", "Preferences"] {
            guard let prefs = readJSON(profileDirectory.appending(path: file)),
                  let settings = (prefs["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                  let entry = settings[extensionID] as? [String: Any]
            else { continue }
            return (true, isEnabled(entry))
        }
        return (false, false)
    }

    /// `disable_reasons` (an int bitmask in older versions, a list in newer ones) or `state == 0` mean disabled.
    static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { return false }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let state = entry["state"] as? Int, state == 0 { return false }
        return true
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
