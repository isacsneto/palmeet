// Run with: node --test Extension/chromium/tests/*.test.mjs
// DOM readers run in a real browser when PALMEET_CHROME points at Chrome for Testing:
//   PALMEET_CHROME="…/Google Chrome for Testing" node --test Extension/chromium/tests/*.test.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../speaker-detection.js', import.meta.url), 'utf8');
const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url)));

/** Values from the vm context have that context's prototypes; compare plain copies. */
const plain = (value) => JSON.parse(JSON.stringify(value));

function load() {
  const context = { globalThis: {} };
  context.globalThis = context;
  vm.runInNewContext(source, context);
  return context.PalMeetSpeakerDetection;
}

test('speaker detection loads before the content script that uses it', () => {
  const js = manifest.content_scripts[0].js;
  assert.deepEqual(js, ['speaker-detection.js', 'content-meeting-state.js']);
  assert.ok(load().readCaptions);
});

test('caption tracker sends new and changed captions once', () => {
  const { CaptionTracker } = load();
  const tracker = new CaptionTracker('t');
  const a = {}, b = {};
  assert.deepEqual(plain(tracker.update([{ key: a, name: 'Ana', text: 'Good' }])), [{ id: 't-1', name: 'Ana', text: 'Good' }]);
  assert.deepEqual(plain(tracker.update([{ key: a, name: 'Ana', text: 'Good' }])), [], 'unchanged → nothing');
  assert.deepEqual(
    plain(tracker.update([{ key: a, name: 'Ana', text: 'Good morning' }, { key: b, name: null, text: 'Hi' }])),
    [{ id: 't-1', name: 'Ana', text: 'Good morning' }, { id: 't-2', name: null, text: 'Hi' }],
  );
  // The name arriving later (Teams renders the author after the text) re-sends the caption.
  assert.deepEqual(plain(tracker.update([{ key: b, name: 'Bo', text: 'Hi' }])), [{ id: 't-2', name: 'Bo', text: 'Hi' }]);
});

test('names must look like names', () => {
  const { plausibleName } = load();
  assert.equal(plausibleName('  Maria   Silva '), 'Maria Silva');
  assert.equal(plausibleName('10:42'), null);
  assert.equal(plausibleName(''), null);
  assert.equal(plausibleName('x'.repeat(81)), null);
});

test('prompts and notices are not people', () => {
  const { personName } = load();
  assert.equal(personName('Ryan Jackson'), 'Ryan Jackson');
  assert.equal(personName('Are you'), null);
  assert.equal(personName('Are you talking? Your mic is off.'), null);
  assert.equal(personName('You'), null);
  assert.equal(personName('Você'), null);
  assert.equal(personName('Someone'), null);
  assert.equal(personName('Isabel Ramos'), 'Isabel Ramos', 'names that start like a stop word are fine');
});

// ---- real DOM in Chrome for Testing ---------------------------------------------------------------

const chrome = process.env.PALMEET_CHROME;

const fixtures = {
  teams: `
    <div data-tid="closed-caption-v2-window-wrapper">
      <div class="fui-ChatMessageCompact"><div class="body">
        <span data-tid="author">Alice Smith</span>
        <span data-tid="closed-caption-text">Good morning everyone.</span></div></div>
      <div class="fui-ChatMessageCompact"><div class="body">
        <span data-tid="author">Bob Jones (Guest)</span>
        <span data-tid="closed-caption-text">Morning! Quick update   from me.</span></div></div>
    </div>
    <div data-tid="video-tile" aria-label="Bob Jones (Guest), speaking"><div data-tid="voice-level-stream-outline" class="outline speaking"></div></div>
    <div aria-label="Carol White, not speaking"></div>
    <button aria-label="Dave Brown is speaking">x</button>`,
  meet: `
    <div role="region" aria-label="Captions" tabindex="0">
      <div class="nMcdL"><div class="adE6rb"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><div class="KcIKyf"><span class="NWpY1d">Alice Smith</span></div></div>
        <div class="ygicle">so the plan is to ship on Friday</div></div>
      <div class="nMcdL"><div class="adE6rb"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><div class="KcIKyf"><span class="NWpY1d">Você</span></div></div>
        <div class="ygicle">sounds good</div></div>
    </div>`,
  meetPortuguese: `
    <div role="region" aria-label="Legendas">
      <div><div><img alt=""><div><span>João Pedro</span></div></div><div><span>bom dia pessoal</span></div></div>
    </div>`,
  nothing: `<div><p>Waiting for others to join…</p><button aria-label="Mute">m</button></div>`,
  // Meet: participant tiles with voice bars, plus the "are you talking?" notice when your mic is off.
  meetTiles: `
    <div data-participant-id="spaces/a/devices/1"><div data-requested-participant-id="spaces/a/devices/1">
      <div class="IisKdb GF8M7d gjg47c YFyDbd" id="bars-ryan"></div>
      <span class="notranslate">Ryan Jackson</span>
      <button aria-label="More options for Ryan Jackson">⋮</button>
      <button aria-label="Mute Ryan Jackson's microphone">m</button></div></div>
    <div data-participant-id="spaces/a/devices/2">
      <div class="xyz" id="bars-yegor"></div>
      <span class="notranslate">Yegor Kluban</span>
      <button aria-label="More options for Yegor Kluban">⋮</button></div>
    <div data-participant-id="spaces/a/devices/3">
      <div class="DYfzY cYKTje gjg47c sxlEM"></div>
      <button aria-label="Pin Danilo Cavalcanti to your main screen">p</button></div>
    <div role="dialog"><div aria-label="Are you talking? Your mic is off.">Are you talking? Your mic is off.</div></div>`,
  // Meet without participant IDs: tiles are found from their buttons.
  meetNoIDs: `
    <div class="grid">
      <div class="tile"><div class="inner"><div class="bars Oaajhc"></div><button aria-label="More options for Ana Lima">⋮</button></div></div>
      <div class="tile"><div class="inner"><div class="bars gjg47c"></div><button aria-label="More options for Bruno Dias">⋮</button></div></div>
    </div>`,
};

async function cdpSession(port) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = list.find((t) => t.type === 'page');
      if (page) {
        const ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
        let next = 1;
        const pending = new Map();
        ws.onmessage = (event) => {
          const message = JSON.parse(event.data);
          pending.get(message.id)?.(message);
          pending.delete(message.id);
        };
        const call = (method, params = {}) => new Promise((resolve) => {
          const id = next++;
          pending.set(id, resolve);
          ws.send(JSON.stringify({ id, method, params }));
        });
        return { call, close: () => ws.close() };
      }
    } catch {
      // Not up yet.
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('Chrome did not start');
}

test('reads captions and speaking indicators from meeting pages', { skip: !chrome && 'set PALMEET_CHROME' }, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'palmeet-dom-'));
  const port = 9300 + Math.floor(Math.random() * 500);
  writeFileSync(join(dir, 'page.html'), '<!doctype html><body></body>');
  const browser = spawn(chrome, [
    '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${join(dir, 'profile')}`,
    '--no-first-run', `file://${join(dir, 'page.html')}`,
  ], { stdio: 'ignore' });
  try {
    const cdp = await cdpSession(port);
    await cdp.call('Runtime.evaluate', { expression: source });
    const run = async (html, host) => {
      const expression = `(() => {
        document.body.innerHTML = ${JSON.stringify(html)};
        const d = globalThis.PalMeetSpeakerDetection;
        return JSON.stringify({
          captions: d.readCaptions(document, ${JSON.stringify(host)}).map((c) => ({ name: c.name, text: c.text })),
          speaking: d.readSpeaking(document, ${JSON.stringify(host)}),
        });
      })()`;
      const reply = await cdp.call('Runtime.evaluate', { expression, returnByValue: true });
      assert.ok(!reply.result.exceptionDetails, JSON.stringify(reply.result.exceptionDetails));
      return JSON.parse(reply.result.result.value);
    };

    const teams = await run(fixtures.teams, 'teams.microsoft.com');
    assert.deepEqual(teams.captions, [
      { name: 'Alice Smith', text: 'Good morning everyone.' },
      { name: 'Bob Jones (Guest)', text: 'Morning! Quick update from me.' },
    ]);
    assert.deepEqual(teams.speaking, ['Bob Jones (Guest)', 'Dave Brown']);

    const meet = await run(fixtures.meet, 'meet.google.com');
    assert.deepEqual(meet.captions, [
      { name: 'Alice Smith', text: 'so the plan is to ship on Friday' },
      { name: 'Você', text: 'sounds good' },
    ]);
    const portuguese = await run(fixtures.meetPortuguese, 'meet.google.com');
    assert.deepEqual(portuguese.captions, [{ name: 'João Pedro', text: 'bom dia pessoal' }]);

    // Meet tiles: nobody talking, then the known voice-bar class, then an unknown class that keeps flipping.
    const tiles = await cdp.call('Runtime.evaluate', {
      awaitPromise: true,
      returnByValue: true,
      expression: `(async () => {
        const d = globalThis.PalMeetSpeakerDetection;
        const pause = (ms) => new Promise((r) => setTimeout(r, ms));
        document.body.innerHTML = ${JSON.stringify(fixtures.meetTiles)};
        const watcher = new d.MeetSpeakingWatcher(document);
        watcher.start();
        const read = () => d.readSpeaking(document, 'meet.google.com', watcher);
        const out = { names: d.meetTiles(document).map((t) => t.name), quiet: read() };
        document.getElementById('bars-ryan').className = 'IisKdb GF8M7d wEsLMd YFyDbd';
        out.ryan = read();
        document.getElementById('bars-ryan').className = 'IisKdb GF8M7d gjg47c YFyDbd';
        for (let i = 0; i < 5; i++) { document.getElementById('bars-yegor').className = i % 2 ? 'xyz a' : 'xyz b'; await pause(20); }
        out.yegor = read();
        await pause(1300);
        out.settled = read();
        out.withoutWatcher = d.readSpeaking(document, 'meet.google.com');
        watcher.stop();
        document.body.innerHTML = ${JSON.stringify(fixtures.meetNoIDs)};
        const plain = new d.MeetSpeakingWatcher(document);
        out.noIDs = { names: d.meetTiles(document).map((t) => t.name), speaking: plain.read() };
        return JSON.stringify(out);
      })()`,
    });
    assert.ok(!tiles.result.exceptionDetails, JSON.stringify(tiles.result.exceptionDetails));
    assert.deepEqual(JSON.parse(tiles.result.result.value), {
      names: ['Ryan Jackson', 'Yegor Kluban', 'Danilo Cavalcanti'],
      quiet: [],
      ryan: ['Ryan Jackson'],
      yegor: ['Ryan Jackson', 'Yegor Kluban'], // Ryan's highlight lingers a moment after his bars rest
      settled: [],
      withoutWatcher: null,
      noIDs: { names: ['Ana Lima', 'Bruno Dias'], speaking: ['Ana Lima'] },
    });

    const empty = await run(fixtures.nothing, 'teams.microsoft.com');
    assert.deepEqual(empty, { captions: [], speaking: null });
    // Teams markup on another site isn't read as Teams.
    assert.deepEqual((await run(fixtures.teams, 'whereby.com')).captions, []);

    // Diagnostics: attribute flips on a tile are counted with the tile's label.
    const diag = await cdp.call('Runtime.evaluate', {
      awaitPromise: true,
      returnByValue: true,
      expression: `(async () => {
        document.body.innerHTML = ${JSON.stringify(fixtures.teams)};
        const d = new globalThis.PalMeetSpeakerDetection.PageDiagnostics(document);
        d.start();
        const outline = document.querySelector('[data-tid="voice-level-stream-outline"]');
        for (let i = 0; i < 6; i++) { outline.className = i % 2 ? 'outline speaking' : 'outline'; await new Promise((r) => setTimeout(r, 5)); }
        const report = d.report(2, ['Bob Jones (Guest)']);
        d.stop();
        return JSON.stringify(report);
      })()`,
    });
    const report = JSON.parse(diag.result.result.value);
    const top = report.top.find((t) => t.sig === 'div[data-tid="voice-level-stream-outline"]@class');
    assert.ok(top, JSON.stringify(report.top));
    assert.equal(top.count, 6);
    assert.ok(top.values.includes('outline speaking'));
    assert.ok(top.labels.some((l) => l.includes('Bob Jones')));
    assert.equal(report.dataTids['closed-caption-text'], 2);
    cdp.close();
  } finally {
    const exited = new Promise((resolve) => browser.once('exit', resolve));
    browser.kill();
    await exited;
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
});
