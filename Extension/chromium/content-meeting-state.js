// PalMeet content script (meeting sites only). Polls the page every second for the
// microphone mute state and whether the user is presenting, and reports changes to the
// service worker. While the tab is recorded it also reports live captions and "is speaking"
// indicators (see speaker-detection.js) so PalMeet can tell who said what. Values are `null`
// when they cannot be determined — selectors on these sites change often and UIs are localized,
// so everything here is best effort.
(() => {
  const POLL_MS = 1000;
  const HEARTBEAT_MS = 10_000;
  const host = location.hostname;

  const label = (el) =>
    (el.getAttribute('aria-label') || el.getAttribute('data-tooltip') || el.getAttribute('title') || '')
      .trim()
      .toLowerCase();

  const isVisible = (el) => el.getClientRects().length > 0;

  const buttons = (selector = 'button, [role="button"]') =>
    Array.from(document.querySelectorAll(selector)).filter(isVisible);

  // ---- mute state -------------------------------------------------------

  function googleMeetMuted() {
    // Meet: <button aria-label="Turn off microphone (⌘ + d)" data-is-muted="false">
    for (const b of buttons('[data-is-muted]')) {
      const l = label(b);
      if (l.includes('microphone') || l.includes('mic')) return b.getAttribute('data-is-muted') === 'true';
    }
    for (const b of buttons()) {
      const l = label(b);
      if (l.startsWith('turn on microphone')) return true;
      if (l.startsWith('turn off microphone')) return false;
    }
    return null;
  }

  function teamsMuted() {
    // Teams web: #microphone-button / [data-tid="microphone-button"], label "Mute"/"Unmute" (+ shortcut).
    const candidates = buttons('#microphone-button, [data-tid="microphone-button"], [data-tid="toggle-mute"]');
    for (const b of candidates) {
      const l = label(b);
      if (l.startsWith('unmute')) return true;
      if (l.startsWith('mute')) return false;
      const stateAttr = b.getAttribute('data-state');
      if (stateAttr === 'mic-off') return true;
      if (stateAttr === 'mic') return false;
    }
    return genericMuted();
  }

  function genericMuted() {
    // "Unmute", "Unmute my microphone", "Unmute mic (Ctrl+Shift+M)" → muted.
    // "Mute", "Mute my microphone", "Mute mic" → live. Ignores "mute all", "mute participant", ….
    const unmute = /^unmute(?:\s+(?:my\s+)?(?:mic|microphone|audio))?(?:\s*[(,]|$)/;
    const mute = /^mute(?:\s+(?:my\s+)?(?:mic|microphone|audio))?(?:\s*[(,]|$)/;
    for (const b of buttons()) {
      const l = label(b);
      if (!l) continue;
      if (unmute.test(l)) return true;
      if (mute.test(l)) return false;
    }
    return null;
  }

  function muted() {
    if (host === 'meet.google.com') return googleMeetMuted();
    if (host.startsWith('teams.')) return teamsMuted();
    return genericMuted();
  }

  // ---- presenting state -------------------------------------------------

  const STOP_SHARE_SELECTOR = [
    '[data-tid="stop-sharing-button"]',
    '[aria-label*="stop presenting" i]',
    '[aria-label*="stop sharing" i]',
    '[aria-label*="stop share" i]',
  ].join(',');

  const START_SHARE = /^(present now|share screen|share content|share|start sharing|start share|share your screen)\b/;

  const PRESENTING_TEXT = /(you are presenting|you're presenting|you are sharing|you're sharing|you are screen sharing)/i;

  function presentingBannerVisible() {
    // Cheap scan of short text nodes only (banners are short strings).
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    let checked = 0;
    while ((node = walker.nextNode()) && checked < 5000) {
      checked++;
      const text = node.nodeValue;
      if (text && text.length < 80 && PRESENTING_TEXT.test(text)) {
        const el = node.parentElement;
        if (el && isVisible(el)) return true;
      }
    }
    return false;
  }

  function presenting() {
    if (buttons(STOP_SHARE_SELECTOR).length > 0) return true;
    if (document.body && presentingBannerVisible()) return true;
    // A visible "share/present" control with no "stop" control → not presenting.
    for (const b of buttons()) {
      if (START_SHARE.test(label(b))) return false;
    }
    return null;
  }

  // ---- reporting ---------------------------------------------------------

  let last = null;
  let lastSentAt = 0;
  let timer = null;

  function poll() {
    let current;
    try {
      current = { muted: muted(), presenting: presenting() };
    } catch {
      current = { muted: null, presenting: null };
    }
    const changed = !last || last.muted !== current.muted || last.presenting !== current.presenting;
    if (!changed && Date.now() - lastSentAt < HEARTBEAT_MS) return;
    last = current;
    lastSentAt = Date.now();
    try {
      chrome.runtime.sendMessage({ source: 'content', type: 'meetingState', ...current }).catch(() => {});
    } catch {
      // Extension reloaded/updated: this script is orphaned, stop polling.
      clearInterval(timer);
    }
  }

  timer = setInterval(poll, POLL_MS);
  poll();

  // ---- who is speaking (captions + speaking indicators) ------------------------------------------

  const detection = globalThis.PalMeetSpeakerDetection;
  if (!detection) return;
  const SPEAKERS_POLL_MS = 400;
  const STATUS_POLL_MS = 3000;
  const DIAGNOSTICS_MS = 60_000;
  const tracker = new detection.CaptionTracker(Math.random().toString(36).slice(2, 8));
  let capturing = false;
  let diagnosticsWanted = false;
  let diagnostics = null;
  let meetWatcher = null;
  let lastSpeaking = null;
  let captionsSeen = 0;
  let orphaned = false;

  function sendToBackground(message) {
    try {
      return chrome.runtime.sendMessage({ source: 'content', ...message });
    } catch {
      orphaned = true;
      return Promise.resolve(null);
    }
  }

  async function refreshStatus() {
    if (orphaned) return;
    const status = await sendToBackground({ type: 'captureStatus' }).catch(() => null);
    capturing = !!status?.capturing;
    if (capturing && host === 'meet.google.com' && !meetWatcher && document.body) {
      meetWatcher = new detection.MeetSpeakingWatcher(document);
      meetWatcher.start();
    } else if (!capturing && meetWatcher) {
      meetWatcher.stop();
      meetWatcher = null;
    }
    diagnosticsWanted = capturing && !!status?.diagnostics;
    if (diagnosticsWanted && !diagnostics && document.body) {
      diagnostics = new detection.PageDiagnostics(document);
      diagnostics.start();
    } else if (!diagnosticsWanted && diagnostics) {
      diagnostics.stop();
      diagnostics = null;
    }
  }

  function pollSpeakers() {
    if (orphaned || !capturing) return;
    let captions = [];
    let speaking = null;
    try {
      captions = tracker.update(detection.readCaptions(document, host));
      speaking = detection.readSpeaking(document, host, meetWatcher);
    } catch {
      return;
    }
    captionsSeen += captions.length;
    const speakingChanged = JSON.stringify(speaking) !== JSON.stringify(lastSpeaking);
    if (captions.length === 0 && !speakingChanged) return;
    lastSpeaking = speaking;
    sendToBackground({ type: 'speakerActivity', at: Date.now(), captions, speaking }).catch(() => {});
  }

  function reportDiagnostics() {
    if (orphaned || !diagnostics) return;
    let payload;
    try {
      payload = diagnostics.report(captionsSeen, lastSpeaking);
    } catch {
      return;
    }
    payload.host = host;
    sendToBackground({ type: 'pageDiagnostics', at: Date.now(), payload }).catch(() => {});
  }

  const speakerTimers = [
    setInterval(refreshStatus, STATUS_POLL_MS),
    setInterval(pollSpeakers, SPEAKERS_POLL_MS),
    setInterval(reportDiagnostics, DIAGNOSTICS_MS),
  ];
  const stopWhenOrphaned = setInterval(() => {
    if (!orphaned) return;
    for (const t of speakerTimers) clearInterval(t);
    clearInterval(stopWhenOrphaned);
    diagnostics?.stop();
    meetWatcher?.stop();
  }, 5000);
  refreshStatus();
})();
