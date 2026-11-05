'use strict';

const DETECTOR_INTERVAL_MS = 1500;
const START_CONFIRMATION_CHECKS = 2;
const END_GRACE_MS = 20000;
const END_CONFIRMATION_CHECKS = Math.ceil(END_GRACE_MS / DETECTOR_INTERVAL_MS);

function shouldStartRecording(consecutiveChecks) {
  return consecutiveChecks >= START_CONFIRMATION_CHECKS;
}

function shouldStopRecording(consecutiveMissingChecks) {
  return consecutiveMissingChecks >= END_CONFIRMATION_CHECKS;
}

function hasConfirmedMeetingEnded(consecutiveMissingChecks) {
  return consecutiveMissingChecks >= END_CONFIRMATION_CHECKS;
}

module.exports = {
  DETECTOR_INTERVAL_MS,
  END_CONFIRMATION_CHECKS,
  END_GRACE_MS,
  START_CONFIRMATION_CHECKS,
  hasConfirmedMeetingEnded,
  shouldStartRecording,
  shouldStopRecording
};
