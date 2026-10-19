# PalMeet Bridge (Chromium extension)

Captures one meeting tab per browser window and streams its audio (and 1 fps screenshots) to
the PalMeet macOS app. Each Chrome profile runs its own copy, so two meetings in two profiles
stay isolated. Protocol details: [PROTOCOL.md](PROTOCOL.md).

Plain JavaScript, Manifest V3, no build step, no dependencies. Works in Chrome 116+, Edge,
Brave, Arc, Vivaldi and Chromium.

## Files

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest. Its `key` pins the extension ID to `lhchlhlaljhfimjelkfbcmgocleehfin`. |
| `background.js` | Service worker: control socket, windows/tabs reports, capture flow, badges. |
| `offscreen.html` / `offscreen.js` | `getUserMedia` on the tab stream, playback, media socket. |
| `pcm-worklet.js` | AudioWorklet that turns Float32 blocks into ~100 ms Int16 chunks. |
| `content-meeting-state.js` | Reads mute / presenting state on meeting pages; while recording, reports captions and speaking indicators. |
| `speaker-detection.js` | Caption and "is speaking" readers for Teams, Meet and Zoom (on Meet, which tile's voice bars are moving), plus page diagnostics. Loaded before the content script. |
| `meeting-patterns.js` | The meeting URL list. Edit this to add services. |
| `options.html` / `options.js` | Profile name, connection status. |

## Install (load unpacked)

Do this once **in every profile** you join meetings from:

1. Open `chrome://extensions` (Edge: `edge://extensions`, Brave: `brave://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and select this `Extension/chromium` folder.
4. Check that the ID shown is `lhchlhlaljhfimjelkfbcmgocleehfin`. The fixed `key` in the
   manifest makes the ID the same in every profile and browser.
5. Optional: pin the PalMeet icon to the toolbar, open the extension's **Options** and give
   the profile a name (e.g. "Work"). PalMeet shows this name in its picker.

## Install the native messaging host (pairing)

The extension gets the port and pairing token from PalMeet through native messaging. The PalMeet
executable is the host. It writes `app.palmeet.bridge.json` into the `NativeMessagingHosts`
folder of every installed Chromium browser:

```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.palmeet.bridge.json
~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/…
~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/…
~/Library/Application Support/Arc/User Data/NativeMessagingHosts/…   (and Chrome Beta/Canary, Chromium, Vivaldi)
```

In the app this is **Settings → Browser extension → Install browser support**. The button calls:

```swift
import BrowserBridge

try NativeHostInstaller.install(
    hostExecutablePath: Bundle.main.executablePath!,          // …/PalMeet.app/Contents/MacOS/PalMeet
    extensionIDs: [BrowserExtension.defaultExtensionID]
)
```

The app's `main` must call `NativeMessagingHost.runIfInvoked(arguments: CommandLine.arguments)`
first, and exit if it returns `true` (Chrome launched it as the host).

For a manual install during development, write the manifest yourself:

```sh
HOST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$HOST"
cat > "$HOST/app.palmeet.bridge.json" <<EOF
{
  "name": "app.palmeet.bridge",
  "description": "PalMeet browser bridge pairing",
  "path": "/Applications/PalMeet.app/Contents/MacOS/PalMeet",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://lhchlhlaljhfimjelkfbcmgocleehfin/"]
}
EOF
```

After installing the host, restart the browser (or click **Reconnect now** in the options page).

## Use

1. Start PalMeet. The icon badge shows **OFF** while PalMeet isn't reachable and is blank once connected.
2. In PalMeet, pick the browser window that has the meeting. The PalMeet icon in that Chrome
   window starts pulsing **REC?**.
3. Click the icon (or press **⌥⇧R**, which you can change at `chrome://extensions/shortcuts`).
   The badge turns to **REC**. You still hear the meeting.
4. Click the icon again on that tab to stop. Closing the tab or leaving the meeting URL also stops.

Clicking the icon on a meeting tab when PalMeet hasn't asked starts a recording anyway, and PalMeet
picks it up as a new session.

## Troubleshooting

- **Badge stays OFF:** PalMeet isn't running, or the native host isn't installed for this
  browser. The options page shows the exact error.
- **"Tab capture failed":** Chrome only allows capture after a click on that tab. Click the icon
  while the meeting tab is the active tab.
- **Service worker logs:** `chrome://extensions` → PalMeet Bridge → *service worker*. Offscreen
  document logs: `chrome://inspect/#other`.
