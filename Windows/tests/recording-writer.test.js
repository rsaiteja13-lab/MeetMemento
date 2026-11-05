'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { MeetingStore } = require('../src/lib/meeting-store');
const { RecordingWriter } = require('../src/lib/recording-writer');

test('streams video, audio, and PCM to a finalized recording folder', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-recording-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const writer = new RecordingWriter(root);
  const startedAt = new Date('2026-09-18T10:00:00.000Z');
  const session = writer.start({ title: 'Test meeting', sourceName: 'Zoom Meeting', startedAt });
  writer.append(session.id, 'video', Buffer.alloc(4096, 1));
  writer.append(session.id, 'audio', Buffer.alloc(2048, 2));
  writer.append(session.id, 'microphone', Buffer.alloc(1024, 4));
  writer.appendPcm(session.id, Buffer.alloc(64000, 3));
  const result = writer.finish(session.id, { endedAt: '2026-09-18T10:00:12.000Z' });
  const metadata = JSON.parse(fs.readFileSync(path.join(root, result.folderName, 'metadata.json'), 'utf8'));
  const wav = fs.readFileSync(path.join(root, result.folderName, 'transcription-input.wav'));
  assert.equal(metadata.durationSeconds, 12);
  assert.equal(metadata.videoFile, 'meeting-screen.webm');
  assert.equal(metadata.audioFile, 'meeting-audio.webm');
  assert.equal(metadata.microphoneFile, 'my-microphone.webm');
  assert.equal(metadata.transcriptionStatus, 'processing');
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.readUInt32LE(40), 64000);
  assert.equal(fs.existsSync(path.join(root, result.folderName, 'recording-session.json')), false);
});

test('recovers streamed files and repairs transcript audio after an interrupted process', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-recovery-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const writer = new RecordingWriter(root);
  const session = writer.start({
    title: 'Interrupted meeting',
    sourceName: 'Zoom Meeting',
    startedAt: new Date('2026-09-18T10:00:00.000Z')
  });
  writer.append(session.id, 'video', Buffer.alloc(4096, 1));
  writer.append(session.id, 'audio', Buffer.alloc(2048, 2));
  writer.append(session.id, 'microphone', Buffer.alloc(1024, 4));
  writer.appendPcm(session.id, Buffer.alloc(64000, 3));
  for (const handle of [
    writer.active.videoHandle,
    writer.active.audioHandle,
    writer.active.microphoneHandle,
    writer.active.wavHandle
  ]) {
    fs.closeSync(handle);
  }
  writer.active = null;

  const recovered = new MeetingStore(root).recoverInterruptedRecordings();
  assert.equal(recovered.length, 1);
  assert.equal(recovered[0].id, session.id);
  assert.equal(recovered[0].videoFile, 'meeting-screen.webm');
  assert.equal(recovered[0].audioFile, 'meeting-audio.webm');
  assert.equal(recovered[0].microphoneFile, 'my-microphone.webm');
  assert.equal(recovered[0].transcriptionStatus, 'processing');
  const wav = fs.readFileSync(path.join(root, session.folderName, 'transcription-input.wav'));
  assert.equal(wav.readUInt32LE(40), 64000);
  assert.equal(fs.existsSync(path.join(root, session.folderName, 'recording-session.json')), false);
});

test('does not collide when two meetings start in the same second', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-collision-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const startedAt = new Date('2026-09-18T10:00:00.000Z');
  const first = new RecordingWriter(root);
  const firstSession = first.start({ title: 'First', sourceName: 'Zoom', startedAt });
  first.abort();
  const second = new RecordingWriter(root);
  const secondSession = second.start({ title: 'Second', sourceName: 'Zoom', startedAt });
  second.abort();
  assert.notEqual(firstSession.folderName, secondSession.folderName);
});

test('has no short-duration cutoff and continues accepting long-session chunks', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-long-recording-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const writer = new RecordingWriter(root);
  const startedAt = new Date('2026-09-18T10:00:00.000Z');
  const session = writer.start({ title: 'Long meeting', sourceName: 'Zoom Meeting', startedAt });
  for (let second = 0; second < 7200; second += 1) writer.append(session.id, 'video', Buffer.alloc(64, second % 255));
  writer.append(session.id, 'audio', Buffer.alloc(2048, 2));
  writer.appendPcm(session.id, Buffer.alloc(6400, 3));
  const result = writer.finish(session.id, { endedAt: '2026-09-18T12:00:00.000Z' });
  assert.equal(result.durationSeconds, 7200);
  assert.ok(fs.statSync(path.join(root, result.folderName, 'meeting-screen.webm')).size > 400000);
});

test('exports every media track without overwriting a previous export', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-export-'));
  const destinationRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-export-destination-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  context.after(() => fs.rmSync(destinationRoot, { recursive: true, force: true }));
  const writer = new RecordingWriter(root);
  const session = writer.start({
    title: 'Weekly review',
    sourceName: 'Teams Meeting',
    startedAt: new Date('2026-09-18T10:00:00.000Z')
  });
  writer.append(session.id, 'video', Buffer.alloc(4096, 1));
  writer.append(session.id, 'audio', Buffer.alloc(2048, 2));
  writer.append(session.id, 'microphone', Buffer.alloc(1024, 3));
  writer.appendPcm(session.id, Buffer.alloc(6400, 4));
  const meeting = writer.finish(session.id, { endedAt: '2026-09-18T10:01:00.000Z' });
  const store = new MeetingStore(root);
  const first = store.exportFiles(meeting.id, destinationRoot);
  const second = store.exportFiles(meeting.id, destinationRoot);
  assert.notEqual(first, second);
  for (const name of ['meeting-screen.webm', 'meeting-audio.webm', 'my-microphone.webm']) {
    assert.equal(fs.existsSync(path.join(first, name)), true);
    assert.equal(fs.existsSync(path.join(second, name)), true);
  }
});
