'use strict';

function timestamp(seconds) {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const remaining = value % 60;
  return [hours, minutes, remaining].map((part) => String(part).padStart(2, '0')).join(':');
}

function formatTranscript(segments) {
  return (segments || [])
    .filter((segment) => String(segment.text || '').trim())
    .map((segment) => `[${timestamp(segment.start)}] ${String(segment.text).trim()}`)
    .join('\n\n');
}

module.exports = { formatTranscript, timestamp };
