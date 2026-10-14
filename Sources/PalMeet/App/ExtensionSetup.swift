import AppKit
import BrowserBridge
import Foundation

/// Guides installing the companion extension in one specific browser profile.
///
/// Browsers refuse to open `chrome://extensions` from outside, so PalMeet opens the chosen profile on a local
/// instructions page with copy buttons for the two things to paste (the extensions page address, the folder path).
enum ExtensionSetup {
    static var pageURL: URL {
        URL.applicationSupportDirectory.appending(path: "PalMeet/Extension Setup.html")
    }

    /// Opens `profile` in its browser on the setup page. Returns false if the browser couldn't be launched.
    @MainActor
    @discardableResult
    static func open(_ profile: BrowserProfileInstall) -> Bool {
        guard let folder = ChromeExtensionFolder.refresh(),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleID)
        else { return false }
        let extensionsPage = profile.bundleID == "com.microsoft.edgemac" ? "edge://extensions" : (profile.bundleID == "com.brave.Browser" ? "brave://extensions" : "chrome://extensions")
        do {
            try FileManager.default.createDirectory(at: pageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try page(profileName: profile.displayName, browser: profile.browser, extensionsPage: extensionsPage, folderPath: folder.path(percentEncoded: false))
                .write(to: pageURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        // `open -n` hands the arguments to the running browser, which opens a window in that profile.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", appURL.path, "--args", "--profile-directory=\(profile.directory)", pageURL.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    static func page(profileName: String, browser: String, extensionsPage: String, folderPath: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Add PalMeet to this profile</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --bg: #f7f7fb; --card: #fff; --text: #1d1d28; --muted: #6a6a7a; --accent: #4f46e5; --border: #e3e3ee; }
        @media (prefers-color-scheme: dark) { :root { --bg: #15151c; --card: #1f1f29; --text: #ececf3; --muted: #9a9aab; --accent: #8b85ff; --border: #2f2f3c; } }
        body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 680px; margin: 40px auto; padding: 0 16px; }
        h1 { font-size: 24px; margin: 0 0 4px; } .sub { color: var(--muted); margin: 0 0 24px; }
        ol { list-style: none; padding: 0; margin: 0; counter-reset: step; }
        li { counter-increment: step; background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 14px 16px 14px 56px; margin-bottom: 12px; position: relative; }
        li::before { content: counter(step); position: absolute; left: 16px; top: 14px; width: 26px; height: 26px; border-radius: 50%; background: var(--accent); color: #fff; font-weight: 600; text-align: center; line-height: 26px; }
        code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: 3px 6px; word-break: break-all; }
        .row { display: flex; gap: 8px; align-items: center; margin-top: 8px; flex-wrap: wrap; }
        button { font: inherit; font-size: 13px; border: 0; border-radius: 8px; padding: 6px 12px; background: var(--accent); color: #fff; cursor: pointer; }
        .done { color: var(--muted); font-size: 13px; }
        kbd { font: 12px ui-monospace, Menlo, monospace; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 4px; padding: 1px 5px; }
        </style></head>
        <body><main>
        <h1>Add PalMeet to this profile</h1>
        <p class="sub">\(escape(browser)) · \(escape(profileName)). With the extension PalMeet records only the meeting tab (not videos or calls in other tabs or profiles) and knows when you're muted.</p>
        <ol>
        <li>Open the extensions page: copy its address, click the address bar, paste and press Return.
          <div class="row"><code>\(escape(extensionsPage))</code><button data-copy="\(escape(extensionsPage))">Copy</button><span class="done"></span></div></li>
        <li>Turn on <b>Developer mode</b> (switch at the top right).</li>
        <li>Click <b>Load unpacked</b>. In the file dialog press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, paste this folder path, press Return, then click <b>Select</b>.
          <div class="row"><code>\(escape(folderPath))</code><button data-copy="\(escape(folderPath))">Copy</button><span class="done"></span></div></li>
        <li>Pin the PalMeet icon (puzzle-piece menu → pin). PalMeet shows this profile as ready within a few seconds, and meeting tabs appear in its Record list.</li>
        </ol>
        </main>
        <script>
        for (const button of document.querySelectorAll('button[data-copy]')) {
          button.addEventListener('click', async () => {
            const text = button.dataset.copy;
            try { await navigator.clipboard.writeText(text); }
            catch { const t = document.createElement('textarea'); t.value = text; document.body.append(t); t.select(); document.execCommand('copy'); t.remove(); }
            button.nextElementSibling.textContent = 'Copied';
          });
        }
        </script>
        </body></html>
        """
    }
}
