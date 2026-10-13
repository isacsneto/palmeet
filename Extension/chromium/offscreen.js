// PalMeet offscreen document: turns a tabCapture stream id into a MediaStream, keeps the
// meeting audible, and streams PCM audio + 1 fps JPEG frames to PalMeet over a dedicated
// "media" WebSocket (binary frames, see PROTOCOL.md).

const KIND_AUDIO = 1;
const KIND_VIDEO = 2;
const HEADER_BYTES = 32;
const VIDEO_INTERVAL_MS = 1000;
const MAX_VIDEO_WIDTH = 1280;
const JPEG_QUALITY = 0.7;
const MAX_QUEUED_FRAMES = 100; // ~10 s of audio while the media socket (re)connects
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024;

/** sessionId -> { stream, ctx, source, worklet, videoTimer, grabber } */
const captures = new Map();

const media = { socket: null, ready: false, bridge: null, hello: null, queue: [], retryTimer: null };

// ---------------------------------------------------------------------------
// Messages from the service worker
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target !== 'offscreen') return false;
  handle(message).then(sendResponse, (error) => sendResponse({ ok: false, error: String(error?.message ?? error) }));
  return true; // async response
});

async function handle(message) {
  switch (message.type) {
    case 'start':
      setBridge(message.bridge, message.hello);
      await startCapture(message.sessionId, message.streamId);
      return { ok: true };
    case 'stop':
      await stopCapture(message.sessionId);
      return { ok: true };
    case 'bridge':
      setBridge(message.bridge, message.hello);
      return { ok: true, sessions: [...captures.keys()] };
    default:
      return { ok: false, error: `Unknown command ${message.type}` };
  }
}

// Keep the service worker awake while we capture.
setInterval(() => {
  if (captures.size > 0) chrome.runtime.sendMessage({ source: 'offscreen', type: 'keepalive' }).catch(() => {});
}, 20_000);

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

async function startCapture(sessionId, streamId) {
  if (captures.has(sessionId)) return;
  const constraints = (extra = {}) => ({
    mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId, ...extra },
  });
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: constraints(),
    video: constraints({ maxWidth: MAX_VIDEO_WIDTH, maxHeight: 2000, maxFrameRate: 5 }),
  });

  const capture = { stream, ctx: null, source: null, worklet: null, videoTimer: null, grabber: null };
  captures.set(sessionId, capture);
  try {
    await startAudio(sessionId, capture);
    startVideo(sessionId, capture);
  } catch (error) {
    await stopCapture(sessionId);
    throw error;
  }

  for (const track of stream.getTracks()) {
    track.addEventListener('ended', () => {
      if (!captures.has(sessionId)) return;
      stopCapture(sessionId).finally(() => {
        chrome.runtime
          .sendMessage({ source: 'offscreen', type: 'captureEnded', sessionId, reason: 'Tab capture ended' })
          .catch(() => {});
      });
    });
  }
  ensureMediaSocket();
}

async function startAudio(sessionId, capture) {
  const audioTracks = capture.stream.getAudioTracks();
  if (audioTracks.length === 0) throw new Error('The tab stream has no audio track.');

  const ctx = new AudioContext({ latencyHint: 'interactive' });
  capture.ctx = ctx;
  await ctx.audioWorklet.addModule('pcm-worklet.js');
  const source = ctx.createMediaStreamSource(new MediaStream(audioTracks));
  capture.source = source;

  // Tab capture mutes the tab locally — play it back so the user still hears the meeting.
  source.connect(ctx.destination);

  const sampleRate = Math.round(ctx.sampleRate);
  const worklet = new AudioWorkletNode(ctx, 'pcm-capture', {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [1],
    processorOptions: { channels: 2, chunkFrames: Math.round(sampleRate / 10) },
  });
  capture.worklet = worklet;
  source.connect(worklet);
  worklet.connect(ctx.destination); // outputs silence; keeps the node pulled by the graph

  worklet.port.onmessage = (event) => {
    const { pcm, channels, startTime } = event.data;
    sendFrame(KIND_AUDIO, channels, sampleRate, sessionId, contextTimeToEpochMs(ctx, startTime), pcm);
  };
  if (ctx.state === 'suspended') await ctx.resume();
}

/** Maps AudioContext time to Unix epoch ms. */
function contextTimeToEpochMs(ctx, contextTime) {
  const ts = ctx.getOutputTimestamp?.();
  if (ts && ts.performanceTime > 0 && typeof contextTime === 'number') {
    return performance.timeOrigin + ts.performanceTime + (contextTime - ts.contextTime) * 1000;
  }
  return Date.now();
}

function startVideo(sessionId, capture) {
  const track = capture.stream.getVideoTracks()[0];
  if (!track) return;
  capture.grabber = makeFrameGrabber(track);
  let busy = false;
  capture.videoTimer = setInterval(async () => {
    if (busy || !captures.has(sessionId)) return;
    busy = true;
    try {
      const captureTime = Date.now();
      const jpeg = await capture.grabber.grabJpeg();
      if (jpeg) sendFrame(KIND_VIDEO, 0, 0, sessionId, captureTime, jpeg);
    } catch {
      // Frame not available yet (tab not painted, etc.) — try again next tick.
    } finally {
      busy = false;
    }
  }, VIDEO_INTERVAL_MS);
}

function makeFrameGrabber(track) {
  const canvasFor = (width, height) => {
    const w = Math.min(MAX_VIDEO_WIDTH, width);
    const h = Math.max(1, Math.round((height * w) / width));
    return { canvas: new OffscreenCanvas(w, h), w, h };
  };
  const encode = async (drawable, width, height) => {
    if (!width || !height) return null;
    const { canvas, w, h } = canvasFor(width, height);
    canvas.getContext('2d').drawImage(drawable, 0, 0, w, h);
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: JPEG_QUALITY });
    return blob.arrayBuffer();
  };

  if (typeof ImageCapture === 'function') {
    const imageCapture = new ImageCapture(track);
    return {
      async grabJpeg() {
        const bitmap = await imageCapture.grabFrame();
        try {
          return await encode(bitmap, bitmap.width, bitmap.height);
        } finally {
          bitmap.close();
        }
      },
      dispose() {},
    };
  }
  // Fallback: draw from a <video> element.
  const video = document.createElement('video');
  video.muted = true;
  video.srcObject = new MediaStream([track]);
  video.play().catch(() => {});
  return {
    async grabJpeg() {
      return encode(video, video.videoWidth, video.videoHeight);
    },
    dispose() {
      video.srcObject = null;
    },
  };
}

async function stopCapture(sessionId) {
  const capture = captures.get(sessionId);
  if (!capture) return;
  captures.delete(sessionId);
  clearInterval(capture.videoTimer);
  capture.grabber?.dispose();
  try {
    capture.worklet?.port.postMessage('flush');
    capture.worklet?.disconnect();
    capture.source?.disconnect();
  } catch {
    // Already disconnected.
  }
  capture.stream.getTracks().forEach((t) => t.stop());
  await capture.ctx?.close().catch(() => {});
  if (captures.size === 0) closeMediaSocket();
}

// ---------------------------------------------------------------------------
// Media WebSocket (binary frames)
// ---------------------------------------------------------------------------

function setBridge(bridge, hello) {
  if (!bridge?.port || !bridge?.token) return;
  const changed = !media.bridge || media.bridge.port !== bridge.port || media.bridge.token !== bridge.token;
  media.bridge = bridge;
  media.hello = hello;
  if (changed && media.socket) {
    const old = media.socket;
    media.socket = null;
    media.ready = false;
    old.close(1000, 'bridge changed');
  }
  if (captures.size > 0) ensureMediaSocket();
}

function ensureMediaSocket() {
  if (!media.bridge || captures.size === 0) return;
  if (media.socket && media.socket.readyState <= WebSocket.OPEN) return;
  clearTimeout(media.retryTimer);
  const socket = new WebSocket(`ws://127.0.0.1:${media.bridge.port}/`);
  socket.binaryType = 'arraybuffer';
  media.socket = socket;
  media.ready = false;
  socket.onopen = () => {
    socket.send(JSON.stringify({ ...media.hello, type: 'hello', token: media.bridge.token, role: 'media' }));
  };
  socket.onmessage = (event) => {
    if (typeof event.data !== 'string') return;
    try {
      if (JSON.parse(event.data)?.type === 'welcome' && socket === media.socket) {
        media.ready = true;
        const queued = media.queue;
        media.queue = [];
        queued.forEach((frame) => socket.send(frame));
      }
    } catch {
      // Ignore malformed text.
    }
  };
  socket.onclose = () => {
    if (socket !== media.socket) return;
    media.socket = null;
    media.ready = false;
    if (captures.size > 0) media.retryTimer = setTimeout(ensureMediaSocket, 1000);
  };
  socket.onerror = () => {};
}

function closeMediaSocket() {
  clearTimeout(media.retryTimer);
  const socket = media.socket;
  media.socket = null;
  media.ready = false;
  media.queue = [];
  // Give the last flushed audio chunk a moment to go out.
  if (socket) setTimeout(() => socket.close(1000, 'idle'), 250);
}

function sendFrame(kind, channels, sampleRate, sessionId, captureTimeMs, payload) {
  const frame = buildFrame(kind, channels, sampleRate, sessionId, captureTimeMs, payload);
  const socket = media.socket;
  if (media.ready && socket?.readyState === WebSocket.OPEN) {
    if (socket.bufferedAmount < MAX_BUFFERED_BYTES) socket.send(frame);
    return;
  }
  media.queue.push(frame);
  if (media.queue.length > MAX_QUEUED_FRAMES) media.queue.shift();
  ensureMediaSocket();
}

/** 32-byte little-endian header + payload. */
function buildFrame(kind, channels, sampleRate, sessionId, captureTimeMs, payload) {
  const body = new Uint8Array(payload);
  const out = new Uint8Array(HEADER_BYTES + body.byteLength);
  const view = new DataView(out.buffer);
  view.setUint8(0, kind);
  view.setUint8(1, 0);
  view.setUint16(2, channels, true);
  view.setUint32(4, sampleRate, true);
  const hex = sessionId.replace(/-/g, '');
  for (let i = 0; i < 16; i++) view.setUint8(8 + i, parseInt(hex.substr(i * 2, 2), 16) || 0);
  view.setFloat64(24, captureTimeMs, true);
  out.set(body, HEADER_BYTES);
  return out.buffer;
}
