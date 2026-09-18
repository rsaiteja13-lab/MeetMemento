'use strict';

const { contextBridge, ipcRenderer } = require('electron');

function on(channel, callback) {
  const handler = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, handler);
  return () => ipcRenderer.removeListener(channel, handler);
}

contextBridge.exposeInMainWorld('meetMemento', {
  getState: () => ipcRenderer.invoke('app:get-state'),
  updateSettings: (patch) => ipcRenderer.invoke('settings:update', patch),
  completeOnboarding: (settings) => ipcRenderer.invoke('onboarding:complete', settings),
  probeSpeech: () => ipcRenderer.invoke('speech:probe'),
  prepareCapture: (sourceId) => ipcRenderer.invoke('capture:prepare', sourceId),
  createRecording: (details) => ipcRenderer.invoke('recording:create', details),
  appendChunk: (sessionId, kind, data) => ipcRenderer.invoke('recording:append', { sessionId, kind, data }),
  appendPcm: (sessionId, data) => ipcRenderer.invoke('recording:pcm', { sessionId, data }),
  finishRecording: (sessionId, details) => ipcRenderer.invoke('recording:finish', { sessionId, details }),
  captureFailed: (message) => ipcRenderer.send('capture:failed', message),
  startManualRecording: () => ipcRenderer.invoke('capture:start-manual'),
  stopRecording: () => ipcRenderer.invoke('capture:stop'),
  listMeetings: () => ipcRenderer.invoke('meetings:list'),
  meetingFileUrl: (id, kind) => ipcRenderer.invoke('meetings:file-url', { id, kind }),
  renameMeeting: (id, title) => ipcRenderer.invoke('meetings:rename', { id, title }),
  deleteMeeting: (id) => ipcRenderer.invoke('meetings:delete', id),
  exportMeeting: (id) => ipcRenderer.invoke('meetings:export', id),
  openRecordingFolder: (id) => ipcRenderer.invoke('meetings:open-folder', id),
  openRecordings: () => ipcRenderer.invoke('app:open-recordings'),
  openRecycleBin: () => ipcRenderer.invoke('app:open-recycle-bin'),
  openSpeechSettings: () => ipcRenderer.invoke('app:open-speech-settings'),
  onCaptureStart: (callback) => on('capture:start', callback),
  onCaptureStop: (callback) => on('capture:stop', callback),
  onCaptureSourceChanged: (callback) => on('capture:source-changed', callback),
  onStateChanged: (callback) => on('app:state-changed', callback),
  onLibraryChanged: (callback) => on('library:changed', callback)
});
