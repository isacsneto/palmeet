# PalMeet

Native macOS app (Swift 6 / SwiftUI, macOS 15+) that records meetings from any app window or browser tab:

- Captures **their** audio (per app, or per tab via the extension) and **your** mic on separate tracks.
- Takes **screenshots** periodically and when the screen changes.
- Builds a **speaker-attributed transcript**, on device. Speakers are named from the meeting's own live captions (browser meetings with the extension) and from **voices it learned** in earlier meetings.
- Writes a **Markdown summary** with Claude, OpenAI/Codex, Gemini, Cursor or a local model, using an API key or your existing CLI login.
- Can record **several meetings at once**, each fully isolated.
- Has a **live copilot** that suggests what to say and ask. It is off unless you turn it on.
- Takes **meeting context** while you record (agenda, ticket, who's who, terms). The copilot, the summary and the spelling fixes use it.
- **Hotkeys** for everything; windows are **hidden from screen sharing** and have **adjustable transparency**.

See [PLAN.md](PLAN.md) for the design.

## Install

```bash
scripts/install.sh --rebuild     # builds a signed Release, installs /Applications/PalMeet.app, registers the browser connector, launches it
```

Or make a drag-to-install disk image with `scripts/make-dmg.sh`, which writes `build/PalMeet-<version>.dmg`.

Requirements: Apple Silicon, macOS 15+. Building also needs Xcode 26 and XcodeGen (`brew install xcodegen`).

**Signing.** Run `scripts/create-dev-cert.sh` once. It creates a local "PalMeet Development" code-signing certificate, which the build scripts use automatically. A stable signature keeps macOS privacy permissions across updates and lets Sparkle accept updates.

The app is not notarized, because that needs a paid Apple Developer ID. It runs fine on this Mac. To give it to someone else, they'd right-click → Open the first time. With a Developer ID, set `PALMEET_SIGN_IDENTITY="Developer ID Application: …"` and notarize.

## Updates

PalMeet updates itself with [Sparkle](https://sparkle-project.org). You can check from the menu bar (↓), from PalMeet → Check for Updates…, or in Settings → Updates. The Updates tab also has the automatic check and install toggles.

- **Where updates live.** Each update is a signed `.zip` on the `releases` branch of the private repo `isacsneto/palmeet`, listed in `appcast.xml`. The app's feed is `SUFeedURL` in `Resources/Info.plist`.
- **Private repo access.** The app authenticates with your GitHub CLI login (`gh auth token`, read at check time and never stored), or with a read-only token saved in Settings → Updates (Keychain). If the repo becomes public, no token is needed.
- **Security.** Every archive is EdDSA-signed. The private key is in your login Keychain under the account `palmeet`; the public key is `SUPublicEDKey`. Sparkle refuses anything not signed with that key, and the new app must also carry the same code signature.
  - **Back up the private key:** `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account palmeet -x palmeet-sparkle-key.txt`. Store the file somewhere safe and offline. Without it you can't ship updates to installed copies.

**Publishing a new version**

```bash
git commit …                                    # commit your changes first
scripts/release.sh 0.2.0 notes.md               # build, sign, update appcast.xml, push the releases branch, tag v0.2.0
```

`notes.md` holds one bullet per line and is shown in the update dialog. Installed apps pick the release up on their next daily check, or straight away with Check for Updates…. To withdraw a bad build, delete its zip from `build/releases` before the next release; the feed is regenerated from the archives that remain.

## Development build

```bash
scripts/build-app.sh Release      # or Debug → build/PalMeet.app (Xcode project App/PalMeet.xcodeproj, generated from App/project.yml)
swift scripts/make-icon.swift     # regenerate the app icon (Resources/Assets.xcassets, Resources/AppIcon.icns)
```

## First run

1. **Permissions.** The onboarding screen asks for Screen & System Audio Recording, Microphone, and System Audio Recording. System Audio is prompted the first time you record an app. Accessibility is optional; it reads mute and sharing state from the Zoom and Teams desktop apps. It also tells PalMeet when you're unmuted in a Teams or Zoom call that isn't being recorded, so your voice there stays out of the meeting you are recording.
2. **AI provider.** Pick one in Settings → AI Providers.
   - **CLIs** reuse your login: `claude`, `codex`, `gemini`, `cursor-agent`.
   - **APIs** need a key, which is stored in the Keychain.
   - The live copilot is fastest with an API provider and a fast model, e.g. `claude-haiku-5-5`.
   - If the provider you picked doesn't work (no key saved, CLI not installed or logged out), PalMeet uses one that does and says so in Settings. You only see a "set up" message when no provider works.
3. **Speech models.** The first transcription downloads the speech models (about 600 MB ASR + diarization) to `~/Library/Application Support/FluidAudio`.

## Recording two meetings in the same browser (Chrome profiles)

Chrome plays the audio of every tab, in every profile, through one process. Per-tab isolation therefore needs the companion extension:

1. Settings → Browser Extension → **Install connector**. This writes the native-messaging host manifest.
2. `chrome://extensions` → Developer mode → **Load unpacked** → `Extension/chromium`. You can also open the folder from Settings. Repeat this in **each profile** you use for meetings.
3. In PalMeet's picker, browser meeting tabs appear one per window, e.g. "Chrome · Work · Google Meet – …".
4. After you start a tab, Chrome brings it forward. Click the PalMeet icon (it blinks **REC?**) or press ⌥⇧R in that window once; Chrome requires a user gesture for tab capture. Until then the live view shows an orange "isn't being recorded yet" banner. Pin the extension so the icon is always visible.
5. A meeting is recorded once: pressing ⌃⌥R again while it starts, or picking both the tab and its browser window, doesn't start a second recording.

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
| `context.md` | The meeting context you typed (agenda, ticket, who's who); used by the copilot, the summary and spelling fixes |
| `meeting-speakers.json` | Captions and "is speaking" indicators the meeting page showed (browser meetings) |
| `speaker-voices.json` | Voiceprint of each remote speaker (used to learn voices when you name speakers) |
| `page-diagnostics.jsonl` | Which meeting-page elements changed while recording (helps add speaker detection for new layouts) |

Learned voices live in `~/Library/Application Support/PalMeet/Voices.json` (Settings → General → Who said what).

## Who said what

Remote speech is attributed in this order (`SpeakerAttribution`):

1. **Meeting captions.** With the extension and the meeting's live captions on, Teams, Meet and Zoom label each caption with the speaker's name. Caption text is aligned to the transcribed words, and those words take that name. This splits people the diarizer lumped together and merges one person it split.
2. **Voice clusters** from the diarizer, named by a majority of their caption-labelled words, by "is speaking" indicators, or by a voice learned earlier (cosine similarity ≥ 0.65 with a clear winner; on real recordings the same voice scores 0.92–0.96 and different people at most 0.44).
3. Otherwise "Speaker N", which the summarizer may name from what people say. It never overrides names from you, the meeting or a known voice.

Naming a speaker in Review, or the meeting naming them, teaches PalMeet their voice (when they spoke for at least 8 s).

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
node --test Extension/chromium/tests/*.test.mjs                       # extension logic (+ real DOM with PALMEET_CHROME)
PALMEET_SESSION_DIRS="<copied session>:<other>" swift test --filter RealSessionTests  # voice learning on real recordings
PALMEET_VOICE_FILE=<them.caf> swift test --filter VoiceCalibrationTests             # same-voice vs other-voice similarity
open build/PalMeet.app --args --self-test /tmp/palmeet-self-test.json  # taps, mic, screen capture, invisibility
scripts/smoke-test.sh                                                  # app launches and stays idle (run before releasing)
```

Note: if Chrome's own audio is muted (e.g. launched with `--mute-audio`), tab capture records silence; muting a meeting tab works the same way. Keep the meeting tab unmuted while recording.

## Known limitations / next steps

- **Echo cancellation can be unavailable.** On some Macs, macOS voice processing fails to start (`-10875`). The self-test reports this as "echo cancellation unavailable". PalMeet then records the plain microphone, and a transcript-level filter drops lines that duplicate the remote audio. With speakers instead of headphones, some echo may remain.

- **Notarization.** Builds are signed with a local certificate, not a Developer ID, so Gatekeeper asks once on other Macs.
- **Needs a real-meeting check on your Mac.** None of these can be verified without a live meeting:
  - process taps on Zoom, Teams and Chrome;
  - echo cancellation with speakers;
  - the Chrome extension in a real browser;
  - the mute/presenting selectors, and the caption / speaking-indicator readers on live Teams, Meet and Zoom pages (`page-diagnostics.jsonl` from a real meeting shows what to adjust);
  - invisibility in each meeting app's screen share (run Settings → Privacy → *Run invisibility check*).
- **Not built yet:**
  - from PLAN.md Phase 3–4: automatic meeting detection, calendar attendees, synced audio playback in review, cloud ASR and the copilot's "Deep answer";
  - PLAN.md also describes a separate floating recording HUD; the menu bar fills that role.
