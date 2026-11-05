'use strict';

const { app, BrowserWindow, desktopCapturer, dialog, ipcMain, Menu, Notification, session, shell, Tray } = require('electron');
const { execFile, spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const {
  CAPTURE_FINALIZATION_TIMEOUT_MS,
  CAPTURE_STARTUP_TIMEOUT_MS,
  RENDERER_HEARTBEAT_TIMEOUT_MS,
  hasTimedOut,
  isHeartbeatStale,
  registerRecoveryAttempt
} = require('./lib/capture-recovery');
const {
  chooseManualSource,
  chooseMeetingSource,
  cleanMeetingTitle,
  runningMeetingAppsFromTaskList
} = require('./lib/zoom-detector');
const { MeetingStore } = require('./lib/meeting-store');
const {
  DETECTOR_INTERVAL_MS,
  hasConfirmedMeetingEnded,
  shouldStartRecording,
  shouldStopRecording
} = require('./lib/meeting-lifecycle');
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
let rendererHealthTimer = null;
let captureStartupTimer = null;
let captureFinalizationTimer = null;
let detectorBusy = false;
let confirmedMeetingChecks = 0;
let missedMeetingChecks = 0;
let lastDetectedSourceId = null;
let suppressAutomaticUntilMeetingEnds = false;
let manualFallbackCapture = false;
let appState = { captureState: 'ready', meetingState: 'not-running', statusMessage: null, activeSource: null };
let quitting = false;
let quitAfterSave = false;
let rendererReady = false;
let rendererLastHeartbeatAt = 0;
let rendererRecoveryInProgress = false;
let rendererRecoveryAttempts = [];
let captureRecoveryAttempts = [];
let captureStartupStartedAt = 0;
let transcriptionQueue = Promise.resolve();

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
  if (mainWindow
      && !mainWindow.isDestroyed()
      && !mainWindow.webContents.isDestroyed()
      && mainWindow.webContents.isLoading() === false) {
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
  tray.setToolTip(recording ? 'MeetMemento — Recording meeting' : 'MeetMemento — Ready');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: recording ? '● Recording meeting' : 'MeetMemento is ready', enabled: false },
    { type: 'separator' },
    { label: 'Open MeetMemento', click: showWindow },
    recording
      ? { label: 'Stop and save recording', click: () => requestStop('Stopped from the tray.', true) }
      : { label: 'Record meeting now', click: () => startFromDetection(false) },
    { label: 'Open recordings folder', click: () => shell.openPath(recordingsRoot()) },
    { type: 'separator' },
    { label: 'Hide MeetMemento', click: () => mainWindow?.hide() }
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
  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    recoverRenderer(`The app interface stopped unexpectedly (${details.reason || 'unknown reason'}).`);
  });
  mainWindow.on('unresponsive', () => recoverRenderer('The app interface stopped responding.'));
  mainWindow.webContents.on('did-finish-load', () => {
    rendererReady = true;
    rendererLastHeartbeatAt = Date.now();
    rendererRecoveryInProgress = false;
    send('app:state-changed', appState);
    void pollMeeting();
  });
}

function createTray() {
  tray = new Tray(resourcesPath('icon.png'));
  tray.on('double-click', showWindow);
  rebuildTray();
}

function listRunningMeetingApps() {
  if (process.platform !== 'win32') return Promise.resolve(new Set());
  return new Promise((resolve) => {
    execFile('tasklist.exe', ['/FO', 'CSV', '/NH'], { windowsHide: true, timeout: 5000 }, (error, stdout) => {
      if (error) return resolve(new Set());
      resolve(runningMeetingAppsFromTaskList(stdout));
    });
  });
}

async function detectMeeting() {
  const [sources, runningApps] = await Promise.all([
    desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: 0, height: 0 }, fetchWindowIcons: false }),
    listRunningMeetingApps()
  ]);
  return {
    source: chooseMeetingSource(sources, runningApps, selectedSource?.id),
    sources,
    runningApps
  };
}

async function pollMeeting() {
  if (detectorBusy) return;
  detectorBusy = true;
  try {
    const { source, sources, runningApps } = await detectMeeting();
    const manualSourceStillVisible = manualFallbackCapture
      && selectedSource
      && sources.some((candidate) => candidate.id === selectedSource.id);
    publishState({ meetingState: source || manualSourceStillVisible ? 'in-meeting' : runningApps.size > 0 ? 'open' : 'not-running' });
    if (manualFallbackCapture && appState.captureState === 'recording') {
      if (manualSourceStillVisible) {
        missedMeetingChecks = 0;
      } else {
        missedMeetingChecks += 1;
        if (shouldStopRecording(missedMeetingChecks)) await requestStop('Meeting window closed.');
      }
      return;
    }
    if (source) {
      confirmedMeetingChecks = source.id === lastDetectedSourceId
        ? confirmedMeetingChecks + 1
        : 1;
      lastDetectedSourceId = source.id;
      missedMeetingChecks = 0;
      if (appState.captureState === 'recording' && selectedSource?.id !== source.id) {
        selectedSource = source;
        publishState({ activeSource: source.name, statusMessage: 'The meeting app changed windows. Capture continued automatically.' });
        send('capture:source-changed', { id: source.id, name: source.name });
      } else if (['ready', 'failed'].includes(appState.captureState)
          && !suppressAutomaticUntilMeetingEnds
          && shouldStartRecording(confirmedMeetingChecks)
          && rendererReady
          && settingsStore.get().autoRecord
          && settingsStore.get().onboardingCompleted) {
        await startCapture(source, true);
      }
    } else {
      confirmedMeetingChecks = 0;
      lastDetectedSourceId = null;
      missedMeetingChecks += 1;
      if (appState.captureState === 'recording') {
        if (shouldStopRecording(missedMeetingChecks)) await requestStop('Meeting ended.');
      } else if (hasConfirmedMeetingEnded(missedMeetingChecks)) {
        suppressAutomaticUntilMeetingEnds = false;
      }
    }
  } catch (error) {
    publishState({ statusMessage: `Meeting detection will retry: ${error.message}` });
  } finally {
    detectorBusy = false;
  }
}

function clearCaptureStartupWatchdog() {
  if (captureStartupTimer) clearTimeout(captureStartupTimer);
  captureStartupTimer = null;
  captureStartupStartedAt = 0;
}

function clearCaptureFinalizationWatchdog() {
  if (captureFinalizationTimer) clearTimeout(captureFinalizationTimer);
  captureFinalizationTimer = null;
}

function queueTranscription(meeting) {
  if (!meeting || meeting.transcriptionStatus !== 'processing') return;
  const folderPath = meeting.folderPath || meetingStore.folder(meeting);
  const wavPath = meeting.wavPath || path.join(folderPath, 'transcription-input.wav');
  transcriptionQueue = transcriptionQueue.then(async () => {
    try {
      const result = await transcriptService.transcribe(
        wavPath,
        folderPath,
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
  }).catch(() => { /* keep later transcript jobs running */ });
}

function abortActiveRecording(message) {
  const recovered = recordingWriter.abort(message);
  if (!recovered) return null;
  send('library:changed');
  queueTranscription(recovered);
  return recovered;
}

function finishQuitIfRequested() {
  if (!quitAfterSave) return;
  quitAfterSave = false;
  quitting = true;
  setImmediate(() => app.quit());
}

function recoverRenderer(reason) {
  if (rendererRecoveryInProgress || !mainWindow || mainWindow.isDestroyed()) return;
  const now = Date.now();
  const recovery = registerRecoveryAttempt(rendererRecoveryAttempts, now);
  rendererRecoveryAttempts = recovery.attempts;
  rendererRecoveryInProgress = true;
  rendererReady = false;
  clearCaptureStartupWatchdog();
  clearCaptureFinalizationWatchdog();
  const recovered = abortActiveRecording(reason);
  selectedSource = null;
  manualFallbackCapture = false;
  pendingCaptureSourceId = null;
  publishState({
    captureState: recovery.allowed ? 'ready' : 'failed',
    activeSource: null,
    statusMessage: recovered
      ? 'The recording interface restarted. The available video and audio were preserved.'
      : recovery.allowed
        ? 'MeetMemento recovered its recording interface automatically.'
        : 'The recording interface stopped repeatedly. Reopen MeetMemento to try again.'
  });
  if (!recovery.allowed || mainWindow.webContents.isDestroyed()) {
    rendererRecoveryInProgress = false;
    showWindow();
    return;
  }
  setTimeout(() => {
    if (!mainWindow || mainWindow.isDestroyed() || mainWindow.webContents.isDestroyed()) return;
    mainWindow.webContents.reload();
  }, 500);
}

function armCaptureStartupWatchdog(source) {
  clearCaptureStartupWatchdog();
  captureStartupStartedAt = Date.now();
  captureStartupTimer = setTimeout(() => {
    if (!hasTimedOut('starting', captureStartupStartedAt, Date.now(), CAPTURE_STARTUP_TIMEOUT_MS)
        || appState.captureState !== 'starting') return;
    const recovery = registerRecoveryAttempt(captureRecoveryAttempts, Date.now());
    captureRecoveryAttempts = recovery.attempts;
    send('capture:cancel', { reason: 'Windows capture startup timed out.' });
    pendingCaptureSourceId = null;
    selectedSource = null;
    manualFallbackCapture = false;
    clearCaptureStartupWatchdog();
    if (recovery.allowed) {
      publishState({
        captureState: 'ready',
        activeSource: null,
        statusMessage: 'Capture startup took too long. MeetMemento is retrying automatically…'
      });
      setTimeout(() => void pollMeeting(), 750);
    } else {
      suppressAutomaticUntilMeetingEnds = true;
      publishState({
        captureState: 'failed',
        activeSource: null,
        statusMessage: 'Windows capture did not start after automatic recovery. MeetMemento will try again with the next meeting.'
      });
      showWindow();
    }
  }, CAPTURE_STARTUP_TIMEOUT_MS + 50);
}

function armCaptureFinalizationWatchdog() {
  clearCaptureFinalizationWatchdog();
  captureFinalizationTimer = setTimeout(() => {
    if (appState.captureState !== 'stopping') return;
    send('capture:cancel', { reason: 'Recording finalization timed out.' });
    const recovered = abortActiveRecording('MeetMemento recovered this recording after finalization took too long.');
    selectedSource = null;
    manualFallbackCapture = false;
    publishState({
      captureState: 'ready',
      activeSource: null,
      statusMessage: recovered
        ? 'Recording finalization took too long, but the available video and audio were preserved.'
        : 'Recording stopped.'
    });
    clearCaptureFinalizationWatchdog();
    finishQuitIfRequested();
  }, CAPTURE_FINALIZATION_TIMEOUT_MS);
}

async function startCapture(source, automatic) {
  if (!source || !rendererReady || !['ready', 'failed'].includes(appState.captureState)) return false;
  selectedSource = source;
  manualFallbackCapture = Boolean(source.manualFallback);
  missedMeetingChecks = 0;
  publishState({ captureState: 'starting', activeSource: source.name, statusMessage: null });
  armCaptureStartupWatchdog(source);
  send('capture:start', {
    source: { id: source.id, name: source.name },
    title: cleanMeetingTitle(source.name, source.providerName || 'Meeting'),
    providerName: source.providerName || 'Meeting',
    includeMicrophone: settingsStore.get().includeMicrophone,
    automatic
  });
  return true;
}

async function startFromDetection(showError = true) {
  const detection = await detectMeeting();
  const source = detection.source || (showError ? chooseManualSource(detection.sources) : null);
  if (!source) {
    if (showError) publishState({ statusMessage: 'Open the meeting window, then choose Record meeting now again.' });
    showWindow();
    return false;
  }
  suppressAutomaticUntilMeetingEnds = false;
  return startCapture(source, false);
}

async function requestStop(reason = null, suppressUntilMeetingEnds = false) {
  if (!['recording', 'starting'].includes(appState.captureState)) return false;
  if (suppressUntilMeetingEnds) suppressAutomaticUntilMeetingEnds = true;
  publishState({ captureState: 'stopping', statusMessage: reason });
  clearCaptureStartupWatchdog();
  armCaptureFinalizationWatchdog();
  send('capture:stop', { reason });
  return true;
}

async function finishAndTranscribe(sessionId, details) {
  clearCaptureStartupWatchdog();
  clearCaptureFinalizationWatchdog();
  const meeting = recordingWriter.finish(sessionId, details);
  selectedSource = null;
  manualFallbackCapture = false;
  publishState({ captureState: 'ready', activeSource: null, statusMessage: 'Recording saved. Creating the transcript locally…' });
  send('library:changed');

  queueTranscription(meeting);
  finishQuitIfRequested();
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
  ipcMain.on('renderer:heartbeat', () => {
    rendererLastHeartbeatAt = Date.now();
  });
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
    clearCaptureStartupWatchdog();
    publishState({ captureState: 'recording', statusMessage: null });
    showNotification(
      'MeetMemento is recording',
      `${details.sourceName || 'Meeting'} is being recorded locally.`
    );
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
  ipcMain.on('capture:failed', (_event, payload) => {
    const detail = typeof payload === 'string' ? { message: payload, retry: false } : payload || {};
    const message = detail.message || 'Recording stopped unexpectedly.';
    clearCaptureStartupWatchdog();
    clearCaptureFinalizationWatchdog();
    abortActiveRecording(message);
    const recovery = detail.retry
      ? registerRecoveryAttempt(captureRecoveryAttempts, Date.now())
      : { allowed: false, attempts: captureRecoveryAttempts };
    captureRecoveryAttempts = recovery.attempts;
    suppressAutomaticUntilMeetingEnds = !recovery.allowed;
    selectedSource = null;
    manualFallbackCapture = false;
    publishState({
      captureState: recovery.allowed ? 'ready' : 'failed',
      activeSource: null,
      statusMessage: recovery.allowed
        ? `${message} MeetMemento is reconnecting automatically…`
        : message
    });
    if (recovery.allowed) setTimeout(() => void pollMeeting(), 750);
    else showWindow();
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
  ipcMain.handle('meetings:delete-many', async (_event, ids) => {
    const uniqueIds = [...new Set(Array.isArray(ids) ? ids : [])]
      .filter((id) => typeof id === 'string')
      .slice(0, 1000);
    const movedIds = [];
    const failures = [];
    for (const id of uniqueIds) {
      const meeting = meetingStore.find(id);
      if (!meeting) continue;
      try {
        await shell.trashItem(meetingStore.folder(meeting));
        movedIds.push(id);
      } catch (error) {
        failures.push({ id, message: error.message });
      }
    }
    if (movedIds.length > 0) send('library:changed');
    return { movedIds, failures };
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
  const recoveredMeetings = meetingStore.recoverInterruptedRecordings();
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
  for (const meeting of meetingStore.list().filter((item) => item.transcriptionStatus === 'processing')) {
    queueTranscription({
      ...meeting,
      folderPath: meetingStore.folder(meeting),
      wavPath: path.join(meetingStore.folder(meeting), 'transcription-input.wav')
    });
  }
  if (recoveredMeetings.length > 0) {
    publishState({
      statusMessage: recoveredMeetings.length === 1
        ? 'An interrupted recording was recovered. Its available video and audio are ready.'
        : `${recoveredMeetings.length} interrupted recordings were recovered.`
    });
  }
  const hiddenLaunch = process.argv.includes('--hidden') && settingsStore.get().onboardingCompleted;
  if (!hiddenLaunch) showWindow();
  detectorTimer = setInterval(pollMeeting, DETECTOR_INTERVAL_MS);
  rendererHealthTimer = setInterval(() => {
    if (rendererReady
        && isHeartbeatStale(rendererLastHeartbeatAt, Date.now(), RENDERER_HEARTBEAT_TIMEOUT_MS)) {
      recoverRenderer('The recording interface stopped responding.');
    }
  }, 5000);
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
    quitAfterSave = true;
    requestStop('MeetMemento is closing.');
    return;
  }
  quitting = true;
  if (detectorTimer) clearInterval(detectorTimer);
  if (rendererHealthTimer) clearInterval(rendererHealthTimer);
  clearCaptureStartupWatchdog();
  clearCaptureFinalizationWatchdog();
});

app.on('window-all-closed', () => { /* Keep the tray process running. */ });
