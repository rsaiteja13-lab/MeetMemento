'use strict';

const PROVIDERS = Object.freeze([
  { key: 'zoom', name: 'Zoom', process: /^(?:zoom|cpthost|zccimeetinghost)\.exe$/i },
  { key: 'teams', name: 'Microsoft Teams', process: /^(?:ms-teams|teams)\.exe$/i },
  { key: 'webex', name: 'Webex', process: /^(?:webex|ciscowebexstart|atmgr)\.exe$/i },
  { key: 'slack', name: 'Slack Huddle', process: /^slack\.exe$/i },
  { key: 'discord', name: 'Discord', process: /^discord(?:canary|ptb)?\.exe$/i },
  { key: 'skype', name: 'Skype', process: /^skype(?:app)?\.exe$/i },
  { key: 'whatsapp', name: 'WhatsApp', process: /^whatsapp\.exe$/i },
  { key: 'ringcentral', name: 'RingCentral', process: /^ringcentral\.exe$/i },
  { key: 'goto', name: 'GoTo Meeting', process: /^(?:gotomeeting|goto opener)\.exe$/i }
]);

const DEFINITE_MEETING_PATTERNS = [
  /zoom meeting/i,
  /zoom webinar/i,
  /google meet/i,
  /meet\.google\.com/i,
  /^meet\s*[-–—|]/i,
  /teams meeting/i,
  /meeting\s*[|–—-]\s*microsoft teams/i,
  /webex.*(?:meeting|webinar|call|event)/i,
  /(?:meeting|webinar|call|event).*webex/i,
  /slack.*huddle|huddle.*slack/i,
  /jitsi meet|meet\.jit\.si/i,
  /whereby.*(?:meeting|call)|(?:meeting|call).*whereby/i,
  /ringcentral.*(?:meeting|call)|(?:meeting|call).*ringcentral/i,
  /goto\s*meeting|gotomeeting/i
];

const EXCLUDED_PATTERNS = [
  /^zoom$/i,
  /^zoom workplace$/i,
  /^microsoft teams$/i,
  /^webex$/i,
  /^slack$/i,
  /^discord$/i,
  /zoom settings/i,
  /zoom scheduler/i,
  /zoom clips/i,
  /zoom whiteboard/i,
  /sign in.*zoom/i,
  /(?:meeting|webinar) (?:has )?ended/i,
  /you (?:have )?left (?:the )?(?:meeting|webinar)/i,
  /post[- ]meeting/i,
  /meeting feedback/i,
  /meeting recap/i,
  /meeting notes/i,
  /call ended/i,
  /rate your call/i,
  /how was (?:the|your) call/i
];

function provider(key) {
  const match = PROVIDERS.find((item) => item.key === key);
  return match ? { providerKey: match.key, providerName: match.name } : null;
}

function normalizeRunningApps(value) {
  if (value === true) return new Set(['zoom']);
  if (!value) return new Set();
  if (value instanceof Set) return value;
  return new Set(Array.isArray(value) ? value : []);
}

function classifySource(source, runningApps = new Set()) {
  const name = String(source?.name || '').trim();
  const lower = name.toLowerCase();
  const running = normalizeRunningApps(runningApps);
  if (!name || EXCLUDED_PATTERNS.some((pattern) => pattern.test(name))) return null;

  if (/zoom meeting/i.test(name)) return { ...provider('zoom'), score: 150 };
  if (/zoom webinar/i.test(name)) return { ...provider('zoom'), score: 148 };
  if (/google meet|meet\.google\.com/i.test(name) || /^meet\s*[-–—|]/i.test(name)) {
    return { providerKey: 'google-meet', providerName: 'Google Meet', score: 146 };
  }
  if (/teams meeting|meeting\s*[|–—-]\s*microsoft teams|live event\s*[|–—-]\s*microsoft teams/i.test(name)) {
    return { ...provider('teams'), score: 145 };
  }
  if (/webex/i.test(name) && /meeting|webinar|call|event|presenting|screen shar/i.test(name)) {
    return { ...provider('webex'), score: 142 };
  }
  if (/huddle/i.test(name) && (/slack/i.test(name) || running.has('slack'))) {
    return { ...provider('slack'), score: 140 };
  }
  if (/jitsi meet|meet\.jit\.si/i.test(name)) {
    return { providerKey: 'jitsi', providerName: 'Jitsi Meet', score: 138 };
  }
  if (/whereby/i.test(name) && /meeting|call/i.test(name)) {
    return { providerKey: 'whereby', providerName: 'Whereby', score: 136 };
  }
  if (/ringcentral/i.test(name) && /meeting|call/i.test(name)) {
    return { ...provider('ringcentral'), score: 136 };
  }
  if (/goto\s*meeting|gotomeeting/i.test(name)) {
    return { ...provider('goto'), score: 136 };
  }
  if (/\b(?:video call|voice call|conference call|in a call|meeting room|live webinar)\b/i.test(name)) {
    return { providerKey: 'other', providerName: 'Meeting', score: 105 };
  }
  if (/waiting room|in[- ]meeting|screen shar(?:e|ing)/i.test(name) && running.has('zoom')) {
    return { ...provider('zoom'), score: 125 };
  }

  const callSignal = /\b(?:meeting|webinar|video call|voice call|huddle|live event|presenting)\b/i.test(name);
  if (!callSignal) return null;
  const runningProvider = PROVIDERS.find((item) => running.has(item.key));
  if (!runningProvider) return null;
  return { providerKey: runningProvider.key, providerName: runningProvider.name, score: 110 };
}

function scoreSource(source, runningApps = new Set()) {
  return classifySource(source, runningApps)?.score ?? -1;
}

function chooseMeetingSource(sources, runningApps = new Set(), preferredId = null) {
  const candidates = (sources || [])
    .map((source) => ({ source, match: classifySource(source, runningApps) }))
    .filter((candidate) => candidate.match)
    .sort((left, right) => right.match.score - left.match.score
      || left.source.name.localeCompare(right.source.name));

  const preferred = candidates.find((candidate) => candidate.source.id === preferredId);
  const selected = preferred || candidates[0];
  return selected ? { ...selected.source, ...selected.match } : null;
}

function chooseManualSource(sources) {
  const excludedWindowNames = [
    /^MeetMemento$/i,
    /^Program Manager$/i,
    /^Windows Input Experience$/i,
    /^Task Switching$/i,
    /^Settings$/i
  ];
  const selected = (sources || []).find((source) => {
    const name = String(source?.name || '').trim();
    return name && !excludedWindowNames.some((pattern) => pattern.test(name));
  });
  return selected ? {
    ...selected,
    providerKey: 'other',
    providerName: 'Meeting',
    manualFallback: true
  } : null;
}

function cleanMeetingTitle(sourceName, providerName = 'Meeting', date = new Date()) {
  if (providerName instanceof Date) {
    date = providerName;
    providerName = 'Zoom';
  }
  const raw = String(sourceName || '').trim();
  const generic = DEFINITE_MEETING_PATTERNS.some((pattern) => pattern.test(raw))
    && !/\s[-–—|]\s/.test(raw)
    && raw.split(/\s+/).length <= 5;
  const fallback = `${providerName} meeting — ${new Intl.DateTimeFormat('en-US', {
    month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
  }).format(date)}`;
  if (!raw || generic || new RegExp(`^${providerName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i').test(raw)) {
    return fallback;
  }
  const cleaned = raw
    .replace(/\s*[|–—-]\s*(?:Google Meet|Microsoft Teams(?: Meeting)?|Zoom(?: Workplace| Meeting)?|Webex(?: Meeting)?|Slack)\s*$/i, '')
    .trim();
  return cleaned || fallback;
}

function runningMeetingAppsFromTaskList(taskListOutput) {
  const executableNames = String(taskListOutput || '')
    .split(/\r?\n/)
    .map((line) => line.match(/^"([^"]+)"/)?.[1])
    .filter(Boolean);
  return new Set(PROVIDERS
    .filter((item) => executableNames.some((name) => item.process.test(name)))
    .map((item) => item.key));
}

module.exports = {
  DEFINITE_MEETING_PATTERNS,
  EXCLUDED_PATTERNS,
  PROVIDERS,
  chooseManualSource,
  chooseMeetingSource,
  chooseZoomSource: chooseMeetingSource,
  classifySource,
  cleanMeetingTitle,
  runningMeetingAppsFromTaskList,
  scoreSource
};
