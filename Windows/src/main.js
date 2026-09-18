'use strict';

const { app, BrowserWindow, desktopCapturer, dialog, ipcMain, Menu, Notification, session, shell, Tray } = require('electron');
const { execFile, spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { chooseZoomSource, cleanMeetingTitle } = require('./lib/zoom-detector');
const { MeetingStore } = require('./lib/meeting-store');
const { RecordingWriter } = require('./lib/recording-writer');
const { SettingsStore } = require('./lib/settings-store');
const { TranscriptService } = require('./lib/transcript-service');

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();

let mainWindow;
let tray;
let settingsStore;
let meetingStore;
let recordingWriter;
let transcriptService;
let pendingCaptureSourceId = null;
let selectedSource = null;
let detectorTimer = null;
let detectorBusy = false;
let missedMeetingChecks = 0;
let suppressedSourceId = null;
let appState = { captureState: 'ready', zoomState: 'not-running', statusMessage: null, activeSource: null };
let quitting = false;
let rendererReady = false;

function resourcesPath(fileName) {
  return app.isPackaged
    ? path.join(process.resourcesPath, fileName)
    : path.join(__dirname, '..', 'resources', fileName);
}

function recordingsRoot() {
  return path.join(app.getPath('videos'), 'MeetMemento', 'Recordings');
}

function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function send(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed() && mainWindow.webContents.isLoading() === false) {
    mainWindow.webContents.send(channel, payload);
  }
}

function publishState(patch = {}) {
  appState = { ...appState, ...patch };
  send('app:state-changed', appState);
  rebuildTray();
}

function showNotification(title, body) {
  if (Notification.isSupported()) new Notification({ title, body, silent: true }).show();
}

function applyLoginItem(settings = settingsStore.get()) {
  if (process.platform !== 'win32') return;
  app.setLoginItemSettings({
    openAtLogin: Boolean(settings.launchAtLogin && settings.consentAcknowledged),
    args: ['--hidden']
  });
}

function showWindow() {
  if (!mainWindow) return;
  mainWindow.show();
  mainWindow.focus();
}

function rebuildTray() {
  if (!tray) return;
  const recording = appState.captureState === 'recording' || appState.captureState === 'starting';
  tray.setToolTip(recording ? 'MeetMemento — Recording Zoom' : 'MeetMemento — Ready');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: recording ? '● Recording Zoom' : 'MeetMemento is ready', enabled: false },
    { type: 'separator' },
    { label: 'Open MeetMemento', click: showWindow },
    recording
      ? { label: 'Stop and save recording', click: () => requestStop('Stopped from the tray.', true) }
      : { label: 'Record Zoom now', click: () => startFromDetection(false) },
    { label: 'Open recordings folder', click: () => shell.openPath(recordingsRoot()) },
    { type: 'separator' },
    { label: 'Quit MeetMemento', click: () => app.quit() }
  ]));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1260,
    height: 820,
    minWidth: 980,
    minHeight: 650,
    show: false,
    backgroundColor: '#f4f6fb',
    icon: resourcesPath('icon.png'),
    title: 'MeetMemento',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      backgroundThrottling: false,
      autoplayPolicy: 'no-user-gesture-required'
    }
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file:')) event.preventDefault();
  });
  mainWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
  mainWindow.webContents.on('render-process-gone', () => {
    rendererReady = false;
    const recovered = recordingWriter.abort('The app interface restarted while recording.');
    if (recovered) publishState({ captureState: 'ready', statusMessage: recovered.errorMessage, activeSource: null });
  });
  mainWindow.webContents.on('did-finish-load', () => {
    rendererReady = true;
    send('app:state-changed', appState);
  });
}

function createTray() {
  tray = new Tray(resourcesPath('icon.png'));
  tray.on('double-click', showWindow);
  rebuildTray();
}

function isZoomRunning() {
  if (process.platform !== 'win32') return Promise.resolve(true);
  return new Promise((resolve) => {
    execFile('tasklist.exe', ['/FO', 'CSV', '/NH'], { windowsHide: true, timeout: 5000 }, (error, stdout) => {
      if (error) return resolve(true);
      resolve(/"(?:Zoom|CptHost)\.exe"/i.test(stdout));
    });
  });
}

async function detectMeeting() {
  const [sources, zoomRunning] = await Promise.all([
    desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: 0, height: 0 }, fetchWindowIcons: false }),
    isZoomRunning()
  ]);
  return chooseZoomSource(sources, zoomRunning, selectedSource?.id);
}

async function pollMeeting() {
  if (detectorBusy) return;
  detectorBusy = true;
  try {
    const source = await detectMeeting();
    publishState({ zoomState: source ? 'in-meeting' : await isZoomRunning() ? 'open' : 'not-running' });
    if (source) {
      missedMeetingChecks = 0;
      if (appState.captureState === 'recording' && selectedSource?.id !== source.id) {
        selectedSource = source;
        publishState({ activeSource: source.name, statusMessage: 'Zoom changed windows. Capture continued automatically.' });
        send('capture:source-changed', { id: source.id, name: source.name });
      } else if (['ready', 'failed'].includes(appState.captureState) && source.id !== suppressedSourceId && rendererReady && settingsStore.get().autoRecord && settingsStore.get().onboardingCompleted) {
        await startCapture(source, true);
      }
    } else if (appState.captureState === 'recording') {
      missedMeetingChecks += 1;
      if (missedMeetingChecks >= 4) await requestStop('Zoom meeting ended.');
    } else {
      suppressedSourceId = null;
    }
  } catch (error) {
    publishState({ statusMessage: `Meeting detection will retry: ${error.message}` });
  } finally {
    detectorBusy = false;
  }
}

async function startCapture(source, automatic) {
  if (!source || !rendererReady || !['ready', 'failed'].includes(appState.captureState)) return false;
  selectedSource = source;
  missedMeetingChecks = 0;
  publishState({ captureState: 'starting', activeSource: source.name, statusMessage: null });
  showNotification('MeetMemento is recording', `${source.name || 'Zoom meeting'} is being recorded locally.`);
  send('capture:start', {
    source: { id: source.id, name: source.name },
    title: cleanMeetingTitle(source.name),
    includeMicrophone: settingsStore.get().includeMicrophone,
    automatic
  });
  return true;
}

async function startFromDetection(showError = true) {
  const source = await detectMeeting();
  if (!source) {
    if (showError) publishState({ statusMessage: 'Open or join a Zoom meeting, then try again.' });
    showWindow();
    return false;
  }
  suppressedSourceId = null;
  return startCapture(source, false);
}

async function requestStop(reason = null, suppressUntilMeetingEnds = false) {
  if (!['recording', 'starting'].includes(appState.captureState)) return false;
  if (suppressUntilMeetingEnds) suppressedSourceId = selectedSource?.id || null;
  publishState({ captureState: 'stopping', statusMessage: reason });
  send('capture:stop', { reason });
  return true;
}

async function finishAndTranscribe(sessionId, details) {
  const meeting = recordingWriter.finish(sessionId, details);
  selectedSource = null;
  publishState({ captureState: 'ready', activeSource: null, statusMessage: 'Recording saved. Creating the transcript locally…' });
  send('library:changed');

  if (meeting.transcriptionStatus === 'processing') {
    void (async () => {
      try {
        const result = await transcriptService.transcribe(
          meeting.wavPath,
          meeting.folderPath,
          settingsStore.get().speechLanguage
        );
        meetingStore.update(meeting.id, {
          transcriptFile: result.status === 'complete' ? 'transcript.txt' : null,
          transcript: result.status === 'complete' ? result.transcript : null,
          transcriptionStatus: result.status,
          errorMessage: result.error || meeting.errorMessage
        });
      } catch (error) {
        meetingStore.update(meeting.id, {
          transcriptionStatus: 'failed',
          errorMessage: [meeting.errorMessage, `Transcript unavailable: ${error.message}`].filter(Boolean).join(' ')
        });
      } finally {
        send('library:changed');
      }
    })();
  }
  return meeting;
}

function registerIpc() {
  ipcMain.handle('app:get-state', () => ({
    app: appState,
    settings: settingsStore.get(),
    meetings: meetingStore.list(),
    recordingsPath: recordingsRoot(),
    platform: process.platform
  }));
  ipcMain.handle('settings:update', (_event, patch) => {
    const settings = settingsStore.update(patch);
    applyLoginItem(settings);
    return settings;
  });
  ipcMain.handle('onboarding:complete', (_event, values) => {
    const settings = settingsStore.update({
      ...values,
      consentAcknowledged: true,
      onboardingCompleted: true
    });
    applyLoginItem(settings);
    return settings;
  });
  ipcMain.handle('speech:probe', () => transcriptService.probe());
  ipcMain.handle('capture:prepare', async (_event, sourceId) => {
    pendingCaptureSourceId = sourceId;
    return true;
  });
  ipcMain.handle('capture:start-manual', () => startFromDetection(true));
  ipcMain.handle('capture:stop', () => requestStop('Stopped by you.', true));
  ipcMain.handle('recording:create', (_event, details) => {
    const sessionInfo = recordingWriter.start({
      title: details.title,
      sourceName: details.sourceName,
      startedAt: new Date(details.startedAt || Date.now())
    });
    publishState({ captureState: 'recording', statusMessage: null });
    return sessionInfo;
  });
  ipcMain.handle('recording:append', (_event, { sessionId, kind, data }) => {
    recordingWriter.append(sessionId, kind, Buffer.from(data));
    return true;
  });
  ipcMain.handle('recording:pcm', (_event, { sessionId, data }) => {
    recordingWriter.appendPcm(sessionId, Buffer.from(data));
    return true;
  });
  ipcMain.handle('recording:finish', (_event, { sessionId, details }) => finishAndTranscribe(sessionId, details));
  ipcMain.on('capture:failed', (_event, message) => {
    recordingWriter.abort(message);
    suppressedSourceId = selectedSource?.id || null;
    selectedSource = null;
    publishState({ captureState: 'failed', activeSource: null, statusMessage: message });
    showWindow();
  });
  ipcMain.handle('meetings:list', () => meetingStore.list());
  ipcMain.handle('meetings:file-url', (_event, { id, kind }) => meetingStore.fileUrl(id, kind));
  ipcMain.handle('meetings:rename', (_event, { id, title }) => {
    const updated = meetingStore.rename(id, title);
    send('library:changed');
    return updated;
  });
  ipcMain.handle('meetings:delete', async (_event, id) => {
    const meeting = meetingStore.find(id);
    if (!meeting) return false;
    await shell.trashItem(meetingStore.folder(meeting));
    send('library:changed');
    return true;
  });
  ipcMain.handle('meetings:export', async (_event, id) => {
    const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory', 'createDirectory'] });
    if (result.canceled || result.filePaths.length === 0) return null;
    return meetingStore.exportFiles(id, result.filePaths[0]);
  });
  ipcMain.handle('meetings:open-folder', async (_event, id) => {
    const meeting = meetingStore.find(id);
    return meeting ? shell.openPath(meetingStore.folder(meeting)) : 'Recording not found.';
  });
  ipcMain.handle('app:open-recordings', () => shell.openPath(recordingsRoot()));
  ipcMain.handle('app:open-recycle-bin', () => {
    if (process.platform === 'win32') {
      const child = spawn('explorer.exe', ['shell:RecycleBinFolder'], { detached: true, windowsHide: true });
      child.unref();
    }
  });
  ipcMain.handle('app:open-speech-settings', () => shell.openExternal('ms-settings:speech'));
}

app.on('second-instance', showWindow);

async function bootApplication() {
  app.setAppUserModelId('com.meetmemento.windows');
  fs.mkdirSync(recordingsRoot(), { recursive: true });
  settingsStore = new SettingsStore(settingsPath());
  meetingStore = new MeetingStore(recordingsRoot());
  recordingWriter = new RecordingWriter(recordingsRoot());
  transcriptService = new TranscriptService(resourcesPath('transcribe.ps1'));
  registerIpc();

  session.defaultSession.setPermissionCheckHandler((_webContents, permission) => ['media', 'display-capture'].includes(permission));
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => callback(['media', 'display-capture'].includes(permission)));
  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    try {
      const sources = await desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: 0, height: 0 } });
      const source = sources.find((candidate) => candidate.id === pendingCaptureSourceId);
      pendingCaptureSourceId = null;
      callback(source ? { video: source, audio: 'loopback' } : {});
    } catch {
      callback({});
    }
  }, { useSystemPicker: false });

  createWindow();
  createTray();
  applyLoginItem();
  const hiddenLaunch = process.argv.includes('--hidden') && settingsStore.get().onboardingCompleted;
  if (!hiddenLaunch) showWindow();
  detectorTimer = setInterval(pollMeeting, 1500);
  await pollMeeting();
}

if (process.argv.includes('--smoke-test')) {
  app.whenReady().then(() => {
    process.stdout.write('MeetMemento Windows smoke test passed.\n');
    app.exit(0);
  });
} else {
  app.whenReady().then(bootApplication);
}

app.on('before-quit', (event) => {
  if (recordingWriter?.active && !quitting) {
    event.preventDefault();
    requestStop('MeetMemento is closing.');
    setTimeout(() => { quitting = true; app.quit(); }, 2500);
    return;
  }
  quitting = true;
  if (detectorTimer) clearInterval(detectorTimer);
});

app.on('window-all-closed', () => { /* Keep the tray process running. */ });
