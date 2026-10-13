// Meeting URL patterns. Edit this list to add or remove services.
// A tab whose URL matches any pattern is reported with `isMeeting: true`, and a capturing
// tab that navigates to a non-matching URL ends its capture.
// (The content script's static `matches` in manifest.json must cover the same hosts.)

export const MEETING_URL_PATTERNS = [
  // meet.google.com/abc-defg-hij (the meeting code; the landing page is not a meeting)
  { service: 'Google Meet', pattern: /^https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[/?#]|$)/i },
  { service: 'Microsoft Teams', pattern: /^https:\/\/teams\.microsoft\.com\//i },
  { service: 'Microsoft Teams', pattern: /^https:\/\/teams\.live\.com\//i },
  { service: 'Microsoft Teams', pattern: /^https:\/\/teams\.cloud\.microsoft\//i },
  // Zoom web client: <sub>.zoom.us/wc/… and app.zoom.us/wc/…
  { service: 'Zoom', pattern: /^https:\/\/(?:[a-z0-9-]+\.)*zoom\.us\/wc(?:[/?#]|$)/i },
  { service: 'Webex', pattern: /^https:\/\/(?:[a-z0-9-]+\.)*webex\.com\//i },
  { service: 'Whereby', pattern: /^https:\/\/(?:[a-z0-9-]+\.)?whereby\.com\//i },
  { service: 'Slack huddle', pattern: /^https:\/\/app\.slack\.com\/huddle\//i },
];

/** @returns {string|null} the service name when `url` is a meeting URL. */
export function meetingService(url) {
  if (typeof url !== 'string' || url.length === 0) return null;
  for (const { service, pattern } of MEETING_URL_PATTERNS) {
    if (pattern.test(url)) return service;
  }
  return null;
}

export function isMeetingUrl(url) {
  return meetingService(url) !== null;
}
