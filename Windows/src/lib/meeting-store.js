'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
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
    const destination = path.join(destinationRoot, safeName(meeting.title));
    fs.mkdirSync(destination, { recursive: true });
    const names = [meeting.videoFile, meeting.audioFile, meeting.transcriptFile].filter(Boolean);
    for (const name of names) {
      const fileName = path.basename(name);
      fs.copyFileSync(path.join(this.folder(meeting), fileName), path.join(destination, fileName));
    }
    return destination;
  }
}

module.exports = { MeetingStore, readMetadata, safeName };
