'use strict';

const CAPTURE_STARTUP_TIMEOUT_MS = 20000;
const CAPTURE_FINALIZATION_TIMEOUT_MS = 15000;
const RENDERER_HEARTBEAT_TIMEOUT_MS = 20000;
const RECOVERY_WINDOW_MS = 5 * 60 * 1000;
const MAX_RECOVERY_ATTEMPTS = 2;

function hasTimedOut(state, startedAt, now, timeoutMs) {
  return state === 'starting'
    && Number.isFinite(startedAt)
    && now - startedAt >= timeoutMs;
}

function isHeartbeatStale(lastHeartbeatAt, now, timeoutMs = RENDERER_HEARTBEAT_TIMEOUT_MS) {
  return Number.isFinite(lastHeartbeatAt)
    && lastHeartbeatAt > 0
    && now - lastHeartbeatAt >= timeoutMs;
}

function registerRecoveryAttempt(attempts, now, {
  windowMs = RECOVERY_WINDOW_MS,
  maximum = MAX_RECOVERY_ATTEMPTS
} = {}) {
  const recent = (attempts || []).filter((attempt) => now - attempt >= 0 && now - attempt < windowMs);
  const allowed = recent.length < maximum;
  return { allowed, attempts: allowed ? [...recent, now] : recent };
}

module.exports = {
  CAPTURE_FINALIZATION_TIMEOUT_MS,
  CAPTURE_STARTUP_TIMEOUT_MS,
  MAX_RECOVERY_ATTEMPTS,
  RECOVERY_WINDOW_MS,
  RENDERER_HEARTBEAT_TIMEOUT_MS,
  hasTimedOut,
  isHeartbeatStale,
  registerRecoveryAttempt
};
