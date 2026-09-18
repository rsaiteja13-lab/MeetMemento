'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { formatTranscript, timestamp } = require('../src/lib/transcript-format');

test('formats timestamps beyond one hour', () => {
  assert.equal(timestamp(3723.9), '01:02:03');
});

test('formats non-empty transcript segments', () => {
  assert.equal(formatTranscript([
    { start: 2.5, text: ' Hello there ' },
    { start: 65, text: '' },
    { start: 66, text: 'Next point' }
  ]), '[00:00:02] Hello there\n\n[00:01:06] Next point');
});
