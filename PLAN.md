# PalMeet — Native macOS Meeting Recorder, Transcriber & Summarizer

> Working name taken from the folder (`pal-meet-o`). Rename freely.

## 1. Goal

A native macOS app that:

1. Lets you **pick a source**: a specific app window (Zoom, Microsoft Teams, Slack huddle, Google Meet in a browser, etc.) or a whole app.
2. **Captures that source's audio** (the other participants) **and your microphone** (you) on separate tracks.
3. **Takes screenshots** of the source periodically and when the screen changes (slides, shared screens, participant names).
4. Produces a **speaker-attributed transcript** (who said what, with timestamps).
5. Uses an AI provider of your choice (**Claude, OpenAI/Codex, Gemini, Cursor**) via **API key** or via a **locally logged-in CLI** to generate a **Markdown summary**: overview, decisions, action items, key takeaways, open questions.
6. Records **multiple meetings at the same time** (e.g. a Teams call and a Meet tab). Each meeting's audio, transcript, screenshots and summary stay **fully isolated** in its own session (see §4.9).
7. Has a **Live Copilot toggle** per meeting. When ON, it suggests what to answer when someone asks you something and proposes good questions to ask, based on the meeting's context (e.g. a grooming session). When OFF, it is completely inactive (see §4.10).
8. Is fully **keyboard-driven** (customizable global hotkeys for every feature), can be **hidden from screen sharing/recording**, and has **adjustable window transparency** (see §4.11–4.12).

---

## 2. Technology choice

**Swift 6 + SwiftUI, macOS 15+ (Sequoia).** Objective-C adds nothing here, and cross-platform stacks (Electron, Tauri, Flutter) would need native bridges for the hardest parts anyway: per-app audio capture, window capture and on-device ML.

| Concern | Native API / library | Why |
|---|---|---|
| Window and app enumeration, video frames, screenshots | **ScreenCaptureKit** (`SCShareableContent`, `SCContentFilter`, `SCStream`, `SCScreenshotManager`) | Captures one window even when it is covered by other windows. Apple-supported. |
| Remote participants' audio (per app) | **Core Audio process taps** (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.2+) | Taps the audio of specific processes, including Chrome/Teams helper processes, without a virtual audio driver like BlackHole. |
| Fallback system/app audio | ScreenCaptureKit audio (`capturesAudio = true`) | Simpler, but filters by app and can miss browser helper processes. |
| Your microphone | **AVAudioEngine** with voice processing (`setVoiceProcessingEnabled(true)`) | Built-in echo cancellation keeps the remote audio from leaking into your mic track. |
| Audio files | AVAudioFile / AVAssetWriter (AAC `.m4a` + 16 kHz mono WAV for ASR) | |
| On-device speech-to-text | **WhisperKit** (Argmax, CoreML) or **FluidAudio** (Parakeet TDT on the Neural Engine). Apple **SpeechAnalyzer/SpeechTranscriber** is an extra engine when running on macOS 26+ | Private, free, works offline. |
| Speaker diarization | **FluidAudio** diarizer (pyannote-style segmentation + speaker embeddings, CoreML) | Native Swift, runs on device. |
| OCR on screenshots | **Vision** (`VNRecognizeTextRequest`) | Reads slide text and participant name labels on device. |
| Secrets | Keychain (`SecItem*`) | API keys are never written to disk in plain text. |
| Persistence | SwiftData (or GRDB) for the session index, plain files for artifacts | |
| Packaging | Developer ID signed + notarized DMG, Sparkle for updates | **Not the Mac App Store.** The sandbox blocks spawning `claude`/`codex`/`gemini`/`cursor-agent` CLIs and makes process taps awkward. |

Dev environment detected: macOS 15.7, Xcode 26.3, Swift 6.2. So the deployment target is **macOS 15.0**, and the macOS 26 SpeechAnalyzer engine is gated with `#available`.

---

## 3. High-level architecture

```
┌───────────────────────────── SwiftUI App ─────────────────────────────┐
│  MenuBarExtra (record / stop / status)   Main window (sessions, live │
│  Source Picker   Live transcript   Settings (providers, keys, ASR)   │
└──────────────┬────────────────────────────────────────────┬──────────┘
               │                                            │
     ┌─────────▼──────────────────────────┐   ┌─────────▼─────────┐
     │ SessionManager (actor)             │   │   SessionStore    │
     │  • N concurrent sessions           │   │ (SwiftData + FS)  │
     │  • source-conflict detection       │   └───────────────────┘
     │  • MicRouter (one mic → sessions)  │
     │  • shared ASR scheduler            │
     └──┬───────────────┬─────────────────┘
        │               │
 ┌──────▼──────────┐  ┌─▼─────────────┐   ┌───────────────────────┐
 │ MeetingSession  │  │MeetingSession │ … │ SharedMicCapture      │
 │  #1 (Teams)     │  │ #2 (Meet tab) │   │ (AVAudioEngine + AEC, │
 │ RemoteAudio ────┤  │ RemoteAudio   │   │  one stream, routed   │
 │ ScreenSampler   │  │ ScreenSampler │   │  per session by       │
 │ Transcript buf. │  │ Transcript    │   │  MicRouter timeline)  │
 └──────┬──────────┘  └─┬─────────────┘   └──────────┬────────────┘
        │ "Them"        │ "Them"       "Me" segments  │
        ▼               ▼  ◄────────────────────────────┘
   (each session runs its own copy of the pipeline below)
┌──────────────────────────────────────┐
│ TranscriptionPipeline                │
│  • live: streaming ASR per track     │
│  • final: high-accuracy re-pass      │
│  • diarization on the "Them" track   │
│  • speaker naming (OCR/vision/LLM)   │
└──────────────────┬───────────────────┘
                   ▼
┌──────────────────────────────────────┐
│ Summarizer → LLMProvider (protocol)  │
│  API: Anthropic / OpenAI / Gemini    │
│  CLI: claude / codex / gemini /      │
│       cursor-agent   (local login)   │
│  Local: Ollama / MLX (optional)      │
└──────────────────┬───────────────────┘
                   ▼
        transcript.md · summary.md · session.json
```

### Swift package / module layout

```
PalMeet/                       (Xcode project, app target)
  App/                         PalMeetApp.swift, MenuBar, Windows, Settings
  Features/
    SourcePicker/              window/app grid with live thumbnails
    LiveSession/               recording HUD + live transcript view
    SessionLibrary/            history, search, reopen and re-summarize
Packages/
  CaptureKit/                  RemoteAudioCapture, MicCapture, ScreenSampler, Permissions
  TranscriptKit/               ASREngine protocol, WhisperKit/FluidAudio/Apple engines, Diarizer, Aligner
  VisionContext/               OCR, frame dedupe (perceptual hash), speaker-label detection
  LLMKit/                      LLMProvider protocol + API and CLI providers, prompt templates
  CopilotKit/                  CopilotEngine (per session), TriggerDetector, ContextBuilder, playbooks
  SessionKit/                  models, storage, Markdown/JSON exporters
```

---

## 4. Core components in detail

### 4.1 Source picker

- `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)` lists windows and apps.
- Group by known meeting apps first (bundle IDs: `us.zoom.xos`, `com.microsoft.teams2`, `com.tinyspeck.slackmacgap`, `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser`, `org.mozilla.firefox`, `com.cisco.webexmeetings`, …).
- Show live thumbnails with `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
- **Browser tabs:** macOS gives you the *window*, not the *tab*. Capturing the window records whichever tab is visible in it, so the user should pop the meeting tab out into its own window. To label it nicely, read the active tab title via AppleScript (Chrome, Safari, Arc support it), which needs the Automation permission. With the companion extension installed (§4.9.3), individual tabs show up as sources directly.
- Optional **"auto-detect meeting"**: watch for a known meeting app that has the mic active (Core Audio `kAudioProcessPropertyIsRunningInput`) and offer a "Start recording?" notification.

### 4.2 Remote audio ("Them" track)

**Primary path: Core Audio process tap (macOS 14.2+)**

1. Resolve the selected app's PID **plus its helper processes**. Chrome, Edge, Teams and Slack play audio from `… Helper` processes, so match by bundle-ID prefix / parent PID. Translate the PIDs to audio process objects with `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. Create a `CATapDescription(stereoMixdownOfProcesses:)` and call `AudioHardwareCreateProcessTap`.
3. Build a private aggregate device that contains the tap, and attach an `AudioDeviceIOProc` to receive PCM buffers.
4. Fan the buffers out to (a) the file writer, (b) a resampler to 16 kHz mono, and (c) the live ASR.
5. Requires the `NSAudioCaptureUsageDescription` Info.plist key (system "audio recording" permission).

Reference: Apple sample *"Capturing system audio with Core Audio taps"* and the open-source **AudioCap** project.

**Fallback path:** ScreenCaptureKit stream with `capturesAudio = true` and an app-based `SCContentFilter`. Use it if the tap fails.

**Per-tab browser audio:** a companion Chromium extension streams a single tab's audio to the app. It is required when two meetings run in the same browser. Details in §4.9.3.

### 4.3 Microphone ("Me" track)

- `AVAudioEngine.inputNode` with `setVoiceProcessingEnabled(true)` for AEC (acoustic echo cancellation) and noise suppression.
- Device picker (follow the system default, or pin a specific device). Handle `AVAudioEngineConfigurationChange` for AirPods connect/disconnect.
- Because "Me" is a separate track, **your lines are attributed perfectly without diarization.**
- There is **one physical mic** but possibly several meetings. The mic is captured once by `SharedMicCapture` and assigned to sessions by the `MicRouter` (§4.9.4).
- Add a "mute detection" heuristic: if the meeting app shows you muted (OCR) or the mic RMS stays at the noise floor, skip ASR on silence to save compute.

### 4.4 Screen context ("eyes")

- `SCStream` on the selected window at **1 fps** (cheap), with `SCStreamConfiguration` scaled to roughly 1280 px wide.
- **Keep a frame when:**
  - the perceptual hash (dHash) distance from the last kept frame is above a threshold (slide changed or screen share started), **or**
  - N seconds passed since the last kept frame (default 30 s, configurable 10–120 s), **or**
  - the user presses the global hotkey "📸 mark this moment".
- For each kept frame:
  - save it as `screenshots/0012_00-14-32.jpg` (time offset from session start),
  - run Vision OCR and store the text and boxes,
  - detect the **active speaker highlight / name label** (Zoom/Teams draw a colored border plus a name tag). Store `(timestamp, candidateNames[])`.
- **Optional** short screen video recording (`AVAssetWriter` H.264 at low bitrate) for later review. Off by default to save disk.

### 4.5 Transcription pipeline

Two passes give you both a live view and a high-quality final transcript:

| Pass | When | Engine (default) | Output |
|---|---|---|---|
| **Live** | During the meeting | WhisperKit `small`/`base` or Parakeet streaming, per track, 5–10 s chunks with VAD | Rolling transcript in the UI |
| **Final** | After stop (or every few minutes in the background) | WhisperKit `large-v3-turbo` / Parakeet TDT v3 locally, or a cloud engine (OpenAI `gpt-4o-transcribe`, Deepgram, AssemblyAI, Gemini) if the user opts in | Word-level timestamps per track |

**Engine protocol**

```swift
protocol ASREngine: Sendable {
    var id: String { get }
    func transcribe(file: URL, language: String?) async throws -> [ASRSegment]          // final pass
    func stream(_ buffers: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<ASRSegment, Error> // live
}
struct ASRSegment: Codable, Sendable { var start, end: TimeInterval; var text: String; var words: [Word]; var track: Track }
```

**Diarization (only the "Them" track)**

1. Run the FluidAudio diarizer on the remote track to get `Speaker A/B/C` segments with embeddings.
2. Align ASR words to the diarization segments by timestamp overlap, splitting a segment when the speaker changes mid-sentence.
3. Merge the "Me" track. Where both tracks have speech at the same moment, keep both (overlapping talk).

**Speaker naming (turning "Speaker B" into "Maria Silva")**, combining signals:

1. **Screenshot evidence:** active-speaker name tags from OCR at time *t*, voted against which diarized speaker was talking at *t*. This is the strongest signal for Zoom/Teams.
2. **Transcript cues:** "Thanks, Maria", "John, can you…", self-introductions. Ask the LLM to propose mappings with confidence scores.
3. **Calendar (optional):** attendee list from EventKit for the current event as the candidate set.
4. **Voice memory (optional, v2):** store speaker embeddings for named people, with consent, and auto-match them in future meetings.
5. **UI fallback:** a quick "Who is Speaker B?" chip in the review screen. One rename updates the whole transcript.

> **On "perfect transcripts":** a transcript can be very good, but never guaranteed perfect. Overlapping speech, heavy accents, poor connections and similar voices all cause errors. The design maximizes accuracy (separate tracks, AEC, a high-accuracy second pass, visual speaker evidence, a custom vocabulary list) and makes corrections easy (click any line to edit it or reassign its speaker).

**Custom vocabulary:** per-user and per-meeting glossary (names, product terms, acronyms), passed as the Whisper prompt / cloud ASR keywords and to the LLM cleanup step.

**Optional LLM cleanup pass:** fix punctuation, obvious mis-hearings and glossary terms in chunks, **without** changing meaning or speaker labels. Keep the raw ASR as well and show a diff.

### 4.6 AI provider layer (LLMKit)

```swift
protocol LLMProvider: Sendable {
    var id: String { get }                      // "anthropic-api", "claude-cli", ...
    var capabilities: LLMCapabilities { get }   // .images, .longContext(tokens), .jsonMode
    func complete(_ request: LLMRequest) async throws -> LLMResponse     // text + optional image attachments
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}
```

| Provider | Auth | How | Notes |
|---|---|---|---|
| **Anthropic API** | API key (Keychain) | `POST /v1/messages` with images as base64 blocks | Default models: `claude-sonnet-5-5` (summary), `claude-haiku-5-5` (cheap cleanup), `claude-opus-5-5` (best quality). Models are configurable. |
| **Claude Code CLI** | Your existing `claude` login (Pro/Max subscription) | `claude -p --output-format json` with the prompt on stdin. Screenshots are passed as file paths in the prompt (read-only tools allowed) | No API key needed. |
| **OpenAI API** | API key | Responses API, images as `input_image` | Can also serve as the cloud ASR (`gpt-4o-transcribe`). |
| **Codex CLI** | Your ChatGPT login (`codex login`) | `codex exec --json` (images via `--image`) | No API key needed. |
| **Gemini API** | API key | `generateContent`, inline images, **native audio input** | Gemini can take the audio file directly as a cross-check transcriber. |
| **Gemini CLI** | Google login | `gemini -p` (non-interactive) | |
| **Cursor** | Your Cursor login | `cursor-agent -p --output-format json` | Cursor has no general public LLM API, so the CLI is the only route. |
| **Local (optional)** | none | Ollama / LM Studio HTTP (OpenAI-compatible) | Fully offline mode. |

**CLI provider implementation details**

- Locate binaries by checking `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, and the user's login-shell `PATH` (run `zsh -lc 'command -v claude'` once and cache the result).
- Spawn with `Process`, write the prompt to stdin, parse JSON stdout, and enforce a timeout and cancellation.
- Detect whether the user is logged in (run a cheap no-op prompt; on an auth error show a "Run `claude` in Terminal to log in" hint).
- Run in a temporary working directory that contains **only** the session's transcript and screenshots, and use each CLI's flags to restrict tools to read-only. The CLIs are agents, so they should not be able to touch anything else.
- CLI flags change between versions. Keep the per-CLI argument builders isolated in one file each and cover them with a smoke test.

### 4.7 Summarization

**Input:** speaker-attributed transcript, selected screenshots (key slide changes, capped at about 10–20), OCR text, meeting metadata (app, title, date, duration, participants), user glossary, and optionally the calendar event description.

**Strategy**

- Transcript under about 100k tokens: single pass with images.
- Longer meetings: **map-reduce**. Summarize 15-minute chunks into structured JSON, then reduce them into the final summary.
- Ask for **structured JSON** first (validated with `Codable`), then render Markdown in Swift. This gives deterministic formatting and lets action items feed other features (Reminders/Things/Jira export later).
- Every claim in the summary carries **timestamp references** (`[00:14:32]`) that link back to the transcript line.

**Summary JSON schema (abridged)**

```json
{
  "title": "...", "tldr": "...",
  "participants": [{"name": "...", "role": "..."}],
  "topics": [{"title": "...", "start": "00:03:10", "summary": "..."}],
  "decisions": [{"text": "...", "ref": "00:21:05"}],
  "action_items": [{"owner": "...", "task": "...", "due": "...", "ref": "00:40:12"}],
  "key_takeaways": ["..."],
  "open_questions": ["..."],
  "risks": ["..."],
  "notable_quotes": [{"speaker": "...", "quote": "...", "ref": "..."}],
  "visual_context": [{"ref": "00:12:00", "screenshot": "screenshots/0007_00-12-00.jpg", "description": "Q3 roadmap slide"}]
}
```

Prompt templates are user-editable (Settings → Templates): e.g. "1:1", "Sales call", "Standup", "Interview", "Generic".

### 4.8 Output files

Each session is saved to `~/Documents/PalMeet/2026-10-13 1500 – <Title>/`:

```
audio/them.m4a   audio/me.m4a   audio/mixed.m4a
screenshots/0001_00-00-30.jpg …   screenshots/index.json (OCR + timestamps)
transcript.md      ← human-readable, speaker-attributed
transcript.json    ← words, timings, speakers, confidence
summary.md         ← the deliverable
session.json       ← metadata, provider/model used, settings
```

**`transcript.md` example**

```markdown
# Transcript — Q4 Roadmap Sync
*2026-10-13 · 15:00–15:47 · Microsoft Teams · Participants: Isac (me), Maria Silva, John Park*

**[00:00:12] Maria Silva:** Okay, let's get started. Can everyone see my screen?
**[00:00:16] Isac:** Yes, looks good.
**[00:00:18] John Park:** Yep.
```

**`summary.md` example**

```markdown
# Q4 Roadmap Sync — Summary
**Date:** 2026-10-13 15:00 (47 min) · **App:** Microsoft Teams
**Participants:** Isac, Maria Silva, John Park

## TL;DR
…

## Decisions
- Ship the beta on Nov 4 instead of Oct 28. [00:21:05]

## Action items
| Owner | Task | Due | Ref |
|---|---|---|---|
| John Park | Update the release checklist | Oct 20 | [00:40:12] |

## Key takeaways
## Topics discussed
## Open questions
## Risks / blockers
## Visual context
![Q3 roadmap slide](screenshots/0007_00-12-00.jpg)
```

### 4.9 Multiple simultaneous meetings

**Goal:** record 2+ meetings at once (e.g. a Teams call in the foreground and a Google Meet you are passively listening to in Chrome). Each meeting gets its **own isolated audio, transcript, screenshots, speakers and summary**, with zero cross-contamination.

#### 4.9.1 Session model

- `SessionManager` (actor) owns a dictionary `[SessionID: MeetingSession]`. The app is designed for N sessions **from Phase 1** (even when only one is used) so that multi-meeting support is not a later rewrite.
- `MeetingSession` (actor) owns **everything specific to one meeting**:
  - its `CaptureSource` (window + resolved audio source),
  - its own `RemoteAudioCapture` (process tap or extension stream),
  - its own `SCStream` / `ScreenSampler` on its window,
  - its own ring buffers, file writers, live transcript, diarization state, speaker map, screenshot index and summary job,
  - its own session folder and its own clock (offset 0 = that meeting's start, plus an absolute `hostTime` anchor so the shared mic can be aligned).
- No session-specific state lives in singletons. The only **shared** resources are the ones that have to be: the physical mic (`SharedMicCapture`), the loaded ASR/diarization models (`ASRScheduler`) and the LLM provider pool. Each of these is keyed by `SessionID` on every call.
- Sessions start and stop independently. You can add a second meeting while the first is recording ("+ Add meeting" in the HUD), and stopping one does not affect the other.

#### 4.9.2 Audio isolation: resolving each session's audio source

When a session starts, the `SessionManager` resolves which processes produce its audio and **checks for conflicts** with the sessions already running:

| Situation | Isolation method | Result |
|---|---|---|
| Different apps (Zoom + Teams, Teams + Chrome, Slack + Safari) | One **Core Audio process tap per app family** (app PID + helpers) | ✅ Fully isolated |
| **Chrome: two windows, each with a different profile, one meeting tab per window** (primary target) | **Companion extension installed in each profile** (§4.9.3) | ✅ Isolated |
| Chrome: two windows in the same profile, one meeting tab per window | Same extension, same mechanism | ✅ Isolated |
| Chrome: two meeting tabs in the **same window** | Not a supported scenario (one meeting per window is the rule). Would technically work via the extension but isn't designed or tested for | – |
| Chrome launched as a separate instance (`--user-data-dir=…`) | Separate process tree, so a process tap works even without the extension | ✅ Isolated |
| Safari or Firefox, two meetings | No per-tab audio API is available on macOS | ⚠️ Not isolatable. Suggest Chrome for the second meeting |

> **Why profiles alone don't isolate audio:** all profiles of one Chrome installation run inside **one browser process tree** and share **one audio-service process**, which plays sound for every tab in every profile. A Core Audio tap on Chrome therefore hears both meetings mixed. Isolation has to happen **inside Chrome**, at the tab level, which is what the extension does. (Phase 0 spike #6 verifies this on your machine.)
| Same desktop app, two calls (Zoom, Teams) | Not applicable: these apps only allow one active call | – |
| Web client + desktop client of the same service (Teams app + Teams in Chrome) | Different processes, so separate taps | ✅ Isolated |

- **Conflict detection:** if a new session's resolved process set overlaps an active session's set, the picker shows the conflict before you start. It offers: "Install/enable the browser extension", "Record anyway as *shared audio*" (both sessions are clearly marked as mixed), or "Cancel".
- **Leak check while recording:** cross-correlate the "Them" tracks of concurrent sessions every few seconds. If they are near-identical (the same audio is being captured twice), show a warning badge on both sessions.

#### 4.9.3 Companion Chrome extension: one meeting tab per window, across profiles

This is a **required component** for running two browser meetings at once. The main scenario it is designed for:

```
Chrome window A  (Profile "Work")      → tab: meet.google.com/abc  → Session #1
Chrome window B  (Profile "Client X")  → tab: teams.microsoft.com  → Session #2
```

**Key design points**

- **Installed per profile.** Chrome extensions are per profile, so the extension is installed once in each profile you use for meetings. Every profile's extension instance connects to PalMeet separately and identifies itself with a stable `profileInstanceId` plus a display name the user picks or the app infers (e.g. "Work", "Client X").
- **Unit of capture = the meeting tab in a window.** The extension reports each window it owns: `windowId`, bounds, active tab, and any tabs with meeting URLs (`meet.google.com`, `teams.microsoft.com`, `teams.live.com`, `app.zoom.us`, `*.webex.com`, `whereby.com`, configurable). PalMeet's picker shows one entry per window: *"Chrome · Work · Google Meet – Weekly sync"*. If a window has exactly one meeting tab, that tab is selected automatically.
- **Audio is bound to the tab, not to what is on screen.** `chrome.tabCapture` returns a stream for that specific `tabId` in that specific profile. Switching to another tab in the same window, minimizing the window, or covering it does **not** change or mix the audio. The other profile's meeting is never in that stream.
- **Starting capture (user gesture).** Chrome only allows tab capture after the user invokes the extension on that tab. The flow is: select the window(s) in PalMeet → in each Chrome window the extension's toolbar icon pulses → **one click per window** (or the extension's keyboard shortcut, `chrome.commands`) → `chrome.tabCapture.getMediaStreamId({targetTabId})` → the offscreen document opens the stream. One click per meeting is the lowest friction Chrome permits.
- **Keep it audible:** tab capture mutes the tab locally, so the offscreen document plays the stream back through an `AudioContext` so you still hear the meeting.
- **Transport to the app:** each profile's extension opens its own **localhost WebSocket** to PalMeet and sends 16-bit 48 kHz PCM chunks tagged `(profileInstanceId, windowId, tabId)` → `SessionID`. Pairing: on first install in a profile, Native Messaging hands the extension a per-profile auth token, so a random web page or another app can't inject audio.
- **Screenshots per meeting:**
  - Primary: frames from the **tab's own video track** (request `video: true` in tab capture, sampled at 1 fps). They show only that meeting's tab content, regardless of which window is in front.
  - Fallback: ScreenCaptureKit on the matching `SCWindow`, matched by window bounds plus title (Chrome titles include the active tab and profile name). Frames are **paused and flagged** while the meeting tab is not the active tab in its window, so you never get screenshots of an unrelated tab.
- **Lifecycle:** the session ends (or prompts) when the tab is closed or navigates away from the meeting URL, or the profile window closes. A tab reload re-requests capture with one click.
- **Mute-state signal for the MicRouter:** the extension can read the meeting page's mute button state from the DOM (`aria-pressed` / `aria-label` on Meet's and Teams' mic buttons). This is more reliable than OCR for routing your mic to the right meeting.
- **Other Chromium browsers:** Edge, Arc and Brave install the same extension. Mixing browsers (e.g. a Chrome window + an Edge window) is isolated too, both via the extension and via separate process taps.

**Not covered by design:** two meeting tabs in the same window. The picker will warn ("Move one meeting to its own window").

#### 4.9.4 One microphone, many meetings: the MicRouter

You only speak into one mic. The question is **which meeting(s) heard you**. Recording the mic once and routing it avoids duplicated or misattributed "Me" lines.

- `SharedMicCapture` records **one** continuous `me.m4a` stream (with AEC) to a shared location, using absolute host timestamps.
- `MicRouter` keeps a **routing timeline**: `[(t0, t1, Set<SessionID>)]`. Each session's "Me" track is the slices of the shared mic where that session is in the set.
- **Auto-routing signals**, combined into a per-session "you are live here" score:
  1. **Mute state** of each meeting: from the extension (page DOM) for browser meetings, and through the Accessibility API where it is exposed for desktop apps (e.g. Zoom's "Mute audio/Unmute audio" menu items, Teams' mute button label), and by OCR of the mute icon in screenshots otherwise.
  2. **Mic usage per process** (`kAudioProcessPropertyIsRunningInput`): which meeting apps are reading the mic right now.
  3. **Frontmost window**: which meeting window was focused when you started speaking.
  4. **Conversational fit**, during the final pass: the LLM checks whether a "Me" utterance answers what was just said in meeting A or meeting B.
- **Manual override** in the HUD: per-session mic toggle ("My mic → Meeting A / B / both / none"), plus a hotkey to cycle through them.
- **Fixable afterwards:** because routing is only metadata over one shared recording, the Review screen lets you reassign any "Me" segment to another meeting. Transcripts and summaries regenerate from it.
- **Echo safety:** voice processing cancels everything playing on the output device (all meetings), so meeting A's audio played through speakers does not end up in meeting B's "Me" track. The cross-track dedupe check (§9) runs against **all** active sessions' "Them" tracks, not just its own.

#### 4.9.5 Compute and scheduling

- **Models load once** and are shared (WhisperKit/FluidAudio models are hundreds of MB to over 1 GB).
- `ASRScheduler` (actor) processes the **live** chunks of all sessions in a fair round-robin queue. Sessions where someone is speaking (VAD active) get priority, and each session gets its own decoder state/context.
- Under load (more than 2 sessions, or an older Mac), live ASR degrades gracefully: smaller model, longer chunks, or "live off for background meetings". The **final pass is never skipped**. It is queued and runs after stop.
- Screen sampling at 1 fps per window is cheap. OCR runs only on kept frames.
- Summaries for different sessions run in parallel, up to a configurable concurrency per provider (CLI tools: one at a time per CLI by default).
- **Disk:** about 1 MB/min per AAC track plus screenshots, roughly 100–150 MB per hour per meeting. A disk-space guard warns when space is low.

#### 4.9.6 Outputs for concurrent meetings

- Each meeting gets **its own folder** with the normal layout (§4.8), so files are never shared between meetings.
- `session.json` records `concurrentWith: [sessionIDs]`, the audio isolation method used (`processTap` / `browserExtension` / `sharedAudio`) and the mic routing timeline.
- The shared raw mic recording lives in `~/Documents/PalMeet/.shared-mic/<date>/` and each session's `audio/me.m4a` is exported from it when the session stops. It is deleted once every session that references it has finished.
- The `summary.md` of each meeting is generated **only** from that meeting's data. Optionally (off by default) a "Day digest" can reference several meetings explicitly.

### 4.10 Live Copilot: "what should I say / ask?"

A **toggle button** per meeting session that turns live suggestions on or off:

- **Suggested answers:** when someone asks *you* something, it shows what you could say.
- **Questions to ask:** it proposes good, context-aware questions for the current discussion. In a grooming/refinement session about a new feature, for example: acceptance criteria, edge cases, dependencies, estimation risks, rollout plan.

#### 4.10.1 On/off contract (strict)

- **Default: OFF** for every new session. It is a per-session toggle (🧠 button on the session row and in the copilot panel) plus a global hotkey (`⌃⌥C`) for the frontmost session.
- **When OFF, the feature is completely inactive:** no trigger detection, no context building, no LLM calls, no data sent anywhere for copilot purposes. Recording, transcription and the final summary are unaffected.
- **Turning it OFF mid-meeting** immediately cancels in-flight requests (`Task` cancellation + killing CLI processes) and discards queued triggers. Already-shown cards stay visible until dismissed.
- **Turning it ON mid-meeting** primes the context from the transcript so far (rolling summary + last few minutes), so it is useful right away.
- Enforced in code: `CopilotEngine` only exists while the toggle is ON (created on enable, torn down on disable). A unit test asserts that zero provider calls happen while OFF.
- An optional setting lets the user auto-enable it for chosen meeting types (e.g. always on for "Grooming"). It is off by default.

#### 4.10.2 Triggers

| Trigger | Detection | Output |
|---|---|---|
| **Question directed at me** | Live "Them" transcript → (1) fast local heuristics: question mark/intonation, interrogative patterns in PT/EN, your **name/aliases** mentioned ("Isac, what do you think…"), then end-of-turn detection (VAD silence ≈ 700 ms); (2) a cheap/fast LLM classifier confirms *"is this a question for me?"* | 💬 **Suggested answer** card |
| **Topic or screen change** | New topic detected in the rolling transcript, a new slide/ticket on screen (frame change + OCR), or ~every 2–3 min of active discussion | 💡 **Questions to ask** card (3–5 ranked questions) |
| **Manual "Help me now"** | Hotkey `⌃⌥H` or button | Both, based on the last ~2 minutes |
| **Pending question unanswered** | A question to you from earlier that you never answered (no "Me" speech after it) | Gentle reminder in the panel |

Debounce and limits: at most 1 proactive card per ~60 s, skip if nothing new was said, and a configurable cap on calls per minute. A cost/usage meter is shown in the panel.

#### 4.10.3 Context the copilot uses (per session, isolated)

- **Rolling transcript:** the last ~5 min verbatim + a running summary of everything earlier (updated incrementally, cheap model).
- **Screen context:** latest OCR text and the latest key screenshot. In grooming this is usually the Jira/Linear ticket, Figma screen or spec being shown, which is exactly what good questions need.
- **Meeting mode** (auto-detected from title/transcript, user can change): `Grooming/Refinement`, `Planning`, `1:1`, `Standup`, `Design review`, `Sales/Client`, `Interview`, `Generic`. Each mode has an editable **playbook prompt**. Example, Grooming:
  > Look for gaps in: acceptance criteria, edge cases & error states, dependencies (APIs, other teams), data/migrations, non-functional requirements (performance, security, accessibility, i18n), analytics/telemetry, feature flags & rollout, test strategy, definition of done, estimation risks, scope that could be split.
- **"About me" profile** (Settings): name + aliases used to detect questions for you, role, team, areas of expertise, communication style, answer language (or "same as the meeting").
- **Prep notes / attachments per meeting** (optional): paste the ticket, drop a PDF/spec, add a link. These are sent with prompt caching so they're cheap on repeated calls.
- **Past meetings** (later): summaries of previous meetings in the same series (same calendar event / title) as background.
- **Strict isolation:** a session's copilot only ever sees **that session's** context (same rule as §4.9). With two meetings running, each has its own toggle, its own engine and its own cards.

#### 4.10.4 Answer quality rules (in the system prompt)

- Suggestions are **short and speakable**: 1–3 bullet options, each under ~25 words, plus an optional "more detail" expansion.
- **Grounded only in the provided context.** If the answer depends on facts that are not there, suggest an honest holding answer ("I need to check X in the code, I'll get back by tomorrow") plus a follow-up question, instead of inventing facts.
- **Never commit you to dates or scope** without flagging it ("⚠️ this commits you to Friday").
- Flag the confidence of each suggestion. Answer in the meeting's language.
- Questions to ask are **ranked by impact** and de-duplicated against questions already asked in the meeting (by anyone).

#### 4.10.5 Latency & providers

- **Target:** a suggestion starts appearing within **~2–3 s** after the question ends.
- This requires **live transcription ON** for that session. Enabling the copilot raises the session's priority in the `ASRScheduler` (§4.9.5).
- Use **API providers with streaming** and a fast model by default (e.g. `claude-haiku-5-5`, or the equivalent fast OpenAI/Gemini model), with prompt caching for the static prefix (profile, playbook, prep notes, rolling summary).
- **CLI providers** (`claude -p`, `codex exec`, `gemini -p`, `cursor-agent -p`) are allowed, but their process startup adds seconds. The UI labels them "slower". They remain fine for proactive questions.
- **Optional "Deep answer" (later phase):** for a feasibility question in grooming ("how hard would this be?"), run Claude Code / Codex CLI asynchronously and **read-only** against a code repo folder you linked to the meeting. The answer arrives 20–60 s later as a richer card.

#### 4.10.6 Copilot UI

- **Floating panel** (`NSPanel`, `.nonactivatingPanel`, floating level): it never steals focus from the meeting, sits next to the meeting window, is resizable and collapses to a small pill.
- **Hidden from screen sharing and adjustable transparency:** same as every PalMeet window (§4.12).
- **Cards:**
  - 💬 *"Maria asked: 'Can we ship this by Friday?'"* → 2–3 answer options.
  - 💡 *"Questions to ask"* → ranked list.
  - Each card has actions: **copy**, **pin**, **dismiss**, 👍/👎 (feedback tunes the playbook), and **"I used this"**.
- With multiple sessions, the panel shows the frontmost meeting's cards, with tabs per session in that session's color.

#### 4.10.7 Persistence

- Suggestions are stored in the session (`copilot.json`: trigger, timestamp, context reference, suggestion, used/dismissed).
- The final `summary.md` gains an optional section, **"Questions I raised / commitments I made"**, cross-checked against what you actually said in the "Me" track.

### 4.11 Global hotkeys

Every feature is reachable from the keyboard, **without switching away from the meeting**.

- **Implementation:** the [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) Swift package. It is built on Carbon `RegisterEventHotKey`, so it works system-wide **without** the Accessibility permission, and it includes a SwiftUI recorder view for the Settings screen.
- **All shortcuts are customizable** in Settings → Hotkeys. Any shortcut can be cleared or changed, and the app warns about conflicts with system shortcuts and with other PalMeet shortcuts. "Reset to defaults" is available.
- **Target session:** with several meetings running, session-level shortcuts act on the session whose meeting window is **frontmost**. Otherwise they act on the most recently used session, and the HUD briefly flashes which session was affected.
- A **cheat sheet** overlay (`⌃⌥/`) lists all current shortcuts.

**Defaults** (the `⌃⌥` prefix rarely collides with meeting apps or macOS):

| Area | Action | Default |
|---|---|---|
| Recording | Start recording the frontmost meeting window (or open the picker) / Stop | `⌃⌥R` |
| | Add another meeting (open picker in multi-select) | `⌃⌥N` |
| | Pause / resume the current session | `⌃⌥P` |
| | Stop & generate summary | `⌃⌥E` |
| Context | Mark moment + screenshot | `⌃⌥S` |
| | Quick note (small text field, timestamped into the transcript) | `⌃⌥K` |
| Mic | Cycle mic routing between active meetings | `⌃⌥M` |
| Copilot | Toggle copilot ON/OFF for the session | `⌃⌥C` |
| | "Help me now" | `⌃⌥H` |
| | Copy suggestion 1 / 2 / 3 | `⌃⌥1` / `⌃⌥2` / `⌃⌥3` |
| | Next / previous card | `⌃⌥]` / `⌃⌥[` |
| Windows | Show / hide copilot panel | `⌃⌥Space` |
| | Show / hide main window | `⌃⌥W` |
| | **Panic hide**: instantly hide *all* PalMeet windows (recording continues) | `⌃⌥\` |
| Appearance | Opacity up / down (10% steps) | `⌃⌥↑` / `⌃⌥↓` |
| | Reset opacity to 100% | `⌃⌥0` |
| | Toggle click-through mode | `⌃⌥T` |
| Help | Show shortcut cheat sheet | `⌃⌥/` |

### 4.12 Window privacy (hidden from screen sharing) & transparency

#### 4.12.1 Hidden from screen sharing / recording

**Goal:** when you share your screen in Zoom, Teams, Meet, Slack, etc., or someone records it, **PalMeet's windows (copilot panel, HUD, main window) are not visible** to viewers. You still see them on your own display.

These layers stack. Each one covers a gap the others leave:

1. **Exclude windows from capture:** set `NSWindow.sharingType = .none` on every PalMeet window and panel. This is the official AppKit flag that excludes a window from screen capture, and is what "invisible overlay" apps rely on.
   - ⚠️ **Caveat:** how well capture tools honor this varies by macOS version and by capture API. There have been reports that ScreenCaptureKit-based capture (which Chrome, Zoom and Teams increasingly use) on recent macOS versions does not reliably exclude these windows. So this layer is **necessary but not guaranteed**. That is why layers 2–4 exist and why Phase 0 tests it per app.
2. **Built-in "Invisibility check":** a button (and an automatic check at launch and after macOS updates). PalMeet captures the full display itself through ScreenCaptureKit with no exclusions, plus the legacy `CGWindowList` API, and checks whether its own windows appear (it draws a unique marker pattern and searches for it in the captured image). The result is shown per capture method: "✅ hidden from ScreenCaptureKit capture / ⚠️ visible to …". A per-app compatibility table from the Phase 0 tests is shown alongside.
3. **Auto-hide while you share (on by default):** if a screen-share start is detected, PalMeet windows are hidden automatically, or switched to a "your eyes only" mode if layer 1 is verified working for that app. Detection signals:
   - **Browser meetings:** the Chrome extension sees the page's "You are presenting" state / `getDisplayMedia` activity.
   - **Zoom/Teams desktop:** Accessibility (AX) labels ("Stop share", sharing toolbar window) and OCR of the share toolbar.
   - Manual "I'm sharing" toggle.
   - The windows reappear when sharing stops.
4. **Panic hide** (`⌃⌥\`) hides everything instantly as a last resort.

Related "low profile" options in Settings → Privacy:

- **No Dock icon / not in ⌘-Tab** (`NSApp.setActivationPolicy(.accessory)`), so the app doesn't show up in the app switcher during a share. Menu bar only, or **no menu bar icon at all** (then reachable only via hotkeys).
- **Exclude from Mission Control / window cycling:** `collectionBehavior` `.transient`, `.ignoresCycle`, `.fullScreenAuxiliary`, and `canJoinAllSpaces` so the panel follows you across Spaces and full-screen meetings.
- **Notifications:** off or silent during meetings, so banners don't appear on a shared screen.
- **Best practice hint:** share a specific **window or tab** instead of the entire screen. PalMeet windows are then never part of the share, regardless of OS behavior.

> **Note:** hiding PalMeet's *windows* from viewers is about keeping your private notes and suggestions private. The recording-consent reminder (§5) still applies.

#### 4.12.2 Transparency & appearance

- **Opacity control on every window:** a slider in the panel header and in Settings → Appearance, plus hotkeys (`⌃⌥↑`/`⌃⌥↓` in 10% steps, `⌃⌥0` reset). The range is 20%–100%, remembered **per window** (copilot panel, HUD, main window) and restored on launch.
- **Two independent sliders:** **background opacity** (`NSVisualEffectView` material + tint alpha) and **content opacity** (`NSWindow.alphaValue`). This makes it possible to have a nearly transparent background with readable text.
- **Click-through mode** (`⌃⌥T`): `ignoresMouseEvents = true`, so you can click the meeting window behind the panel. A small lock badge shows that it's active, and the same hotkey turns it off.
- **Auto-fade:** optionally fade to a lower opacity when the mouse isn't over the panel, and return to full opacity on hover or when a new suggestion arrives.
- **Always on top** toggle (floating window level), compact/expanded layouts, font size, light/dark/auto.

---

## 5. Permissions, privacy & legal

| Permission | Why | Info.plist / entitlement |
|---|---|---|
| Screen & System Audio Recording | ScreenCaptureKit window capture | (TCC prompt on first `SCShareableContent` call) |
| System audio recording (process taps) | Core Audio tap | `NSAudioCaptureUsageDescription` |
| Microphone | Your voice | `NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input` |
| Automation (optional) | Read browser tab titles | `NSAppleEventsUsageDescription` |
| Calendars (optional) | Attendee names | `NSCalendarsFullAccessUsageDescription` |

- An **onboarding flow** checks each permission and deep-links to the right System Settings pane.
- **Consent:** recording laws vary (one-party vs all-party consent). Show a reminder on start, and optionally a one-click "post a recording notice in the meeting chat" text to copy.
- **Privacy modes:** "Local only" (local ASR + local LLM/no summary), "Local ASR + cloud LLM" (default), "Full cloud". Show clearly in the UI which data leaves the machine and to which provider.
- Keys live in the Keychain. Session data stays local, with optional retention policies (auto-delete audio after N days, keep the text).

---

## 6. UI / UX

- **Menu bar app** (`MenuBarExtra`) with a dock window available on demand: ● Record, source name, elapsed time, live levels for Me/Them, "📸 mark moment", Stop.
- **Multiple sessions in the menu bar:** one row per active meeting, each with its own color, source icon, elapsed time, level meters, mic-routing toggle (🎙 on/off), "📸" and Stop. The menu bar icon shows the number of active recordings.
- **Global hotkeys** for every feature, all customizable (full list in §4.11).
- **Privacy & appearance:** every window is hidden from screen sharing, auto-hides while you share, and has a panic hide. Transparency and click-through are adjustable per window (§4.12).
- **Source picker:** grid of window thumbnails (plus browser tabs when the extension is installed) with meeting apps first. **Multi-select is allowed.** The picker shows the isolation status of each selection (✅ isolated / ⚠️ shared audio / 🧩 needs extension) and toggles for "Include my mic", "Screenshots every 30 s", "Language: auto".
- **Live view:** rolling transcript with speaker colors, plus an optional "Ask about this meeting so far" box (LLM over the transcript so far).
- **🧠 Copilot toggle** on every session row, in the live view and via hotkey. It is clearly lit when ON and grey when OFF. The floating copilot panel is described in §4.10.6.
- **Review screen:** audio player synced to the transcript (click a line to seek), speaker rename chips, inline edits, screenshot filmstrip, a "Regenerate summary" picker (provider, model, template), and Export (Markdown, copy to clipboard, open in Obsidian folder).
- **Library:** searchable list of past meetings (full-text search over transcripts).

---

## 7. Implementation roadmap

### Phase 0: Spikes to de-risk (1 week)
1. **Process tap spike:** capture Zoom, Teams and a Chrome Meet tab to WAV. Verify that helper processes are included and confirm the permission prompts.
2. **Mic + AEC spike:** record mic with voice processing while meeting audio plays through speakers (not headphones). Measure the echo leak.
3. **ASR spike:** WhisperKit vs FluidAudio/Parakeet on a 30-min sample. Measure WER, speed and memory on Apple Silicon.
4. **Diarization spike:** FluidAudio on a multi-speaker remote track.
5. **CLI spike:** call `claude -p`, `codex exec`, `gemini -p` and `cursor-agent -p` from a Swift `Process` with a transcript and an image, and check that JSON output parses.
6. **Concurrency spike:** run two process taps at once (Teams + Chrome) and verify the audio is isolated. Confirm that two Chrome profiles share one audio process (a tap hears both). Then prototype `chrome.tabCapture` → WebSocket → Swift with **two profiles, one meeting tab each**, and verify that each stream contains only its own tab.
7. **Invisibility spike:** a floating panel with `sharingType = .none`. Share the entire screen in Zoom, Teams (desktop), Google Meet (Chrome), Slack huddle, and record with QuickTime, the macOS screenshot tool and OBS. Record which ones show the panel. This builds the compatibility table for §4.12.1 and decides how aggressive the auto-hide default should be.
8. **Copilot latency spike:** measure time from end of question to first streamed token, for API providers (fast models) vs CLI providers.

### Phase 1: MVP (2–3 weeks)
- Xcode project, SwiftUI app shell, menu bar, onboarding and permissions.
- `SessionManager` / `MeetingSession` architecture built for N sessions (the UI may expose only one at first). `SharedMicCapture` + a simple `MicRouter` (manual routing).
- Hotkey infrastructure (`KeyboardShortcuts`) with the core recording shortcuts. All windows use `sharingType = .none`, plus the panic-hide hotkey and a basic opacity slider.
- Source picker (windows/apps, thumbnails).
- Remote audio (tap) + mic → `them.m4a`, `me.m4a`.
- Periodic screenshots (fixed interval) + OCR.
- Final-pass local ASR per track → transcript with "Me" vs "Them".
- One provider end to end (Anthropic API **and** Claude CLI) → `summary.md`.
- Session folder output.

### Phase 2: Quality (2–3 weeks)
- Diarization + alignment → Speaker A/B/C.
- Speaker naming from screenshot evidence + LLM transcript cues + rename UI.
- Change-detection screenshots, "mark moment" hotkey.
- Live streaming transcript.
- Remaining providers: OpenAI API, Codex CLI, Gemini API/CLI, Cursor CLI.
- Map-reduce summarization for long meetings, templates.

### Phase 2b: Multiple meetings (2 weeks)
- Multi-select picker, "+ Add meeting" while recording, multi-row menu bar HUD.
- Source-conflict detection and the cross-session leak check.
- Chromium companion extension: per-profile install and pairing, window/meeting-tab listing, per-tab audio + video capture, WebSocket transport, DOM mute-state signal.
- `MicRouter` auto-routing (Accessibility mute state, per-process mic usage, focus) + reassigning "Me" segments in Review.
- `ASRScheduler` fair queue with load-based degradation.

### Phase 2c: Live Copilot + privacy/appearance (2–3 weeks)
- Copilot toggle with the strict on/off contract and its unit test, floating non-activating panel, cards.
- Trigger detection (questions to me, topic/screen changes, "help me now"), rolling-summary context builder, "About me" profile, meeting modes and playbooks (Grooming first), prep notes with prompt caching.
- Streaming fast-model path; CLI providers labeled "slower".
- Full hotkey set + Settings recorder + cheat sheet.
- Invisibility check, auto-hide while sharing (extension/AX/OCR signals), low-profile options.
- Separate background/content opacity, click-through, auto-fade.

### Phase 3: Polish (2 weeks)
- Review screen with synced playback and inline editing.
- Library + search, retention policies.
- Glossary/custom vocabulary, LLM cleanup pass with diff.
- Auto-detect meetings, calendar integration.
- Signing, notarization, Sparkle updates, crash reporting (opt-in).

### Phase 4: Extras (later)
- Voice-profile memory for recurring participants.
- Copilot "Deep answer": read-only Claude Code / Codex run against a linked repo for feasibility questions. Copilot context from past meetings in the same series.
- Export action items to Reminders / Things / Linear / Jira / Notion.
- "Ask anything across all meetings" (local embedding index).
- Local LLM (MLX / Ollama) fully offline mode.

---

## 8. Testing strategy

- **Fixture meetings:** a few recorded multi-speaker sessions (with consent) with hand-made reference transcripts. Track WER and DER (diarization error rate) in CI as regression metrics.
- **Unit tests:** alignment/merge logic, Markdown rendering, JSON schema decoding, CLI argument builders, frame change detection.
- **Integration tests:** providers against recorded HTTP fixtures, with an opt-in live test using real keys.
- **Manual matrix:** Zoom / Teams (new client) / Slack huddle / Meet in Chrome, Safari and Arc; with speakers vs headphones; Bluetooth device switching mid-call; 2-hour meeting (memory and disk).
- **Isolation tests:** play distinct known audio (e.g. different spoken number sequences) into two or three concurrent sources and assert that each session's transcript contains only its own sequence. Combinations: **Chrome profile A window + Chrome profile B window (primary)**, two windows in the same profile, Teams + Chrome, Zoom + Safari. Include switching tabs, minimizing and covering windows during the test. Also test the mic routing timeline when switching which meeting you are unmuted in.
- **Copilot tests:**
  - question-to-me detection precision/recall on fixture meetings (PT and EN),
  - latency budget (≤ 3 s to first token with API providers),
  - **zero provider calls while the toggle is OFF** (mock provider asserts no calls), and cancellation when switched OFF mid-request,
  - per-session isolation of copilot context.
- **Privacy/appearance tests:** automated invisibility check (marker search in a ScreenCaptureKit capture) in CI on each supported macOS version, a manual share matrix per meeting app, hotkey conflict detection, and opacity/click-through state persistence.
- **Load test:** three concurrent 1-hour sessions on a base M1. Check that live ASR keeps up (or degrades as designed) and that no audio is dropped.

---

## 9. Key risks & mitigations

| Risk | Mitigation |
|---|---|
| Browser plays audio from helper processes, so the tap gets silence | Include all processes in the bundle family. Fall back to the SCK app filter. Offer the Chrome extension in v2. |
| Can't isolate one browser *tab* natively | Recommend popping the meeting tab into its own window. Extension in v2. |
| Echo of remote audio in the mic track (speakers, no headphones) | Voice processing AEC, plus cross-track dedupe: drop "Me" segments that closely match simultaneous "Them" text. |
| Diarization confuses similar voices | Visual active-speaker evidence, easy manual relabel, voice memory later. |
| CLI tools change flags or output format | One adapter per CLI, version detection, smoke tests, clear error UI. |
| Long meetings exceed context or cost limits | Map-reduce, image cap, cheaper model for chunk summaries. |
| macOS permission prompts / TCC resets after re-signing | Stable signing identity during dev, onboarding checker. |
| Legal/consent | Consent reminder, local-first defaults, retention controls. |
| Two Chrome windows/profiles mix their audio (one shared audio process) | Per-profile extension with tab-bound capture. Conflict detection before start. Clear "shared audio" labeling if the extension is missing in a profile. |
| `sharingType = .none` not honored by some capture paths (e.g. ScreenCaptureKit on recent macOS) | Built-in invisibility check, auto-hide while sharing, panic hotkey, "share a window, not the screen" guidance, and a per-app compatibility table. |
| Copilot too slow to be useful | Fast streaming models, prompt caching, local trigger heuristics before the LLM, priority live ASR for copilot sessions. |
| Copilot suggests wrong or invented facts, or commitments | Grounding rules, holding-answer pattern, commitment warnings, confidence labels. You always decide what to say. |
| Copilot cost or distraction | Off by default, debounce/rate caps, usage meter, compact layout. |
| Hotkey collisions with other apps | Rarely used `⌃⌥` prefix, conflict detection, fully remappable. |
| Extension not installed in one of the profiles | The picker detects which profiles are paired and offers a one-click "Install in this profile" link. |
| Safari/Firefox meetings can't be split per tab | Documented limitation. Suggest a different browser or the desktop app for the second meeting. |
| Your voice is attributed to the wrong meeting | Auto-routing signals, manual override, and reassignment in Review (routing is metadata, so nothing is lost). |
| CPU/ANE contention with several live sessions | Shared models, fair scheduler, degraded live mode. The final pass is always complete. |
| State accidentally shared between sessions (bugs) | Per-session actors, no session state in singletons, `SessionID` required on every shared-service API, isolation tests in CI. |

---

## 10. Open decisions (defaults chosen; change if you prefer)

1. **Minimum macOS:** 15.0 (default). Alternative: 14.2, the minimum for process taps.
2. **Default local ASR:** WhisperKit (more languages, very mature) vs FluidAudio Parakeet (faster, best for English and European languages). Decide after the Phase 0 spike.
3. **Default summary provider:** Claude CLI if installed and logged in, otherwise ask for an API key on first run.
4. **Distribution:** direct download (Developer ID + notarization). The App Store is not viable because of the sandbox and CLI usage.
5. **Default language(s):** auto-detect, with a pinned option (e.g. Portuguese/English meetings).
6. **Max concurrent meetings:** soft limit of 3 (configurable). Beyond that, live transcription is off for background sessions.
7. **Default mic routing when several meetings are active:** auto (mute state + focus), with a visible indicator of where your mic is going.
8. **Copilot default provider/model:** a fast API model (e.g. `claude-haiku-5-5`), with the summary still using the higher-quality model. Copilot is OFF by default for every session.
9. **Hotkey prefix:** `⌃⌥` (Control+Option). All shortcuts can be remapped.
10. **Auto-hide while sharing:** ON by default until the Phase 0 invisibility spike shows `sharingType = .none` is reliable for a given app.
