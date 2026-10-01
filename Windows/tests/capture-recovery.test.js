'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  CAPTURE_STARTUP_TIMEOUT_MS,
  hasTimedOut,
  isHeartbeatStale,
  registerRecoveryAttempt
} = require('../src/lib/capture-recovery');

test('detects capture startup stalls only after the timeout', () => {
  assert.equal(hasTimedOut('starting', 1000, 1000 + CAPTURE_STARTUP_TIMEOUT_MS - 1, CAPTURE_STARTUP_TIMEOUT_MS), false);
  assert.equal(hasTimedOut('starting', 1000, 1000 + CAPTURE_STARTUP_TIMEOUT_MS, CAPTURE_STARTUP_TIMEOUT_MS), true);
  assert.equal(hasTimedOut('recording', 1000, 100000, CAPTURE_STARTUP_TIMEOUT_MS), false);
});

test('detects stale renderer heartbeats', () => {
  assert.equal(isHeartbeatStale(1000, 20999, 20000), false);
  assert.equal(isHeartbeatStale(1000, 21000, 20000), true);
  assert.equal(isHeartbeatStale(0, 50000, 20000), false);
});

test('limits automatic recovery attempts inside one window', () => {
  const first = registerRecoveryAttempt([], 1000);
  const second = registerRecoveryAttempt(first.attempts, 2000);
  const third = registerRecoveryAttempt(second.attempts, 3000);
  assert.equal(first.allowed, true);
  assert.equal(second.allowed, true);
  assert.equal(third.allowed, false);
  assert.equal(registerRecoveryAttempt(third.attempts, 400000).allowed, true);
});
