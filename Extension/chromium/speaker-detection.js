// PalMeet speaker detection (content script, loaded before content-meeting-state.js; also loaded by tests).
// Reads who is talking from the meeting page itself:
//   - live captions, which meeting services label with the speaker's name (most reliable);
//   - "is speaking" indicators on participant tiles (best effort).
// Meeting sites change their markup often and are localized, so every reader is defensive and returns
// empty results rather than guesses. Nothing here leaves the browser except through the PalMeet bridge.
(function (global) {
  'use strict';

  const MAX_NAME_LENGTH = 80;

  const isVisible = (el) => !!el && typeof el.getClientRects === 'function' && el.getClientRects().length > 0;

  const clean = (text) => (text || '').replace(/\s+/g, ' ').trim();

  // Words that start prompts and notices, never a person ("Are you talking? Your mic is off.").
  const NOT_A_NAME = /^(?:are|is|am|you|you're|your|yours|someone|somebody|anyone|anybody|everyone|nobody|no one|who|voc[eê]|algu[eé]m|ningu[eé]m|est[aá]s?|usted|alguien|nadie)(?=$|[\s,.'’])/iu;

  function plausibleName(text) {
    const name = clean(text);
    if (!name || name.length > MAX_NAME_LENGTH) return null;
    // Not a timestamp, number or punctuation-only string.
    if (!/\p{L}/u.test(name)) return null;
    return name;
  }

  /** A name read from a label or tile: also not a question or a notice. */
  function personName(text) {
    const name = plausibleName(text);
    if (!name || /[?!¿¡:]/.test(name) || NOT_A_NAME.test(name)) return null;
    return name;
  }

  /** Elements with their own (direct) visible text, in document order. */
  function textLeaves(root) {
    const leaves = [];
    const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    let last = null;
    while ((node = walker.nextNode())) {
      if (!clean(node.nodeValue)) continue;
      const el = node.parentElement;
      if (!el || el === last) continue;
      if (el.closest('button, [role="button"], [aria-hidden="true"]')) continue;
      last = el;
      leaves.push(el);
    }
    return leaves;
  }

  // ---- captions: Microsoft Teams ------------------------------------------------------------------

  // Teams (web, "new Teams"): each caption is a chat-like message with
  //   [data-tid="author"] (speaker name) and [data-tid="closed-caption-text"] (what they said).
  function teamsCaptions(doc) {
    const entries = [];
    for (const textEl of doc.querySelectorAll('[data-tid="closed-caption-text"]')) {
      let name = null;
      let el = textEl.parentElement;
      for (let depth = 0; el && depth < 8 && !name; depth++, el = el.parentElement) {
        const author = el.querySelector('[data-tid="author"]');
        if (author) name = plausibleName(author.textContent);
      }
      const text = clean(textEl.textContent);
      if (text) entries.push({ key: textEl, name, text });
    }
    return entries;
  }

  // ---- captions: Google Meet ----------------------------------------------------------------------

  const CAPTION_REGION_LABEL = /caption|legenda|subt[ií]tulo|sous-titre|untertitel|sottotitol|ondertitel|napisy|字幕|자막/i;

  function meetCaptionRegions(doc) {
    const regions = [];
    for (const el of doc.querySelectorAll('[role="region"][aria-label]')) {
      if (CAPTION_REGION_LABEL.test(el.getAttribute('aria-label'))) regions.push(el);
    }
    if (regions.length === 0) {
      // Older Meet builds: the captions container's stable jsname.
      for (const el of doc.querySelectorAll('[jsname="dsyhDe"], [jsname="YSxPC"]')) regions.push(el);
    }
    return regions;
  }

  // Meet: each caption block is [avatar img] [name] [text]. Walk up from each avatar to the smallest block that
  // holds a name and some text; the first text is the name, the rest is the caption.
  function meetCaptions(doc) {
    const entries = [];
    for (const region of meetCaptionRegions(doc)) {
      const seen = new Set();
      for (const img of region.querySelectorAll('img')) {
        let block = img.parentElement;
        let leaves = [];
        while (block && block !== region.parentElement) {
          leaves = textLeaves(block);
          if (leaves.length >= 2) break;
          block = block.parentElement;
        }
        if (!block || leaves.length < 2 || seen.has(block)) continue;
        seen.add(block);
        const name = plausibleName(leaves[0].textContent);
        const text = clean(leaves.slice(1).map((l) => l.textContent).join(' '));
        if (name && text) entries.push({ key: block, name, text });
      }
    }
    return entries;
  }

  // ---- captions: Zoom web client ------------------------------------------------------------------

  function zoomCaptions(doc) {
    const entries = [];
    for (const item of doc.querySelectorAll('.live-transcription-subtitle__item, [class*="lt-full-transcript__item"]')) {
      const nameEl = item.querySelector('[class*="display-name"], [class*="__name"]');
      const textEl = item.querySelector('[class*="__text"], [class*="message"]') ?? item;
      const name = nameEl ? plausibleName(nameEl.textContent) : null;
      let text = clean(textEl.textContent);
      if (nameEl && textEl === item) text = clean(text.slice(clean(nameEl.textContent).length));
      if (name && text) entries.push({ key: item, name, text });
    }
    return entries;
  }

  function readCaptions(doc, host) {
    if (host === 'meet.google.com') return meetCaptions(doc);
    if (host.startsWith('teams.')) return teamsCaptions(doc);
    if (host.endsWith('zoom.us')) return zoomCaptions(doc);
    return [];
  }

  // ---- "is speaking" indicators -------------------------------------------------------------------

  // Labels like "Maria Silva, speaking", "Maria Silva is speaking", "Maria está falando".
  const SPEAKING_LABEL = /^(.{1,80}?)[,.\s-]+(?:is\s+)?(?:speaking|talking|est[aá]\s+falando|falando|hablando|est[aá]\s+hablando|parle|spricht)\b/i;
  const NOT_SPEAKING = /\b(?:not|isn't|n[aã]o|no)\s+(?:speaking|talking|falando|hablando)\b/i;

  function speakingFromLabels(doc) {
    const names = new Set();
    for (const el of doc.querySelectorAll('[aria-label], [title]')) {
      const label = clean(el.getAttribute('aria-label') || el.getAttribute('title'));
      // Questions and notices ("Are you talking? Your mic is off.") aren't someone speaking.
      if (!label || label.length > 160 || label.includes('?') || NOT_SPEAKING.test(label)) continue;
      const match = SPEAKING_LABEL.exec(label);
      if (match && isVisible(el)) {
        const name = personName(match[1]);
        if (name) names.add(name);
      }
    }
    return names;
  }

  // ---- Google Meet: the tile of whoever is talking ------------------------------------------------

  // Meet has no "is speaking" label. While someone talks it animates the voice bars on their tile (and the
  // tile's outline) by swapping CSS classes many times a second; when they stop, the bars settle. So:
  //   1. find the participant tiles and the name on each;
  //   2. a tile is speaking while one of its known voice-level classes is on, or while any element in it keeps
  //      flipping classes (so a renamed class in a new Meet build still works).
  const MEET_TILE = '[data-participant-id], [data-requested-participant-id]';
  // Voice-level classes in Meet's current build; "gjg47c" is the bars at rest.
  const MEET_LEVEL_CLASSES = ['Oaajhc', 'HX2H7', 'wEsLMd', 'OgVli'];
  const MEET_LEVEL_SELECTOR = MEET_LEVEL_CLASSES.map((c) => `.${c}:not(.gjg47c)`).join(', ');
  // Buttons on each tile name its person.
  const TILE_LABELS = [
    /^More options for (.+)$/i,
    /^Mute (.+?)['’]s microphone$/i,
    /^(?:Pin|Unpin) (.+?) (?:to|from) (?:your )?main screen$/i,
    /^Remove (.+?) from the (?:call|meeting)$/i,
    /^Mais opções (?:para|de) (.+)$/i,
    /^(?:Desativar|Desligar) o microfone de (.+)$/i,
    /^(?:Fixar|Liberar) (.+?) (?:na|da) (?:sua )?tela principal$/i,
    /^Más opciones (?:para|de) (.+)$/i,
    /^Silenciar (?:el micrófono de|a) (.+)$/i,
  ];
  const TILE_REFRESH_MS = 2000;
  const FLIP_WINDOW_MS = 1200;
  const FLIP_RECENT_MS = 600;
  const FLIP_MINIMUM = 3;
  // More tiles than this flipping at once is a layout change, not people talking.
  const FLIP_MAX_TILES = 3;
  // The bars rest between words; someone stays "speaking" this long after their bars last moved.
  const SPEAKING_HOLD_MS = 700;

  function nameFromTileLabel(label) {
    const text = clean(label);
    for (const pattern of TILE_LABELS) {
      const match = pattern.exec(text);
      if (match) return personName(match[1]);
    }
    return null;
  }

  function tileName(tile) {
    for (const el of tile.querySelectorAll('[aria-label]')) {
      const name = nameFromTileLabel(el.getAttribute('aria-label'));
      if (name) return name;
    }
    const self = tile.querySelector('[data-self-name]');
    if (self) return personName(self.getAttribute('data-self-name'));
    for (const el of tile.querySelectorAll('.notranslate')) {
      const name = personName(el.textContent);
      if (name) return name;
    }
    return null;
  }

  /** Participant tiles and their names: [{tile, name}], one per name. */
  function meetTiles(doc) {
    const found = new Map();
    for (const el of doc.querySelectorAll(MEET_TILE)) {
      // The outermost element of each tile (tiles nest an inner element with the same participant).
      if (el.parentElement?.closest(MEET_TILE)) continue;
      const name = tileName(el);
      if (name && !found.has(name)) found.set(name, el);
    }
    if (found.size === 0) {
      // No participant IDs: each tile is the largest box around a "More options for <name>" button that names
      // nobody else.
      for (const el of doc.querySelectorAll('[aria-label]')) {
        const name = nameFromTileLabel(el.getAttribute('aria-label'));
        if (!name || found.has(name)) continue;
        let tile = el;
        while (tile.parentElement && tile.parentElement !== doc.body && namesIn(tile.parentElement).size <= 1) tile = tile.parentElement;
        if (tile !== el) found.set(name, tile);
      }
    }
    return [...found.entries()].map(([name, tile]) => ({ name, tile }));
  }

  function namesIn(el) {
    const names = new Set();
    for (const labelled of el.querySelectorAll('[aria-label]')) {
      const name = nameFromTileLabel(labelled.getAttribute('aria-label'));
      if (name) names.add(name);
      if (names.size > 1) break;
    }
    return names;
  }

  /** Watches class flips on the page while a Meet tab is recorded and reads which tiles are talking. */
  class MeetSpeakingWatcher {
    constructor(doc, now = () => performance.now()) {
      this.doc = doc;
      this.now = now;
      this.flips = [];
      this.observer = null;
      this.tiles = [];
      this.tilesAt = -Infinity;
      this.lastSpoke = new Map();
    }

    start() {
      if (this.observer || typeof MutationObserver === 'undefined' || !this.doc.body) return;
      this.observer = new MutationObserver((records) => {
        const at = this.now();
        for (const record of records) {
          const el = record.target;
          // Hovering a tile restyles its buttons; that's not talking.
          if (el.nodeType !== 1 || el.closest('button, [role="button"]')) continue;
          this.flips.push({ el, at });
        }
        if (this.flips.length > 4000) this.flips.splice(0, this.flips.length - 2000);
      });
      this.observer.observe(this.doc.body, { subtree: true, attributes: true, attributeFilter: ['class'] });
    }

    stop() {
      this.observer?.disconnect();
      this.observer = null;
      this.flips = [];
    }

    /** Names on the tiles shown as talking now, [] when nobody is, or null when there are no tiles. */
    read() {
      const now = this.now();
      if (now - this.tilesAt > TILE_REFRESH_MS || this.tiles.some((t) => !t.tile.isConnected)) {
        this.tiles = meetTiles(this.doc);
        this.tilesAt = now;
      }
      if (this.tiles.length === 0) return null;
      const cutoff = now - FLIP_WINDOW_MS;
      let first = 0;
      while (first < this.flips.length && this.flips[first].at < cutoff) first++;
      if (first > 0) this.flips.splice(0, first);

      const known = new Set();
      const flipping = new Set();
      for (const { name, tile } of this.tiles) {
        if (tile.querySelector(MEET_LEVEL_SELECTOR)) known.add(name);
        const counts = new Map();
        let recent = false;
        for (const flip of this.flips) {
          if (!tile.contains(flip.el)) continue;
          const count = (counts.get(flip.el) ?? 0) + 1;
          counts.set(flip.el, count);
          if (count >= FLIP_MINIMUM && now - flip.at <= FLIP_RECENT_MS) recent = true;
        }
        if (recent) flipping.add(name);
      }
      for (const name of known) this.lastSpoke.set(name, now);
      if (flipping.size <= FLIP_MAX_TILES) for (const name of flipping) this.lastSpoke.set(name, now);
      const names = [];
      for (const [name, at] of this.lastSpoke) {
        if (now - at <= SPEAKING_HOLD_MS) names.push(name);
        else this.lastSpoke.delete(name);
      }
      return names.sort();
    }
  }

  // Teams: participant tiles carry the person's name; the voice-level outline is drawn while they talk.
  function teamsSpeaking(doc) {
    const names = new Set();
    for (const outline of doc.querySelectorAll('[data-tid="voice-level-stream-outline"]')) {
      const cls = outline.getAttribute('class') || '';
      const active = /speaking|active/i.test(cls) || outline.getAttribute('data-is-speaking') === 'true';
      if (!active) continue;
      const tile = outline.closest('[data-tid*="participant"], [data-cid*="participant"], [role="menuitem"], [aria-label]');
      const label = tile?.getAttribute('aria-label') || tile?.getAttribute('data-tid') || '';
      const name = plausibleName(label.split(',')[0]);
      if (name) names.add(name);
    }
    return names;
  }

  /**
   * Names currently shown as speaking, [] when the page shows nobody talking, or null when this page has no
   * indicator we understand. `meetWatcher` (a MeetSpeakingWatcher) reads Meet's tiles.
   */
  function readSpeaking(doc, host, meetWatcher = null) {
    const names = speakingFromLabels(doc);
    if (host.startsWith('teams.')) for (const n of teamsSpeaking(doc)) names.add(n);
    const tiles = host === 'meet.google.com' && meetWatcher ? meetWatcher.read() : null;
    for (const n of tiles ?? []) names.add(n);
    if (names.size > 0) return [...names].sort();
    return tiles ? [] : null;
  }

  // ---- change tracking ----------------------------------------------------------------------------

  /**
   * Turns repeated caption reads into updates. Captions grow word by word and get rewritten as the service
   * refines them, so each on-screen caption element keeps one ID and is re-sent whenever its text changes.
   */
  class CaptionTracker {
    constructor(prefix) {
      this.prefix = prefix;
      this.counter = 0;
      this.ids = new WeakMap();
      this.lastText = new Map();
    }

    /** @returns the entries that are new or whose text/name changed: [{id, name, text}] */
    update(entries) {
      const changed = [];
      for (const entry of entries) {
        let id = this.ids.get(entry.key);
        if (!id) {
          id = `${this.prefix}-${++this.counter}`;
          this.ids.set(entry.key, id);
        }
        const signature = `${entry.name ?? ''}\u0000${entry.text}`;
        if (this.lastText.get(id) === signature) continue;
        this.lastText.set(id, signature);
        changed.push({ id, name: entry.name ?? null, text: entry.text });
      }
      // Forget old IDs so the map doesn't grow without bound in long meetings.
      if (this.lastText.size > 2000) {
        const keys = [...this.lastText.keys()];
        for (const key of keys.slice(0, keys.length - 1000)) this.lastText.delete(key);
      }
      return changed;
    }
  }

  // ---- diagnostics --------------------------------------------------------------------------------

  /**
   * Counts attribute changes on the page by element signature. Speaking indicators flip an attribute on the
   * speaker's tile every time someone talks, so the summary shows which elements to read. Used only while
   * the tab is being recorded, and the result stays on this Mac (the PalMeet session folder).
   */
  class PageDiagnostics {
    constructor(doc) {
      this.doc = doc;
      this.counts = new Map();
      this.observer = null;
      this.mutations = 0;
    }

    static signature(el, attribute) {
      const tid = el.getAttribute('data-tid');
      const cid = el.getAttribute('data-cid');
      const role = el.getAttribute('role');
      let sig = el.tagName.toLowerCase();
      if (tid) sig += `[data-tid="${tid.slice(0, 60)}"]`;
      else if (cid) sig += `[data-cid="${cid.slice(0, 60)}"]`;
      else if (role) sig += `[role="${role}"]`;
      if (el.hasAttribute('data-participant-id')) sig += '[data-participant-id]';
      return `${sig}@${attribute}`;
    }

    static nearestLabel(el) {
      const labelled = el.closest('[aria-label], [data-tid*="participant"], [data-participant-id]');
      if (!labelled) return null;
      return clean(labelled.getAttribute('aria-label') || labelled.getAttribute('data-tid') || '').slice(0, 80) || null;
    }

    start() {
      if (this.observer || typeof MutationObserver === 'undefined') return;
      this.observer = new MutationObserver((records) => {
        for (const record of records) {
          this.mutations++;
          // Very busy pages: sample, the ranking stays the same.
          if (this.mutations > 20000 && this.mutations % 10 !== 0) continue;
          const el = record.target;
          if (!el || el.nodeType !== 1) continue;
          const sig = PageDiagnostics.signature(el, record.attributeName);
          let item = this.counts.get(sig);
          if (!item) {
            if (this.counts.size > 3000) continue;
            item = { count: 0, values: new Set(), labels: new Set() };
            this.counts.set(sig, item);
          }
          item.count++;
          if (item.values.size < 6) {
            const value = el.getAttribute(record.attributeName);
            if (value !== null) item.values.add(value.slice(0, 120));
          }
          if (item.labels.size < 4) {
            const label = PageDiagnostics.nearestLabel(el);
            if (label) item.labels.add(label);
          }
        }
      });
      this.observer.observe(this.doc.body, { subtree: true, attributes: true });
    }

    stop() {
      this.observer?.disconnect();
      this.observer = null;
    }

    /** Top changing attributes since the last report, plus page structure hints. Resets the counters. */
    report(captionsFound, speaking) {
      const top = [...this.counts.entries()]
        .sort((a, b) => b[1].count - a[1].count)
        .slice(0, 40)
        .map(([sig, item]) => ({ sig, count: item.count, values: [...item.values], labels: [...item.labels] }));
      const dataTids = new Map();
      for (const el of this.doc.querySelectorAll('[data-tid]')) {
        const tid = el.getAttribute('data-tid').slice(0, 60);
        dataTids.set(tid, (dataTids.get(tid) ?? 0) + 1);
        if (dataTids.size > 400) break;
      }
      const regions = [...this.doc.querySelectorAll('[role="region"][aria-label], [aria-live]')]
        .slice(0, 40)
        .map((el) => `${el.tagName.toLowerCase()} ${el.getAttribute('role') ?? ''} ${clean(el.getAttribute('aria-label') ?? '').slice(0, 60)} live=${el.getAttribute('aria-live') ?? ''}`);
      const result = {
        mutations: this.mutations,
        top,
        dataTids: Object.fromEntries([...dataTids.entries()].sort((a, b) => b[1] - a[1])),
        regions,
        captionsFound,
        speaking,
        tiles: { ids: this.doc.querySelectorAll(MEET_TILE).length, names: meetTiles(this.doc).map((t) => t.name) },
      };
      this.counts.clear();
      this.mutations = 0;
      return result;
    }
  }

  global.PalMeetSpeakerDetection = {
    readCaptions, readSpeaking, CaptionTracker, PageDiagnostics, MeetSpeakingWatcher, meetTiles, plausibleName, personName,
  };
})(globalThis);
