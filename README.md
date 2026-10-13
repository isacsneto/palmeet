# PalMeet

Native macOS app (Swift 6 / SwiftUI, macOS 15+) that records meetings from any app window or browser tab:

- Captures **their** audio (per app, or per tab via the extension) and **your** mic on separate tracks.
- Takes **screenshots** periodically and when the screen changes.
- Builds a **speaker-attributed transcript**, on device.
- Writes a **Markdown summary** with Claude, OpenAI/Codex, Gemini, Cursor or a local model, using an API key or your existing CLI login.
- Can record **several meetings at once**, each fully isolated.
- Has a **live copilot** that suggests what to say and ask. It is off unless you turn it on.
- **Hotkeys** for everything; windows are **hidden from screen sharing** and have **adjustable transparency**.

See [PLAN.md](PLAN.md) for the design.

## Build and run

```bash
scripts/build-app.sh debug        # or: release
open build/PalMeet.app
```

Requirements: Apple Silicon, macOS 15+, Xcode 26 / Swift 6.2.

**Recommended: a stable signing identity.** Ad-hoc signed builds make macOS forget Screen Recording, Microphone and System Audio permissions after every rebuild. Create a local certificate once:

```bash
scripts/create-dev-cert.sh
PALMEET_SIGN_IDENTITY="PalMeet Development" scripts/build-app.sh debug
```

## First run

1. **Permissions.** The onboarding screen asks for Screen & System Audio Recording, Microphone, and System Audio Recording. System Audio is prompted the first time you record an app. Accessibility is optional; it reads mute and sharing state from the Zoom and Teams desktop apps.
2. **AI provider.** Pick one in Settings → AI Providers.
   - **CLIs** reuse your login: `claude`, `codex`, `gemini`, `cursor-agent`.
   - **APIs** need a key, which is stored in the Keychain.
   - The live copilot is fastest with an API provider and a fast model, e.g. `claude-haiku-5-5`.
3. **Speech models.** The first transcription downloads the speech models (about 600 MB ASR + diarization) to `~/Library/Application Support/FluidAudio`.

## Recording two meetings in the same browser (Chrome profiles)

Chrome plays the audio of every tab, in every profile, through one process. Per-tab isolation therefore needs the companion extension:

1. Settings → Browser Extension → **Install connector**. This writes the native-messaging host manifest.
2. `chrome://extensions` → Developer mode → **Load unpacked** → `Extension/chromium`. You can also open the folder from Settings. Repeat this in **each profile** you use for meetings.
3. In PalMeet's picker, browser meeting tabs appear one per window, e.g. "Chrome · Work · Google Meet – …".
4. After you start a tab, click the PalMeet icon in that Chrome window once. Chrome requires a user gesture for tab capture.

Details: [Extension/chromium/README.md](Extension/chromium/README.md) and [PROTOCOL.md](Extension/chromium/PROTOCOL.md).

## Default hotkeys

All of them can be changed in Settings → Hotkeys. Press `⌃⌥/` for the cheat sheet.

| | |
|---|---|
| `⌃⌥R` record frontmost meeting / stop | `⌃⌥N` add another meeting |
| `⌃⌥P` pause/resume | `⌃⌥E` stop & summarize |
| `⌃⌥S` mark moment + screenshot | `⌃⌥K` quick note |
| `⌃⌥M` cycle mic routing | `⌃⌥C` copilot on/off |
| `⌃⌥H` help me now | `⌃⌥1/2/3` copy suggestion |
| `⌃⌥Space` copilot panel | `⌃⌥W` main window |
| `⌃⌥\` panic hide | `⌃⌥↑/↓/0` opacity |
| `⌃⌥T` click-through | |

## Output

Each meeting is saved to `~/Documents/PalMeet/<date time> – <title>/`:

| File | Contents |
|---|---|
| `summary.md` / `summary.json` | The summary: TL;DR, decisions, action items, key takeaways, topics, open questions, risks, your commitments, quotes, screenshots |
| `transcript.md` / `transcript.json` | Speaker-attributed transcript with timestamps |
| `audio/them.caf`, `audio/me.caf` | The two audio tracks (16 kHz) |
| `screenshots/*.jpg`, `screenshots/index.json` | Screenshots with their OCR text |
| `copilot.json`, `notes.json`, `session.json` | Copilot suggestions, your notes, session metadata |

## Project layout

| Module | Responsibility |
|---|---|
| `SessionKit` | Models, on-disk layout, Markdown renderers |
| `CaptureKit` | Window list, Core Audio process taps, shared mic (echo cancellation), window frame sampling, permissions, Accessibility meeting state |
| `BrowserBridge` | Localhost WebSocket bridge + native-messaging pairing with the Chromium extension |
| `TranscriptKit` | Parakeet ASR (FluidAudio), diarization, voice-activity segmentation, ASR scheduler, transcript assembly, speaker naming |
| `VisionContext` | OCR, perceptual hash, screenshot keep policy |
| `LLMKit` | Anthropic, OpenAI-compatible and Gemini APIs; Claude Code, Codex, Gemini and Cursor CLIs; Keychain |
| `CopilotKit` | Question detection, prompts, streaming line protocol, copilot engine (strict on/off) |
| `PalMeetCore` | `SessionManager` (concurrent sessions, conflicts, mic routing, bridge events), `MeetingSession`, summarizer |
| `PalMeet` | App: menu bar, main window, picker, review, copilot panel, settings, hotkeys, window privacy and appearance |

## Tests

```bash
swift test                                   # unit + local integration tests (no network)
PALMEET_INTEGRATION=1 swift test --filter RealAudioIntegrationTests   # real ASR + diarization on synthetic voices
PALMEET_INTEGRATION=1 swift test --filter LiveSummaryTests            # real summary via the Claude Code CLI
PALMEET_INTEGRATION=1 swift test --filter RealPipelineTests           # whole sessions with real models (EN + PT)
PALMEET_CHROME="…/Google Chrome for Testing" swift test --filter ChromeExtensionE2ETests  # real Chrome + extension
node --test Extension/chromium/tests/*.test.mjs                       # extension logic
open build/PalMeet.app --args --self-test /tmp/palmeet-self-test.json  # taps, mic, screen capture, invisibility
```

Note: if Chrome's own audio is muted (e.g. launched with `--mute-audio`), tab capture records silence; muting a meeting tab works the same way. Keep the meeting tab unmuted while recording.

## Known limitations / next steps

- **Echo cancellation can be unavailable.** On some Macs, macOS voice processing fails to start (`-10875`). The self-test reports this as "echo cancellation unavailable". PalMeet then records the plain microphone, and a transcript-level filter drops lines that duplicate the remote audio. With speakers instead of headphones, some echo may remain.

- **Distribution.** Local builds resolve SwiftPM resource bundles from `.build`. A notarized, distributable build needs an Xcode project (or XcodeGen) so resource bundles land in `Contents/Resources`.
- **Needs a real-meeting check on your Mac.** None of these can be verified without a live meeting:
  - process taps on Zoom, Teams and Chrome;
  - echo cancellation with speakers;
  - the Chrome extension in a real browser;
  - the mute/presenting selectors;
  - invisibility in each meeting app's screen share (run Settings → Privacy → *Run invisibility check*).
- **Not built yet:**
  - from PLAN.md Phase 3–4: automatic meeting detection, calendar attendees, synced audio playback in review, an LLM transcript-cleanup pass, cloud ASR, voice memory for recurring participants, and the copilot's "Deep answer";
  - PLAN.md also describes a separate floating recording HUD; the menu bar fills that role.
