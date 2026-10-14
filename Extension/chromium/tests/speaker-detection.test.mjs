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
