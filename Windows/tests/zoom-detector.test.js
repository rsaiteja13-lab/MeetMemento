'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  chooseManualSource,
  chooseMeetingSource,
  chooseZoomSource,
  cleanMeetingTitle,
  runningMeetingAppsFromTaskList,
  scoreSource
} = require('../src/lib/zoom-detector');

test('chooses the meeting window instead of the Zoom home window', () => {
  const sources = [
    { id: 'home', name: 'Zoom Workplace' },
    { id: 'meeting', name: 'Weekly planning - Zoom Meeting' },
    { id: 'other', name: 'Notes' }
  ];
  assert.equal(chooseZoomSource(sources, true).id, 'meeting');
});

test('keeps a currently captured Zoom source when it remains available', () => {
  const sources = [
    { id: 'first', name: 'Zoom Meeting' },
    { id: 'current', name: 'Screen Sharing - Zoom Meeting' }
  ];
  assert.equal(chooseZoomSource(sources, true, 'current').id, 'current');
});

test('does not treat unrelated windows as meetings', () => {
  assert.equal(scoreSource({ name: 'Project notes' }, true), -1);
  assert.equal(chooseZoomSource([{ id: 'home', name: 'Zoom Workplace' }], true), null);
  assert.equal(chooseZoomSource([{ id: 'ended', name: 'Zoom Webinar has ended' }], true), null);
  assert.equal(chooseZoomSource([{ id: 'feedback', name: 'Post-meeting feedback - Zoom' }], true), null);
});

test('uses descriptive Zoom window text as the meeting name', () => {
  assert.equal(cleanMeetingTitle('Customer review - Zoom Meeting'), 'Customer review');
  assert.match(cleanMeetingTitle('Zoom Meeting', new Date('2026-09-18T10:00:00Z')), /^Zoom meeting — /);
});

test('detects browser and native meeting providers without treating home windows as calls', () => {
  const running = new Set(['teams', 'webex']);
  const sources = [
    { id: 'teams-home', name: 'Microsoft Teams' },
    { id: 'notes', name: 'Meeting notes - Google Docs' },
    { id: 'meet', name: 'Product review - Google Meet' },
    { id: 'teams-call', name: 'Weekly planning | Microsoft Teams meeting' },
    { id: 'webex-call', name: 'Customer call - Webex Meeting' }
  ];
  const selected = chooseMeetingSource(sources, running);
  assert.equal(selected.id, 'meet');
  assert.equal(selected.providerName, 'Google Meet');
  assert.equal(scoreSource(sources[1], running), -1);
  assert.equal(scoreSource(sources[3], running) > 0, true);
  assert.equal(scoreSource(sources[4], running) > 0, true);
  assert.equal(
    chooseMeetingSource([{ id: 'generic', name: 'Video call with Priya' }], new Set()).providerName,
    'Meeting'
  );
});

test('detects Slack huddles and common meeting processes', () => {
  const running = runningMeetingAppsFromTaskList([
    '"ms-teams.exe","123","Console","1","100,000 K"',
    '"Slack.exe","456","Console","1","120,000 K"'
  ].join('\r\n'));
  assert.deepEqual([...running].sort(), ['slack', 'teams']);
  const selected = chooseMeetingSource(
    [{ id: 'huddle', name: 'Design sync — Huddle' }],
    running
  );
  assert.equal(selected.providerName, 'Slack Huddle');
});

test('cleans provider suffixes from non-Zoom meeting titles', () => {
  assert.equal(cleanMeetingTitle('Product review - Google Meet', 'Google Meet'), 'Product review');
  assert.equal(cleanMeetingTitle('Weekly planning | Microsoft Teams', 'Microsoft Teams'), 'Weekly planning');
});

test('manual recording can capture an unfamiliar meeting app without capturing MeetMemento', () => {
  const selected = chooseManualSource([
    { id: 'self', name: 'MeetMemento' },
    { id: 'unknown', name: 'Acme Calls - Room 42' },
    { id: 'notes', name: 'Project notes' }
  ]);
  assert.equal(selected.id, 'unknown');
  assert.equal(selected.providerName, 'Meeting');
  assert.equal(selected.manualFallback, true);
});
