# PalMeet Bridge protocol (v1)

How the companion Chromium extension and the PalMeet macOS app talk to each other.
The Swift side is `Sources/BrowserBridge`; the extension side is this directory.

## Overview

```
Chrome profile "Work"   ── service worker ──(control WS)──┐
                         └ offscreen doc ───(media WS)────┤
Chrome profile "Client" ── service worker ──(control WS)──┼──> PalMeet BrowserBridgeServer
                         └ offscreen doc ───(media WS)────┘     ws://127.0.0.1:47821
```

- Each browser profile runs its own copy of the extension, so each profile opens its own sockets.
- The **control** connection (service worker) carries all JSON messages.
- The **media** connection (offscreen document, open only while capturing) carries binary
  audio/video frames. Binary frames are also accepted on the control connection.

## Transport

- WebSocket on `127.0.0.1`, default port **47821**. If it is taken, the app tries 47822 … 47830.
- The server binds to the loopback interface only and rejects upgrades whose `Origin` header is
  not `chrome-extension://…` (web pages cannot connect even if they guess the port).
- Text frames: UTF-8 JSON, every message has a `type`. Unknown types are ignored by both sides.
- Session IDs are RFC 4122 UUID strings, lowercase (as `crypto.randomUUID()` emits).

## Pairing (native messaging)

1. When the app's server starts it writes `~/Library/Application Support/PalMeet/bridge.json`
   (mode 0600):
   ```json
   { "port": 47821, "token": "<64 hex chars>", "pid": 1234, "updatedAt": "2026-10-13T12:00:00Z" }
   ```
   `token` is 32 random bytes in hex, created once and kept across launches. On stop, `port`
   and `pid` are cleared.
2. The PalMeet executable is also the native messaging host **`app.palmeet.bridge`**. Its host
   manifest (`app.palmeet.bridge.json`, written by `NativeHostInstaller`) allows only the
   extension's origin `chrome-extension://lhchlhlaljhfimjelkfbcmgocleehfin/`.
3. The extension calls `chrome.runtime.sendNativeMessage("app.palmeet.bridge", {"type":"getBridgeInfo"})`.
   Chrome launches the host with the origin as an argument. The host reads one request
   (4-byte native-endian length + JSON on stdin), writes one reply the same way on stdout, and exits:
   ```json
   { "type": "bridgeInfo", "port": 47821, "token": "…", "protocolVersion": 1 }
   ```
   or `{ "type": "error", "error": "notRunning" | "notConfigured" | "badRequest", "message": "…" }`.
4. The extension caches `{port, token}` in `chrome.storage.local` and uses the cache if the
   native host is unavailable. A 4401 close clears the cache.

## Connection lifecycle

1. Extension opens `ws://127.0.0.1:<port>/` and must send `hello` first (within 10 s, else 4408).
2. App replies `welcome`, or closes with **4401** (bad token) / **4400** (first message is not
   a valid `hello`).
3. A second **control** connection with the same `profileInstanceId` replaces the old one,
   which is closed with **4409**.
4. Extension sends `ping` every 20 s; app answers `pong`. The extension reconnects with
   exponential backoff (1 s → 30 s) and a 30 s `chrome.alarms` wake-up.

| Close code | Meaning |
|---|---|
| 1000 / 1001 | normal / app shutting down |
| 4400 | protocol violation before `hello` |
| 4401 | bad token |
| 4408 | no `hello` in time |
| 4409 | superseded by a newer control connection for the same profile |

## Messages: extension → app

### `hello`
```jsonc
{
  "type": "hello",
  "token": "<from bridgeInfo>",
  "profileInstanceId": "4b0c…",        // random UUID, persisted per profile in chrome.storage.local
  "profileLabel": "Work",               // options page; default: profile email if granted, else "Profile <id[0..6]>"
  "browser": "Chrome",                  // Chrome | Edge | Brave | Opera | Vivaldi | Arc | Chromium
  "extensionVersion": "0.1.0",
  "role": "control"                     // "control" (default) | "media"
}
```

### `windows`
Sent after `welcome` and on any tab/window change (debounced 300 ms).
```json
{
  "type": "windows",
  "windows": [{
    "windowId": 12, "focused": true, "state": "normal",
    "bounds": { "left": 10, "top": 20, "width": 1280, "height": 800 },
    "activeTabId": 99,
    "tabs": [{ "tabId": 99, "title": "Meet – abc-defg-hij", "url": "https://meet.google.com/abc-defg-hij",
               "active": true, "audible": true, "isMeeting": true }]
  }]
}
```
`isMeeting` uses `MEETING_URL_PATTERNS` in `meeting-patterns.js`: `meet.google.com/xxx-xxxx-xxx`,
`teams.microsoft.com`, `teams.live.com`, `teams.cloud.microsoft`, `*.zoom.us/wc/`, `app.zoom.us/wc`,
`*.webex.com`, `whereby.com`, `app.slack.com/huddle`.

### `captureState`
```jsonc
{ "type": "captureState", "sessionId": "…", "state": "awaitingGesture" | "capturing" | "stopped" | "error",
  "message": "Tab closed",                // optional
  "userInitiated": true,                  // optional; capture started from the browser
  "windowId": 12, "tabId": 99 }           // present with "capturing"
```
- `awaitingGesture`: the request was accepted; the icon in that window shows a pulsing **REC?**.
- `capturing`: streaming. If the app does not know `sessionId` (the user clicked the icon with no
  pending request, or the app restarted mid-capture) and `windowId`/`tabId` are present, the app
  adopts it (`BrowserBridgeEvent.userInitiatedCapture`).
- `stopped`: the tab was closed (`"Tab closed"`), navigated away from the meeting URL
  (`"Navigated away from the meeting"`), its window closed, the user clicked the icon again
  (`"Stopped from the browser"`), or Chrome ended the capture.
- `error`: e.g. `"Tab capture failed: …"`, `"Tab not found."`.

After a reconnect the extension re-sends `capturing` for every live capture and
`awaitingGesture` for every pending request.

### `meetingState`
From the content script on meeting pages (polled every 1 s, sent on change). `null` = unknown.
```json
{ "type": "meetingState", "sessionId": "…", "muted": true, "presenting": null }
```

### `speakerActivity`
From the content script while its tab is captured: live captions (labelled with the speaker's name by the
meeting service) and "is speaking" indicators. Sent when something changes (polled every 400 ms).
```jsonc
{ "type": "speakerActivity", "sessionId": "…", "at": 1760436000123,   // Unix epoch ms of the page read
  "captions": [{ "id": "k3x9-4", "name": "Maria Silva", "text": "Good morning everyone" }],
  "speaking": ["Maria Silva"] }                                        // null: no indicator understood
```
- A caption keeps its `id` while on screen and is re-sent with its full text whenever the text changes
  (captions grow word by word and get refined). `name` may be `null` (ignored by the app).
- The app keeps them per session in `meeting-speakers.json` and, after the meeting, aligns caption text with
  the transcribed words to name speakers (`SpeakerAttribution`).
- Readers: Teams (`[data-tid="closed-caption-text"]` + `[data-tid="author"]`), Google Meet (the captions
  region, any UI language), Zoom web; speaking indicators from "… speaking" labels. See `speaker-detection.js`.

### `pageDiagnostics`
Only when the app enabled it (`welcome.options.pageDiagnostics`) and only for captured tabs: once a minute,
which page attributes changed most (with sample values and the nearest label), `data-tid` counts and live
regions. The app appends it to `page-diagnostics.jsonl` in the session folder; it is used to add readers for
new meeting-site layouts.
```jsonc
{ "type": "pageDiagnostics", "sessionId": "…", "at": 1760436000123,
  "payload": { "mutations": 5210, "top": [{ "sig": "div[data-tid=\"voice-level-stream-outline\"]@class",
               "count": 42, "values": ["…"], "labels": ["Maria Silva, …"] }], "dataTids": {}, "regions": [] } }
```

### `ping`
`{ "type": "ping" }`

## Messages: app → extension

| Message | Fields |
|---|---|
| `welcome` | `protocolVersion`, `profileInstanceId`, `options: { pageDiagnostics }` |
| `startCapture` | `sessionId`, `windowId`, `tabId` |
| `stopCapture` | `sessionId` |
| `reloadExtension` | – (sent once per app run to an extension older than the copy in its folder; it reloads when nothing is being recorded) |
| `pong` | – |

### Capture flow and the user gesture

Chrome only lets an extension capture a tab after the user invokes it on that tab.

1. App → `startCapture {sessionId, windowId, tabId}`.
2. Extension stores it as the window's pending request, badges every tab of that window with a
   pulsing **REC?**, replies `captureState awaitingGesture`.
3. The user clicks the toolbar icon (or presses the `start-capture` command, default ⌥⇧R) in that window.
   - If the clicked tab is not the requested tab, the extension activates the requested tab and
     waits for a second click.
4. `chrome.tabCapture.getMediaStreamId({targetTabId})` → offscreen document (reasons
   `USER_MEDIA`, `AUDIO_PLAYBACK`) → `getUserMedia({audio, video})` with
   `chromeMediaSource: "tab"`. The audio is played back through an `AudioContext` so the
   meeting stays audible.
5. Extension → `captureState capturing {windowId, tabId}`; frames flow on the media socket.

Clicking the icon with **no** pending request starts a capture of the active tab with a new
`sessionId` and reports `capturing` with `"userInitiated": true`. Clicking a tab that is being
recorded stops it.

## Binary frames (extension → app)

Little-endian, 32-byte header followed by the payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `kind`: 1 = audio PCM, 2 = video JPEG |
| 1 | 1 | reserved, 0 |
| 2 | 2 | `channels` (u16; 0 for video) |
| 4 | 4 | `sampleRate` (u32 Hz; 0 for video) |
| 8 | 16 | `sessionId` UUID, raw bytes in RFC 4122 order |
| 24 | 8 | `captureTime` (f64, Unix epoch **milliseconds**, time of the first sample/frame) |
| 32 | … | payload |

- **Audio**: Int16 interleaved PCM at the `AudioContext` rate (usually 48 kHz), 2 channels,
  ~100 ms per frame (AudioWorklet → Int16).
- **Video**: one JPEG per second, max width 1280, quality 0.7 (`ImageCapture.grabFrame` →
  `OffscreenCanvas.convertToBlob`).
- The app accepts a frame only if `sessionId` belongs to a capture of the same profile.

Reference: header for kind 1, 2 ch, 48000 Hz, session `6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b`,
time 1700000000123.5 →
`0100020080bb00006f1c2a3b4d5e4f608a7b9c0d1e2f3a4b00b88756febc7842`.
