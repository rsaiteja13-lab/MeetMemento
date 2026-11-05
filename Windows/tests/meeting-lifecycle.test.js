'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  DETECTOR_INTERVAL_MS,
  END_CONFIRMATION_CHECKS,
  END_GRACE_MS,
  hasConfirmedMeetingEnded,
  shouldStartRecording,
  shouldStopRecording
} = require('../src/lib/meeting-lifecycle');

test('requires stable detection before automatic recording starts', () => {
  assert.equal(shouldStartRecording(1), false);
  assert.equal(shouldStartRecording(2), true);
});

test('does not stop for a short meeting-window interruption', () => {
  assert.ok(END_CONFIRMATION_CHECKS * DETECTOR_INTERVAL_MS >= END_GRACE_MS);
  assert.equal(shouldStopRecording(4), false);
  assert.equal(shouldStopRecording(END_CONFIRMATION_CHECKS - 1), false);
  assert.equal(shouldStopRecording(END_CONFIRMATION_CHECKS), true);
  assert.equal(hasConfirmedMeetingEnded(END_CONFIRMATION_CHECKS), true);
});
