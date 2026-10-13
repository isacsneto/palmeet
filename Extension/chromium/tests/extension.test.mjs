// Run with: node --test Extension/chromium/tests
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { isMeetingUrl, meetingService } from '../meeting-patterns.js';

const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url)));

test('recognizes meeting URLs', () => {
  const meetings = {
    'https://meet.google.com/abc-defg-hij': 'Google Meet',
    'https://meet.google.com/abc-defg-hij?authuser=1': 'Google Meet',
    'https://teams.microsoft.com/v2/?meetingjoin=true': 'Microsoft Teams',
    'https://teams.live.com/meet/123': 'Microsoft Teams',
    'https://teams.cloud.microsoft/': 'Microsoft Teams',
    'https://us05web.zoom.us/wc/123456/join': 'Zoom',
    'https://app.zoom.us/wc/home': 'Zoom',
    'https://acme.webex.com/meet/jane': 'Webex',
    'https://whereby.com/standup': 'Whereby',
    'https://app.slack.com/huddle/T1/C2': 'Slack huddle',
  };
  for (const [url, service] of Object.entries(meetings)) {
    assert.equal(meetingService(url), service, url);
  }
});

test('ignores non-meeting pages and lookalikes', () => {
  for (const url of [
    'https://meet.google.com/',
    'https://meet.google.com/landing',
    'https://meet.google.com.evil.com/abc-defg-hij',
    'https://zoom.us/j/123456',
    'https://evilzoom.us/wc/1',
    'https://example.com/?next=https://teams.microsoft.com/',
    'http://meet.google.com/abc-defg-hij',
    '', null, undefined, 42,
  ]) {
    assert.equal(isMeetingUrl(url), false, String(url));
  }
});

test('manifest declares what the capture flow needs', () => {
  assert.equal(manifest.manifest_version, 3);
  for (const permission of ['tabCapture', 'offscreen', 'tabs', 'storage', 'nativeMessaging']) {
    assert.ok(manifest.permissions.includes(permission), permission);
  }
  assert.equal(manifest.background.type, 'module');
  assert.ok(manifest.commands?.['start-capture'], 'keyboard shortcut for the capture gesture');
});

test('content script covers every meeting host', () => {
  const matches = manifest.content_scripts.flatMap((c) => c.matches);
  for (const host of ['meet.google.com', 'teams.microsoft.com', 'teams.live.com', 'teams.cloud.microsoft', 'zoom.us', 'webex.com', 'whereby.com', 'app.slack.com']) {
    assert.ok(matches.some((m) => m.includes(host)), host);
  }
});

test('manifest key yields the extension ID the app trusts', () => {
  const der = Buffer.from(manifest.key, 'base64');
  const hex = createHash('sha256').update(der).digest('hex').slice(0, 32);
  const id = [...hex].map((c) => String.fromCharCode('a'.charCodeAt(0) + parseInt(c, 16))).join('');
  assert.equal(id, 'lhchlhlaljhfimjelkfbcmgocleehfin');
});
