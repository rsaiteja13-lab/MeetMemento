'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { WAV_HEADER_BYTES, wavHeader } = require('./recording-writer');
const { writeJsonAtomic } = require('./settings-store');

function readMetadata(folderPath) {
  try {
    return JSON.parse(fs.readFileSync(path.join(folderPath, 'metadata.json'), 'utf8'));
  } catch {
    return null;
  }
}

function safeName(value) {
  return String(value || 'Meeting')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-')
    .replace(/[. ]+$/g, '')
    .slice(0, 100) || 'Meeting';
}

function safeStat(filePath) {
  try { return fs.statSync(filePath); } catch { return null; }
}

function startedAtFromFolder(folderName) {
  const match = /^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})/.exec(folderName);
  if (!match) return null;
  const [, year, month, day, hour, minute, second] = match.map(Number);
  const date = new Date(year, month - 1, day, hour, minute, second);
  return Number.isNaN(date.getTime()) ? null : date;
}

function availableExportDestination(destinationRoot, baseName) {
  let destination = path.join(destinationRoot, baseName);
  let suffix = 2;
  while (fs.existsSync(destination)) {
    destination = path.join(destinationRoot, `${baseName} ${suffix}`);
    suffix += 1;
  }
  return destination;
}

function repairWavHeader(wavPath) {
  const size = safeStat(wavPath)?.size || 0;
  if (size <= WAV_HEADER_BYTES) return false;
  const handle = fs.openSync(wavPath, 'r+');
  try {
    fs.writeSync(handle, wavHeader(size - WAV_HEADER_BYTES), 0, WAV_HEADER_BYTES, 0);
    fs.fsyncSync(handle);
  } finally {
    fs.closeSync(handle);
  }
  return true;
}

class MeetingStore {
  constructor(recordingsRoot) {
    this.recordingsRoot = recordingsRoot;
    fs.mkdirSync(recordingsRoot, { recursive: true });
  }

  list() {
    return fs.readdirSync(this.recordingsRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const metadata = readMetadata(path.join(this.recordingsRoot, entry.name));
        return metadata ? { ...metadata, folderName: entry.name } : null;
      })
      .filter(Boolean)
      .sort((left, right) => new Date(right.startedAt) - new Date(left.startedAt));
  }

  recoverInterruptedRecordings() {
    const recovered = [];
    const entries = fs.readdirSync(this.recordingsRoot, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const folderPath = path.join(this.recordingsRoot, entry.name);
      const metadataPath = path.join(folderPath, 'metadata.json');
      if (fs.existsSync(metadataPath)) continue;

      const session = readMetadataFile(path.join(folderPath, 'recording-session.json')) || {};
      const modernVideoPath = path.join(folderPath, 'meeting-screen.webm');
      const legacyVideoPath = path.join(folderPath, 'zoom-screen.webm');
      const videoPath = safeStat(modernVideoPath) ? modernVideoPath : legacyVideoPath;
      const audioPath = path.join(folderPath, 'meeting-audio.webm');
      const microphonePath = path.join(folderPath, 'my-microphone.webm');
      const wavPath = path.join(folderPath, 'transcription-input.wav');
      const videoStat = safeStat(videoPath);
      const audioStat = safeStat(audioPath);
      const microphoneStat = safeStat(microphonePath);
      const wavStat = safeStat(wavPath);
      const videoValid = (videoStat?.size || 0) > 1024;
      const audioValid = (audioStat?.size || 0) > 256;
      const microphoneValid = (microphoneStat?.size || 0) > 256;
      const speechInputValid = (wavStat?.size || 0) > WAV_HEADER_BYTES + 3200;
      if (!videoValid && !audioValid && !microphoneValid && !speechInputValid) continue;

      const folderStartedAt = startedAtFromFolder(entry.name);
      let startedAt = new Date(session.startedAt || folderStartedAt || Date.now());
      if (Number.isNaN(startedAt.getTime())) startedAt = folderStartedAt || new Date();
      const latestModifiedAt = [videoStat, audioStat, microphoneStat, wavStat]
        .filter(Boolean)
        .map((stat) => stat.mtime)
        .sort((left, right) => right - left)[0] || startedAt;
      const warnings = ['MeetMemento recovered this recording after Windows or the app closed unexpectedly.'];
      if (!videoValid) warnings.push('Video was not finalized, but the available audio was preserved.');
      if (!audioValid) warnings.push('Meeting audio was not finalized.');
      if (speechInputValid) {
        try { repairWavHeader(wavPath); }
        catch (error) { warnings.push(`Transcript audio recovery: ${error.message}`); }
      }

      const metadata = {
        id: session.id || crypto.randomUUID(),
        title: session.title || 'Recovered meeting',
        sourceName: session.sourceName || 'Meeting',
        startedAt: startedAt.toISOString(),
        endedAt: latestModifiedAt.toISOString(),
        durationSeconds: Math.max(0, (latestModifiedAt.getTime() - startedAt.getTime()) / 1000),
        folderName: entry.name,
        videoFile: videoValid ? path.basename(videoPath) : null,
        audioFile: audioValid ? path.basename(audioPath) : null,
        microphoneFile: microphoneValid ? path.basename(microphonePath) : null,
        transcriptFile: null,
        transcriptionStatus: speechInputValid ? 'processing' : 'failed',
        errorMessage: warnings.join(' ')
      };
      writeJsonAtomic(metadataPath, metadata);
      fs.rmSync(path.join(folderPath, 'recording-session.json'), { force: true });
      recovered.push({ ...metadata, folderPath, wavPath });
    }
    return recovered;
  }

  find(id) {
    return this.list().find((meeting) => meeting.id === id) || null;
  }

  folder(meeting) {
    return path.join(this.recordingsRoot, meeting.folderName);
  }

  update(id, patch) {
    const meeting = this.find(id);
    if (!meeting) throw new Error('Recording not found.');
    const updated = { ...meeting, ...patch, id: meeting.id, folderName: meeting.folderName };
    writeJsonAtomic(path.join(this.folder(meeting), 'metadata.json'), updated);
    return updated;
  }

  rename(id, title) {
    return this.update(id, { title: safeName(title) });
  }

  fileUrl(id, kind) {
    const meeting = this.find(id);
    if (!meeting) return null;
    const fileName = kind === 'video'
      ? meeting.videoFile
      : kind === 'audio'
        ? meeting.audioFile
        : meeting.transcriptFile;
    if (!fileName) return null;
    const filePath = path.join(this.folder(meeting), path.basename(fileName));
    return fs.existsSync(filePath) ? pathToFileURL(filePath).href : null;
  }

  exportFiles(id, destinationRoot) {
    const meeting = this.find(id);
    if (!meeting) throw new Error('Recording not found.');
    const destination = availableExportDestination(destinationRoot, safeName(meeting.title));
    fs.mkdirSync(destination, { recursive: false });
    const names = [
      meeting.videoFile,
      meeting.audioFile,
      meeting.microphoneFile,
      meeting.transcriptFile
    ].filter(Boolean);
    for (const name of names) {
      const fileName = path.basename(name);
      fs.copyFileSync(path.join(this.folder(meeting), fileName), path.join(destination, fileName));
    }
    return destination;
  }
}

function readMetadataFile(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, 'utf8')); }
  catch { return null; }
}

module.exports = {
  MeetingStore,
  availableExportDestination,
  readMetadata,
  repairWavHeader,
  safeName,
  startedAtFromFolder
};
