'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { writeJsonAtomic } = require('./settings-store');

const WAV_HEADER_BYTES = 44;

function folderStamp(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
}

function wavHeader(dataBytes, sampleRate = 16000, channels = 1, bitsPerSample = 16) {
  const bytesPerSample = bitsPerSample / 8;
  const blockAlign = channels * bytesPerSample;
  const byteRate = sampleRate * blockAlign;
  const header = Buffer.alloc(WAV_HEADER_BYTES);
  header.write('RIFF', 0, 'ascii');
  header.writeUInt32LE(36 + dataBytes, 4);
  header.write('WAVE', 8, 'ascii');
  header.write('fmt ', 12, 'ascii');
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write('data', 36, 'ascii');
  header.writeUInt32LE(dataBytes, 40);
  return header;
}

function safeSize(filePath) {
  try { return fs.statSync(filePath).size; } catch { return 0; }
}

class RecordingWriter {
  constructor(recordingsRoot) {
    this.recordingsRoot = recordingsRoot;
    this.active = null;
  }

  start({ title, sourceName, startedAt = new Date() }) {
    if (this.active) throw new Error('A recording is already active.');
    fs.mkdirSync(this.recordingsRoot, { recursive: true });
    const initialFolderName = folderStamp(startedAt);
    let folderName = initialFolderName;
    let suffix = 2;
    while (fs.existsSync(path.join(this.recordingsRoot, folderName))) {
      folderName = `${initialFolderName}_${suffix}`;
      suffix += 1;
    }
    const folderPath = path.join(this.recordingsRoot, folderName);
    fs.mkdirSync(folderPath, { recursive: false });

    const videoPath = path.join(folderPath, 'meeting-screen.webm');
    const audioPath = path.join(folderPath, 'meeting-audio.webm');
    const microphonePath = path.join(folderPath, 'my-microphone.webm');
    const wavPath = path.join(folderPath, 'transcription-input.wav');
    const id = crypto.randomUUID();
    writeJsonAtomic(path.join(folderPath, 'recording-session.json'), {
      id,
      title,
      sourceName,
      startedAt: startedAt.toISOString(),
      folderName
    });
    const session = {
      id,
      title,
      sourceName,
      startedAt,
      folderName,
      folderPath,
      videoPath,
      audioPath,
      microphonePath,
      wavPath,
      videoHandle: fs.openSync(videoPath, 'w'),
      audioHandle: fs.openSync(audioPath, 'w'),
      microphoneHandle: fs.openSync(microphonePath, 'w'),
      wavHandle: fs.openSync(wavPath, 'w+'),
      videoBytes: 0,
      audioBytes: 0,
      microphoneBytes: 0,
      pcmBytes: 0
    };
    fs.writeSync(session.wavHandle, wavHeader(0));
    this.active = session;
    return { id: session.id, folderName, startedAt: startedAt.toISOString() };
  }

  #require(sessionId) {
    if (!this.active || this.active.id !== sessionId) throw new Error('Recording session is no longer active.');
    return this.active;
  }

  append(sessionId, kind, chunk) {
    const session = this.#require(sessionId);
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (buffer.length === 0) return;
    if (kind === 'video') {
      fs.writeSync(session.videoHandle, buffer);
      session.videoBytes += buffer.length;
    } else if (kind === 'audio') {
      fs.writeSync(session.audioHandle, buffer);
      session.audioBytes += buffer.length;
    } else if (kind === 'microphone') {
      fs.writeSync(session.microphoneHandle, buffer);
      session.microphoneBytes += buffer.length;
    } else {
      throw new Error(`Unsupported recording chunk: ${kind}`);
    }
  }

  appendPcm(sessionId, chunk) {
    const session = this.#require(sessionId);
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (buffer.length === 0) return;
    fs.writeSync(session.wavHandle, buffer);
    session.pcmBytes += buffer.length;
  }

  finish(sessionId, { endedAt = new Date(), warnings = [], errorMessage = null } = {}) {
    const session = this.#require(sessionId);
    const finishedAt = endedAt instanceof Date ? endedAt : new Date(endedAt);
    if (Number.isNaN(finishedAt.getTime())) throw new Error('The recording end time is invalid.');
    const finalizationFailures = [];
    try {
      fs.writeSync(session.wavHandle, wavHeader(session.pcmBytes), 0, WAV_HEADER_BYTES, 0);
    } catch (error) {
      finalizationFailures.push(`Transcript audio header: ${error.message}`);
    }
    for (const handle of [session.videoHandle, session.audioHandle, session.microphoneHandle, session.wavHandle]) {
      try { fs.fsyncSync(handle); } catch (error) { finalizationFailures.push(`File flush: ${error.message}`); }
      try { fs.closeSync(handle); } catch (error) { finalizationFailures.push(`File close: ${error.message}`); }
    }
    this.active = null;

    const videoValid = safeSize(session.videoPath) > 1024;
    const audioValid = safeSize(session.audioPath) > 256;
    const microphoneValid = safeSize(session.microphonePath) > 256;
    if (!microphoneValid) fs.rmSync(session.microphonePath, { force: true });
    const speechInputValid = safeSize(session.wavPath) > WAV_HEADER_BYTES + 3200;
    const failures = [...warnings, ...finalizationFailures];
    if (!videoValid) failures.push('Video was not captured.');
    if (!audioValid) failures.push('Meeting audio was not captured.');

    const metadata = {
      id: session.id,
      title: session.title,
      sourceName: session.sourceName,
      startedAt: session.startedAt.toISOString(),
      endedAt: finishedAt.toISOString(),
      durationSeconds: Math.max(0, (finishedAt.getTime() - session.startedAt.getTime()) / 1000),
      folderName: session.folderName,
      videoFile: videoValid ? path.basename(session.videoPath) : null,
      audioFile: audioValid ? path.basename(session.audioPath) : null,
      microphoneFile: microphoneValid ? path.basename(session.microphonePath) : null,
      transcriptFile: null,
      transcriptionStatus: speechInputValid ? 'processing' : 'failed',
      errorMessage: [errorMessage, ...failures].filter(Boolean).join(' ') || null
    };
    writeJsonAtomic(path.join(session.folderPath, 'metadata.json'), metadata);
    fs.rmSync(path.join(session.folderPath, 'recording-session.json'), { force: true });
    return { ...metadata, folderPath: session.folderPath, wavPath: session.wavPath };
  }

  abort(errorMessage = 'Recording ended unexpectedly.') {
    if (!this.active) return null;
    return this.finish(this.active.id, { errorMessage });
  }
}

module.exports = { RecordingWriter, WAV_HEADER_BYTES, folderStamp, wavHeader };
