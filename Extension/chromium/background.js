// PalMeet Bridge — service worker (ES module).
// Owns the control WebSocket to the PalMeet app, reports windows/tabs, handles
// startCapture/stopCapture and turns the user's action click into a tab capture.
// See PROTOCOL.md for the wire protocol.

import { isMeetingUrl } from './meeting-patterns.js';

const NATIVE_HOST = 'app.palmeet.bridge';
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const OFFSCREEN_PATH = 'offscreen.html';
const WINDOWS_DEBOUNCE_MS = 300;
const PING_INTERVAL_MS = 20_000;
const MAX_BACKOFF_MS = 30_000;
const KEEPALIVE_ALARM = 'palmeet-keepalive';

const COLORS = { idle: '#5f6368', rec: '#d93025', pulseA: '#d93025', pulseB: '#f9ab00', error: '#b06000' };

// ---------------------------------------------------------------------------
// State. `mem` mirrors chrome.storage.session so it survives service-worker restarts.
//   pending:  { [windowId]: { sessionId, tabId } }      — startCapture waiting for a click
//   captures: { [sessionId]: { windowId, tabId, userInitiated } }
// ---------------------------------------------------------------------------

let mem = null;
let loading = null;

async function state() {
  if (mem) return mem;
  if (!loading) {
    loading = chrome.storage.session.get(['pending', 'captures']).then((s) => {
      mem = { pending: s.pending ?? {}, captures: s.captures ?? {} };
      return mem;
    });
  }
  return loading;
}

async function persist() {
  if (!mem) return;
  await chrome.storage.session.set({ pending: mem.pending, captures: mem.captures });
}

function captureForTab(tabId) {
  if (!mem) return null;
  for (const [sessionId, c] of Object.entries(mem.captures)) {
    if (c.tabId === tabId) return { sessionId, ...c };
  }
  return null;
}

/** Set by the app (welcome.options): record which page elements change while the tab is captured. */
let pageDiagnosticsEnabled = false;

/** Last meeting-page state per tab, from the content script. */
const meetingStateByTab = new Map();

// ---------------------------------------------------------------------------
// Profile identity
// ---------------------------------------------------------------------------

async function profileInstanceId() {
  const { profileInstanceId: existing } = await chrome.storage.local.get('profileInstanceId');
  if (existing) return existing;
  const id = crypto.randomUUID();
  await chrome.storage.local.set({ profileInstanceId: id });
  return id;
}

async function profileLabel(id) {
  const { profileLabel: label } = await chrome.storage.local.get('profileLabel');
  if (label && label.trim()) return label.trim();
  try {
    // Only works if the user granted the optional "identity" + "identity.email" permissions.
    if (chrome.identity?.getProfileUserInfo) {
      const info = await chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' });
      if (info?.email) return info.email;
    }
  } catch {
    // Permission not granted; fall through.
  }
  return `Profile ${id.slice(0, 6)}`;
}

function browserName() {
  if (navigator.brave) return 'Brave';
  const brands = (navigator.userAgentData?.brands ?? []).map((b) => b.brand);
  const known = [
    ['Microsoft Edge', 'Edge'],
    ['Brave', 'Brave'],
    ['Opera', 'Opera'],
    ['Vivaldi', 'Vivaldi'],
    ['Arc', 'Arc'],
    ['Google Chrome', 'Chrome'],
    ['Chromium', 'Chromium'],
  ];
  for (const [brand, name] of known) {
    if (brands.includes(brand)) return name;
  }
  return 'Chromium';
}

async function helloMessage(token, role = 'control') {
  const id = await profileInstanceId();
  return {
    type: 'hello',
    token,
    profileInstanceId: id,
    profileLabel: await profileLabel(id),
    browser: browserName(),
    extensionVersion: EXTENSION_VERSION,
    role,
  };
}

// ---------------------------------------------------------------------------
// Connection to the app
// ---------------------------------------------------------------------------

let ws = null;
let authenticated = false;
let bridge = null; // { port, token } of the current connection
let connecting = false;
let backoffMs = 1000;
let reconnectTimer = null;
let pingTimer = null;

async function setStatus(connected, message) {
  await chrome.storage.session.set({
    status: { connected, message, port: bridge?.port ?? null, updatedAt: Date.now() },
  });
  refreshBadges();
}

/** Asks the native host (= the PalMeet app binary) for {port, token}. */
async function fetchBridgeInfo() {
  try {
    const reply = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { type: 'getBridgeInfo' });
    if (reply?.type === 'bridgeInfo' && Number.isInteger(reply.port) && typeof reply.token === 'string') {
      const info = { port: reply.port, token: reply.token };
      await chrome.storage.local.set({ bridgeInfo: info });
      return info;
    }
    await setStatus(false, reply?.message ?? 'PalMeet is not running.');
    return null;
  } catch (error) {
    // Host not installed / not allowed: fall back to the last known info.
    const { bridgeInfo } = await chrome.storage.local.get('bridgeInfo');
    if (bridgeInfo?.port && bridgeInfo?.token) return bridgeInfo;
    await setStatus(
      false,
      `Can't reach PalMeet's native host (${error?.message ?? error}). ` +
        'In PalMeet open Settings → Browser extension → Install browser support.'
    );
    return null;
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = backoffMs;
  backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

async function connect() {
  if (connecting) return;
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  connecting = true;
  try {
    const info = await fetchBridgeInfo();
    if (!info) {
      scheduleReconnect();
      return;
    }
    const socket = new WebSocket(`ws://127.0.0.1:${info.port}/`);
    ws = socket;
    authenticated = false;
    socket.onopen = async () => {
      bridge = info;
      socket.send(JSON.stringify(await helloMessage(info.token, 'control')));
    };
    socket.onmessage = (event) => {
      if (typeof event.data !== 'string') return;
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      onServerMessage(socket, message).catch((e) => console.warn('PalMeet: message handling failed', e));
    };
    socket.onclose = async (event) => {
      if (ws !== socket) return;
      ws = null;
      authenticated = false;
      clearInterval(pingTimer);
      pingTimer = null;
      if (event.code === 4401) {
        // Token rotated or stale cache: forget it and ask the native host again.
        await chrome.storage.local.remove('bridgeInfo');
      }
      await setStatus(false, event.code === 4401 ? 'Pairing token rejected; retrying.' : 'Disconnected from PalMeet.');
      if (event.code !== 4409) scheduleReconnect(); // 4409 = superseded by a newer connection
    };
    socket.onerror = () => {
      /* onclose follows */
    };
  } finally {
    connecting = false;
  }
}

function send(message) {
  if (ws && ws.readyState === WebSocket.OPEN && authenticated) {
    ws.send(JSON.stringify(message));
    return true;
  }
  return false;
}

function sendCaptureState(sessionId, captureState, extra = {}) {
  send({ type: 'captureState', sessionId, state: captureState, ...extra });
}

async function onServerMessage(socket, message) {
  switch (message?.type) {
    case 'welcome': {
      if (socket !== ws) return;
      authenticated = true;
      pageDiagnosticsEnabled = message.options?.pageDiagnostics === true;
      backoffMs = 1000;
      clearInterval(pingTimer);
      pingTimer = setInterval(() => send({ type: 'ping' }), PING_INTERVAL_MS);
      await setStatus(true, 'Connected to PalMeet.');
      await sendWindowsNow();
      await reannounce();
      await updateOffscreenBridge();
      break;
    }
    case 'startCapture':
      await handleStartCapture(message);
      break;
    case 'stopCapture':
      await stopCapture(message.sessionId, 'Stopped by PalMeet', true);
      break;
    case 'reloadExtension':
      // PalMeet was updated and this folder holds newer files: reload, but never in the middle of a recording.
      reloadWhenIdle = true;
      await reloadIfIdle();
      break;
    case 'pong':
    default:
      break;
  }
}

let reloadWhenIdle = false;

async function reloadIfIdle() {
  if (!reloadWhenIdle) return;
  const st = await state();
  if (Object.keys(st.captures).length > 0 || Object.keys(st.pending).length > 0) return;
  chrome.runtime.reload();
}

/** After a (re)connect, tell the app about captures and pending requests it may not know. */
async function reannounce() {
  const st = await state();
  for (const [sessionId, c] of Object.entries(st.captures)) {
    sendCaptureState(sessionId, 'capturing', { windowId: c.windowId, tabId: c.tabId, userInitiated: !!c.userInitiated });
    forwardMeetingState(c.tabId);
  }
  for (const p of Object.values(st.pending)) {
    sendCaptureState(p.sessionId, 'awaitingGesture');
  }
}

// ---------------------------------------------------------------------------
// Windows / tabs reporting
// ---------------------------------------------------------------------------

let windowsTimer = null;

function scheduleWindows() {
  clearTimeout(windowsTimer);
  windowsTimer = setTimeout(() => {
    windowsTimer = null;
    sendWindowsNow();
  }, WINDOWS_DEBOUNCE_MS);
}

async function snapshotWindows() {
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ['normal', 'popup', 'app'] });
  return windows.map((w) => {
    const tabs = (w.tabs ?? []).map((t) => {
      const url = t.url || t.pendingUrl || '';
      return {
        tabId: t.id,
        title: t.title ?? '',
        url,
        active: !!t.active,
        audible: !!t.audible,
        isMeeting: isMeetingUrl(url),
      };
    });
    return {
      windowId: w.id,
      focused: !!w.focused,
      state: w.state ?? 'normal',
      bounds: { left: w.left ?? 0, top: w.top ?? 0, width: w.width ?? 0, height: w.height ?? 0 },
      activeTabId: tabs.find((t) => t.active)?.tabId ?? null,
      tabs,
    };
  });
}

async function sendWindowsNow() {
  let windows;
  try {
    windows = await snapshotWindows();
  } catch (e) {
    console.warn('PalMeet: windows snapshot failed', e);
    return;
  }
  // Keep each capture's windowId current (tabs can be dragged between windows).
  const st = await state();
  let changed = false;
  for (const c of Object.values(st.captures)) {
    const owner = windows.find((w) => w.tabs.some((t) => t.tabId === c.tabId));
    if (owner && owner.windowId !== c.windowId) {
      c.windowId = owner.windowId;
      changed = true;
    }
  }
  if (changed) await persist();
  send({ type: 'windows', windows });
  refreshBadges();
}

// ---------------------------------------------------------------------------
// Capture flow
// ---------------------------------------------------------------------------

async function handleStartCapture({ sessionId, windowId, tabId }) {
  if (typeof sessionId !== 'string' || !Number.isInteger(tabId)) return;
  const st = await state();

  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    sendCaptureState(sessionId, 'error', { message: 'Tab not found.' });
    return;
  }
  const existing = captureForTab(tabId);
  if (existing) {
    if (existing.sessionId === sessionId) {
      sendCaptureState(sessionId, 'capturing', { windowId: existing.windowId, tabId });
    } else {
      sendCaptureState(sessionId, 'error', { message: 'This tab is already being recorded by another session.' });
    }
    return;
  }
  const targetWindow = tab.windowId ?? windowId;
  const previous = st.pending[targetWindow];
  if (previous && previous.sessionId !== sessionId) {
    sendCaptureState(previous.sessionId, 'stopped', { message: 'Superseded by a newer request for this window.' });
  }
  st.pending[targetWindow] = { sessionId, tabId };
  await persist();
  sendCaptureState(sessionId, 'awaitingGesture');
  refreshBadges();
}

/** Action click or keyboard command in `tab`'s window. */
async function handleGesture(tab) {
  if (!tab || !Number.isInteger(tab.id)) return;
  const st = mem ?? (await state());
  const windowId = tab.windowId;
  const pending = st.pending[windowId];

  const active = captureForTab(tab.id);
  if (!pending && active) {
    await stopCapture(active.sessionId, 'Stopped from the browser', true);
    return;
  }

  if (pending && pending.tabId !== tab.id) {
    // Chrome grants tab capture only for the tab the user invoked the extension on.
    // Bring the requested tab forward and ask for one more click.
    try {
      await chrome.tabs.update(pending.tabId, { active: true });
    } catch {
      delete st.pending[windowId];
      await persist();
      sendCaptureState(pending.sessionId, 'error', { message: 'The requested tab no longer exists.' });
    }
    refreshBadges();
    return;
  }

  if (!authenticated || !bridge) {
    flashError(tab.id, 'PalMeet is not running');
    connect();
    return;
  }

  const sessionId = pending?.sessionId ?? crypto.randomUUID();
  const userInitiated = !pending;
  let streamId;
  try {
    streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
  } catch (error) {
    if (pending) {
      delete st.pending[windowId];
      await persist();
    }
    sendCaptureState(sessionId, 'error', { message: `Tab capture failed: ${error?.message ?? error}` });
    flashError(tab.id, 'Tab capture failed');
    return;
  }

  if (pending) delete st.pending[windowId];
  st.captures[sessionId] = { windowId, tabId: tab.id, userInitiated };
  await persist();

  try {
    await ensureOffscreenDocument();
    const reply = await chrome.runtime.sendMessage({
      target: 'offscreen',
      type: 'start',
      sessionId,
      streamId,
      bridge,
      hello: await helloMessage(bridge.token, 'media'),
    });
    if (!reply?.ok) throw new Error(reply?.error ?? 'Offscreen document did not respond.');
  } catch (error) {
    delete st.captures[sessionId];
    await persist();
    sendCaptureState(sessionId, 'error', { message: `Could not start capture: ${error?.message ?? error}` });
    flashError(tab.id, 'Capture failed');
    await closeOffscreenIfIdle();
    return;
  }

  sendCaptureState(sessionId, 'capturing', { windowId, tabId: tab.id, userInitiated });
  forwardMeetingState(tab.id);
  refreshBadges();
}

async function stopCapture(sessionId, message, notifyApp) {
  const st = await state();
  // A request still waiting for its click?
  for (const [windowId, p] of Object.entries(st.pending)) {
    if (p.sessionId === sessionId) {
      delete st.pending[windowId];
      await persist();
      if (notifyApp) sendCaptureState(sessionId, 'stopped', { message });
      refreshBadges();
      return;
    }
  }
  if (!st.captures[sessionId]) return;
  delete st.captures[sessionId];
  await persist();
  try {
    await chrome.runtime.sendMessage({ target: 'offscreen', type: 'stop', sessionId });
  } catch {
    // Offscreen document already gone.
  }
  if (notifyApp) sendCaptureState(sessionId, 'stopped', { message });
  await closeOffscreenIfIdle();
  refreshBadges();
  await reloadIfIdle();
}

async function stopCapturesForTab(tabId, message) {
  const st = await state();
  for (const [sessionId, c] of Object.entries(st.captures)) {
    if (c.tabId === tabId) await stopCapture(sessionId, message, true);
  }
  for (const p of Object.values(st.pending)) {
    if (p.tabId === tabId) await stopCapture(p.sessionId, message, true);
  }
}

// ---------------------------------------------------------------------------
// Offscreen document (getUserMedia + AudioContext playback + streaming)
// ---------------------------------------------------------------------------

let creatingOffscreen = null;

async function hasOffscreenDocument() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [chrome.runtime.getURL(OFFSCREEN_PATH)],
  });
  return contexts.length > 0;
}

async function ensureOffscreenDocument() {
  if (await hasOffscreenDocument()) return;
  if (!creatingOffscreen) {
    creatingOffscreen = chrome.offscreen
      .createDocument({
        url: OFFSCREEN_PATH,
        reasons: ['USER_MEDIA', 'AUDIO_PLAYBACK'],
        justification: 'Capture the meeting tab audio/video for PalMeet and keep the meeting audible.',
      })
      .finally(() => {
        creatingOffscreen = null;
      });
  }
  await creatingOffscreen;
}

async function closeOffscreenIfIdle() {
  const st = await state();
  if (Object.keys(st.captures).length > 0) return;
  try {
    if (await hasOffscreenDocument()) await chrome.offscreen.closeDocument();
  } catch {
    // Already closed.
  }
}

async function updateOffscreenBridge() {
  const st = await state();
  if (!bridge || Object.keys(st.captures).length === 0) return;
  if (!(await hasOffscreenDocument())) {
    // The offscreen document died (e.g. browser restart) — those captures are gone.
    for (const sessionId of Object.keys(st.captures)) {
      await stopCapture(sessionId, 'Capture was interrupted', true);
    }
    return;
  }
  try {
    const reply = await chrome.runtime.sendMessage({
      target: 'offscreen',
      type: 'bridge',
      bridge,
      hello: await helloMessage(bridge.token, 'media'),
    });
    // Drop captures the offscreen document no longer has.
    const alive = new Set(reply?.sessions ?? []);
    for (const sessionId of Object.keys(st.captures)) {
      if (!alive.has(sessionId)) await stopCapture(sessionId, 'Capture was interrupted', true);
    }
  } catch {
    // Ignore; the next reconnect retries.
  }
}

// ---------------------------------------------------------------------------
// Badge / title
// ---------------------------------------------------------------------------

let pulseTimer = null;
let pulsePhase = false;
let badgeRefreshQueued = false;
const errorFlashUntil = new Map(); // tabId -> timestamp

function flashError(tabId, title) {
  errorFlashUntil.set(tabId, Date.now() + 4000);
  chrome.action.setBadgeText({ tabId, text: '!' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: COLORS.error }).catch(() => {});
  chrome.action.setTitle({ tabId, title: `PalMeet: ${title}` }).catch(() => {});
  setTimeout(refreshBadges, 4100);
}

function refreshBadges() {
  if (badgeRefreshQueued) return;
  badgeRefreshQueued = true;
  queueMicrotask(async () => {
    badgeRefreshQueued = false;
    try {
      await applyBadges();
    } catch (e) {
      console.warn('PalMeet: badge update failed', e);
    }
  });
}

async function applyBadges() {
  const st = await state();
  const globalTitle = authenticated
    ? 'PalMeet: connected — click to record this tab'
    : 'PalMeet: app not running (click to retry)';
  await chrome.action.setBadgeTextColor?.({ color: '#ffffff' });
  await chrome.action.setBadgeText({ text: authenticated ? '' : 'OFF' });
  await chrome.action.setBadgeBackgroundColor({ color: COLORS.idle });
  await chrome.action.setTitle({ title: globalTitle });

  const windows = await chrome.windows.getAll({ populate: true });
  const pendingWindows = new Set(Object.keys(st.pending).map(Number));
  for (const w of windows) {
    const pending = st.pending[w.id];
    for (const t of w.tabs ?? []) {
      if ((errorFlashUntil.get(t.id) ?? 0) > Date.now()) continue;
      const capture = captureForTab(t.id);
      let text = null;
      let color = COLORS.idle;
      let title = globalTitle;
      if (capture) {
        text = 'REC';
        color = COLORS.rec;
        title = 'PalMeet: recording this tab — click to stop';
      } else if (pending) {
        text = 'REC?';
        color = pulsePhase ? COLORS.pulseB : COLORS.pulseA;
        title =
          pending.tabId === t.id
            ? 'PalMeet: click to start recording this meeting'
            : 'PalMeet: click to switch to the meeting tab, then click again';
      }
      await chrome.action.setBadgeText({ tabId: t.id, text }); // null → falls back to global
      await chrome.action.setBadgeBackgroundColor({ tabId: t.id, color });
      await chrome.action.setTitle({ tabId: t.id, title });
    }
  }

  if (pendingWindows.size > 0 && !pulseTimer) {
    pulseTimer = setInterval(pulse, 700);
  } else if (pendingWindows.size === 0 && pulseTimer) {
    clearInterval(pulseTimer);
    pulseTimer = null;
  }
}

async function pulse() {
  pulsePhase = !pulsePhase;
  const st = mem;
  if (!st) return;
  for (const windowId of Object.keys(st.pending).map(Number)) {
    try {
      const tabs = await chrome.tabs.query({ windowId });
      for (const t of tabs) {
        if (captureForTab(t.id)) continue;
        await chrome.action.setBadgeBackgroundColor({
          tabId: t.id,
          color: pulsePhase ? COLORS.pulseB : COLORS.pulseA,
        });
      }
    } catch {
      // Window closed between ticks.
    }
  }
}

// ---------------------------------------------------------------------------
// Meeting page state (content script) → app
// ---------------------------------------------------------------------------

function forwardMeetingState(tabId) {
  const s = meetingStateByTab.get(tabId);
  const capture = captureForTab(tabId);
  if (!s || !capture) return;
  send({ type: 'meetingState', sessionId: capture.sessionId, muted: s.muted, presenting: s.presenting });
}

// ---------------------------------------------------------------------------
// Event wiring (must be registered synchronously at top level)
// ---------------------------------------------------------------------------

// Automated end-to-end tests stand in for the user's click through DevTools (Runtime.evaluate inside this
// service worker). Web pages and content scripts cannot reach this context, so this grants nothing new.
globalThis.palmeetTest = { handleGesture };

chrome.action.onClicked.addListener((tab) => {
  handleGesture(tab).catch((e) => console.warn('PalMeet: gesture failed', e));
});

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'start-capture') return;
  const target = tab ?? (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
  handleGesture(target).catch((e) => console.warn('PalMeet: command failed', e));
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.source === 'content' && message.type === 'meetingState' && sender.tab?.id !== undefined) {
    const tabId = sender.tab.id;
    const next = {
      muted: typeof message.muted === 'boolean' ? message.muted : null,
      presenting: typeof message.presenting === 'boolean' ? message.presenting : null,
    };
    const prev = meetingStateByTab.get(tabId);
    meetingStateByTab.set(tabId, next);
    if (!prev || prev.muted !== next.muted || prev.presenting !== next.presenting) {
      state().then(() => forwardMeetingState(tabId));
    }
    return false;
  }
  if (message?.source === 'content' && message.type === 'captureStatus' && sender.tab?.id !== undefined) {
    state().then(() => sendResponse({ capturing: !!captureForTab(sender.tab.id), diagnostics: pageDiagnosticsEnabled }));
    return true;
  }
  if (message?.source === 'content' && (message.type === 'speakerActivity' || message.type === 'pageDiagnostics') && sender.tab?.id !== undefined) {
    const tabId = sender.tab.id;
    state().then(() => {
      const capture = captureForTab(tabId);
      if (!capture) return;
      if (message.type === 'speakerActivity') {
        send({
          type: 'speakerActivity',
          sessionId: capture.sessionId,
          at: Number(message.at) || Date.now(),
          captions: Array.isArray(message.captions) ? message.captions.slice(0, 50) : [],
          speaking: Array.isArray(message.speaking) ? message.speaking.slice(0, 20) : null,
        });
      } else if (pageDiagnosticsEnabled) {
        send({ type: 'pageDiagnostics', sessionId: capture.sessionId, at: Number(message.at) || Date.now(), payload: message.payload ?? {} });
      }
    });
    return false;
  }
  if (message?.source === 'offscreen') {
    if (message.type === 'captureEnded') {
      stopCapture(message.sessionId, message.reason ?? 'Capture ended', true);
    } else if (message.type === 'keepalive') {
      if (!ws) connect();
    }
    return false;
  }
  if (message?.target === 'background') {
    if (message.type === 'reconnect') {
      reconnectNow();
      sendResponse({ ok: true });
    } else if (message.type === 'status') {
      sendResponse({ connected: authenticated, port: bridge?.port ?? null });
    }
    return false;
  }
  return false;
});

function reconnectNow() {
  backoffMs = 1000;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  if (ws) {
    const old = ws;
    ws = null;
    authenticated = false;
    old.close(1000, 'reconnect');
  }
  connect();
}

chrome.storage.onChanged.addListener((changes, area) => {
  // A new label must be re-announced with a fresh hello.
  if (area === 'local' && changes.profileLabel) reconnectNow();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  meetingStateByTab.delete(tabId);
  errorFlashUntil.delete(tabId);
  stopCapturesForTab(tabId, 'Tab closed');
  scheduleWindows();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url && !isMeetingUrl(changeInfo.url)) {
    if (captureForTab(tabId)) stopCapturesForTab(tabId, 'Navigated away from the meeting');
    meetingStateByTab.delete(tabId);
  }
  if ('url' in changeInfo || 'title' in changeInfo || 'audible' in changeInfo || changeInfo.status === 'complete') {
    scheduleWindows();
  }
});

chrome.tabs.onCreated.addListener(scheduleWindows);
chrome.tabs.onActivated.addListener(scheduleWindows);
chrome.tabs.onMoved.addListener(scheduleWindows);
chrome.tabs.onAttached.addListener(scheduleWindows);
chrome.tabs.onDetached.addListener(scheduleWindows);
chrome.tabs.onReplaced.addListener(scheduleWindows);
chrome.windows.onCreated.addListener(scheduleWindows);
chrome.windows.onFocusChanged.addListener(scheduleWindows);
chrome.windows.onBoundsChanged.addListener(scheduleWindows);
chrome.windows.onRemoved.addListener(async (windowId) => {
  const st = await state();
  const pending = st.pending[windowId];
  if (pending) await stopCapture(pending.sessionId, 'Window closed', true);
  scheduleWindows();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== KEEPALIVE_ALARM) return;
  if (!ws) connect();
  else send({ type: 'ping' });
});

chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());

// Wakes the worker periodically so it reconnects when PalMeet starts, and keeps it alive
// while capturing (the open WebSocket and offscreen keepalives also extend its lifetime).
chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.5 });

state().then(() => {
  refreshBadges();
  connect();
});
