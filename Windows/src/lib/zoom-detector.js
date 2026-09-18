'use strict';

const DEFINITE_MEETING_PATTERNS = [
  /zoom meeting/i,
  /zoom webinar/i,
  /waiting room/i,
  /in[- ]meeting/i,
  /screen shar(?:e|ing)/i,
  /^meeting(?:\s|$)/i
];

const EXCLUDED_PATTERNS = [
  /^zoom$/i,
  /^zoom workplace$/i,
  /zoom settings/i,
  /zoom scheduler/i,
  /zoom clips/i,
  /zoom whiteboard/i,
  /sign in.*zoom/i
];

function scoreSource(source, zoomProcessRunning = true) {
  const name = String(source?.name || '').trim();
  if (!name || EXCLUDED_PATTERNS.some((pattern) => pattern.test(name))) return -1;
  if (/zoom meeting/i.test(name)) return 120;
  if (/zoom webinar/i.test(name)) return 115;
  if (/waiting room/i.test(name)) return 105;
  if (/in[- ]meeting/i.test(name)) return 100;
  if (/screen shar(?:e|ing)/i.test(name) && /zoom/i.test(name)) return 95;
  if (/^meeting(?:\s|$)/i.test(name) && zoomProcessRunning) return 80;
  if (/zoom/i.test(name) && zoomProcessRunning) return 55;
  return -1;
}

function chooseZoomSource(sources, zoomProcessRunning = true, preferredId = null) {
  const candidates = (sources || [])
    .map((source) => ({ source, score: scoreSource(source, zoomProcessRunning) }))
    .filter((candidate) => candidate.score >= 0)
    .sort((left, right) => right.score - left.score || left.source.name.localeCompare(right.source.name));

  const preferred = candidates.find((candidate) => candidate.source.id === preferredId);
  return (preferred || candidates[0])?.source || null;
}

function cleanMeetingTitle(sourceName, date = new Date()) {
  const raw = String(sourceName || '').trim();
  const generic = DEFINITE_MEETING_PATTERNS.some((pattern) => pattern.test(raw))
    && !raw.includes(' - ')
    && raw.split(/\s+/).length <= 4;
  if (!raw || generic || /^zoom/i.test(raw)) {
    const stamp = new Intl.DateTimeFormat('en-US', {
      month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
    }).format(date);
    return `Zoom meeting — ${stamp}`;
  }
  return raw
    .replace(/\s*[|–—-]\s*Zoom(?: Workplace| Meeting)?\s*$/i, '')
    .trim() || `Zoom meeting — ${date.toLocaleString()}`;
}

module.exports = {
  DEFINITE_MEETING_PATTERNS,
  EXCLUDED_PATTERNS,
  chooseZoomSource,
  cleanMeetingTitle,
  scoreSource
};
