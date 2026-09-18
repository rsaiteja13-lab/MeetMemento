'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { chooseZoomSource, cleanMeetingTitle, scoreSource } = require('../src/lib/zoom-detector');

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
});

test('uses descriptive Zoom window text as the meeting name', () => {
  assert.equal(cleanMeetingTitle('Customer review - Zoom Meeting'), 'Customer review');
  assert.match(cleanMeetingTitle('Zoom Meeting', new Date('2026-09-18T10:00:00Z')), /^Zoom meeting — /);
});
