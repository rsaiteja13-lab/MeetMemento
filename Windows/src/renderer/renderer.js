'use strict';

const api = window.meetMemento;

const elements = Object.fromEntries([
  'app', 'onboarding', 'captureDot', 'captureTitle', 'captureDescription', 'captureButton',
  'meetingCount', 'meetingList', 'openRecycleBin', 'openSettings', 'detailPane', 'meetingTitle',
  'meetingMeta', 'meetingActions', 'renameMeeting', 'exportMeeting', 'deleteMeeting', 'statusBanner',
  'emptyState', 'emptyRecordButton', 'meetingDetail', 'videoPlayer', 'videoUnavailable', 'audioPlayer',
  'audioUnavailable', 'openMeetingFolder', 'transcriptBadge', 'transcriptContent', 'setupAutoRecord',
  'setupMicrophone', 'setupLogin', 'setupConsent', 'setupProgress', 'finishSetup', 'settingsDialog',
  'autoRecordSetting', 'microphoneSetting', 'loginSetting', 'openRecordingsFolder', 'checkSpeech',
  'speechStatus', 'captureCanvas', 'captureSourceVideo'
].map((id) => [id, document.getElementById(id)]));

const viewState = {
  app: { captureState: 'ready', zoomState: 'not-running', statusMessage: null },
  settings: null,
  meetings: [],
  selectedId: null,
  renderingMeeting: 0
};

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function formatDay(dateValue) {
  const date = new Date(dateValue);
  const today = new Date();
  const start = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const target = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const difference = Math.round((start - target) / 86400000);
  if (difference === 0) return 'Today';
  if (difference === 1) return 'Yesterday';
  if (difference < 7) return date.toLocaleDateString(undefined, { weekday: 'long' });
  return date.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

function formatMeetingTime(meeting) {
  const date = new Date(meeting.startedAt);
  const duration = Math.max(0, Number(meeting.durationSeconds) || 0);
  const minutes = Math.floor(duration / 60);
  const seconds = Math.floor(duration % 60);
  return `${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })} · ${minutes}:${String(seconds).padStart(2, '0')}`;
}

function formatMeetingMeta(meeting) {
  const date = new Date(meeting.startedAt);
  const duration = Math.max(0, Number(meeting.durationSeconds) || 0);
  const hours = Math.floor(duration / 3600);
  const minutes = Math.floor((duration % 3600) / 60);
  const seconds = Math.floor(duration % 60);
  const length = hours > 0 ? `${hours} hr ${minutes} min` : minutes > 0 ? `${minutes} min ${seconds} sec` : `${seconds} sec`;
  return `${date.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })} · ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })} · ${length}`;
}

function selectedMeeting() {
  return viewState.meetings.find((meeting) => meeting.id === viewState.selectedId) || null;
}

function statusCopy() {
  const { captureState, zoomState } = viewState.app;
  if (captureState === 'recording') return ['Recording Zoom', 'Video and complete meeting audio are being saved.', 'Stop and save', 'recording'];
  if (captureState === 'starting') return ['Starting recording…', 'Connecting to the active Zoom meeting.', 'Starting…', 'waiting'];
  if (captureState === 'stopping') return ['Saving recording…', 'Finishing the video and audio files safely.', 'Saving…', 'waiting'];
  if (captureState === 'transcribing') return ['Creating transcript…', 'Your audio and video are already saved.', 'Working…', 'waiting'];
  if (captureState === 'failed') return ['Recording needs attention', viewState.app.statusMessage || 'Open MeetMemento to review the issue.', 'Try again', 'waiting'];
  if (zoomState === 'in-meeting') return ['Zoom meeting found', 'Automatic recording will begin in a moment.', 'Record Zoom now', 'waiting'];
  if (zoomState === 'open') return ['Zoom is open', 'Join a meeting and recording will start automatically.', 'Record Zoom now', ''];
  return ['Ready for Zoom', 'MeetMemento is watching for your next Zoom meeting.', 'Record Zoom now', ''];
}

function renderCaptureStatus() {
  const [title, description, button, dotClass] = statusCopy();
  elements.captureTitle.textContent = title;
  elements.captureDescription.textContent = description;
  elements.captureButton.textContent = button;
  elements.captureDot.className = `status-dot ${dotClass}`.trim();
  elements.captureButton.disabled = ['starting', 'stopping', 'transcribing'].includes(viewState.app.captureState);
  elements.emptyRecordButton.disabled = elements.captureButton.disabled;
  elements.statusBanner.hidden = !viewState.app.statusMessage;
  elements.statusBanner.textContent = viewState.app.statusMessage || '';
}

function requestDelete(meeting) {
  if (!meeting) return;
  const accepted = window.confirm(`Move “${meeting.title}” to the Recycle Bin? You can restore it from Recently Deleted.`);
  if (!accepted) return;
  api.deleteMeeting(meeting.id).then(refreshLibrary).catch(showError);
}

function renderMeetingList() {
  elements.meetingCount.textContent = String(viewState.meetings.length);
  elements.meetingList.replaceChildren();
  let currentGroup = '';

  for (const meeting of viewState.meetings) {
    const group = formatDay(meeting.startedAt);
    if (group !== currentGroup) {
      currentGroup = group;
      const heading = document.createElement('div');
      heading.className = 'date-group-label';
      heading.textContent = group;
      elements.meetingList.append(heading);
    }

    const row = document.createElement('div');
    row.className = `meeting-row${meeting.id === viewState.selectedId ? ' active' : ''}`;
    row.tabIndex = 0;
    row.setAttribute('role', 'button');
    row.setAttribute('aria-label', `Open ${meeting.title}`);
    row.innerHTML = `
      <span class="meeting-thumb" aria-hidden="true">▰</span>
      <span class="meeting-copy">
        <span class="meeting-name">${escapeHtml(meeting.title)}</span>
        <span class="meeting-time">${escapeHtml(formatMeetingTime(meeting))}</span>
      </span>
      <button class="quick-delete" type="button" title="Move to Recycle Bin" aria-label="Delete ${escapeHtml(meeting.title)}">×</button>`;
    const select = () => selectMeeting(meeting.id);
    row.addEventListener('click', (event) => {
      if (!event.target.closest('.quick-delete')) select();
    });
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        select();
      }
    });
    row.querySelector('.quick-delete').addEventListener('click', (event) => {
      event.stopPropagation();
      requestDelete(meeting);
    });
    elements.meetingList.append(row);
  }
}

async function selectMeeting(id) {
  viewState.selectedId = id;
  renderMeetingList();
  await renderMeetingDetail();
}

async function renderMeetingDetail() {
  const token = ++viewState.renderingMeeting;
  const meeting = selectedMeeting();
  elements.emptyState.hidden = Boolean(meeting);
  elements.meetingDetail.hidden = !meeting;
  elements.meetingActions.hidden = !meeting;
  if (!meeting) {
    elements.meetingTitle.textContent = 'Your recordings will appear here';
    elements.meetingMeta.textContent = 'Join a Zoom meeting and MeetMemento will begin automatically.';
    return;
  }

  elements.meetingDetail.style.animation = 'none';
  void elements.meetingDetail.offsetHeight;
  elements.meetingDetail.style.animation = '';
  elements.meetingTitle.textContent = meeting.title;
  elements.meetingMeta.textContent = formatMeetingMeta(meeting);
  elements.videoPlayer.pause();
  elements.videoPlayer.removeAttribute('src');
  elements.videoPlayer.load();
  elements.audioPlayer.pause();
  elements.audioPlayer.removeAttribute('src');
  elements.audioPlayer.load();

  const [videoUrl, audioUrl] = await Promise.all([
    meeting.videoFile ? api.meetingFileUrl(meeting.id, 'video') : null,
    meeting.audioFile ? api.meetingFileUrl(meeting.id, 'audio') : null
  ]);
  if (token !== viewState.renderingMeeting) return;

  elements.videoUnavailable.hidden = Boolean(videoUrl);
  elements.videoPlayer.hidden = !videoUrl;
  if (videoUrl) elements.videoPlayer.src = videoUrl;
  elements.audioUnavailable.hidden = Boolean(audioUrl);
  elements.audioPlayer.hidden = !audioUrl;
  if (audioUrl) elements.audioPlayer.src = audioUrl;

  const transcriptStatus = meeting.transcriptionStatus || 'pending';
  elements.transcriptBadge.textContent = transcriptStatus === 'complete' ? 'Ready' : transcriptStatus === 'failed' ? 'Unavailable' : 'Processing';
  elements.transcriptBadge.className = `state-badge ${transcriptStatus}`;
  if (meeting.transcript) {
    elements.transcriptContent.textContent = meeting.transcript;
  } else if (transcriptStatus === 'processing') {
    elements.transcriptContent.innerHTML = '<span class="placeholder">MeetMemento is creating the local transcript. Audio and video are already safe.</span>';
  } else {
    elements.transcriptContent.innerHTML = `<span class="placeholder">${escapeHtml(meeting.errorMessage || 'A transcript could not be created from this recording.')}</span>`;
  }
}

async function refreshLibrary() {
  const meetings = await api.listMeetings();
  viewState.meetings = meetings;
  if (viewState.selectedId && !meetings.some((meeting) => meeting.id === viewState.selectedId)) {
    viewState.selectedId = meetings[0]?.id || null;
  } else if (!viewState.selectedId && meetings.length > 0) {
    viewState.selectedId = meetings[0].id;
  }
  renderMeetingList();
  await renderMeetingDetail();
}

function showError(error) {
  viewState.app.statusMessage = error?.message || String(error);
  renderCaptureStatus();
}

function updateSettingsControls() {
  if (!viewState.settings) return;
  elements.autoRecordSetting.checked = viewState.settings.autoRecord;
  elements.microphoneSetting.checked = viewState.settings.includeMicrophone;
  elements.loginSetting.checked = viewState.settings.launchAtLogin;
}

class CaptureController {
  constructor() {
    this.active = false;
    this.stopping = false;
    this.displayStream = null;
    this.microphoneStream = null;
    this.audioContext = null;
    this.mixBus = null;
    this.mediaDestination = null;
    this.systemAudioSource = null;
    this.systemAnalyser = null;
    this.systemSamples = null;
    this.microphoneSource = null;
    this.silentSource = null;
    this.processor = null;
    this.processorMute = null;
    this.canvasStream = null;
    this.videoRecorder = null;
    this.audioRecorder = null;
    this.sessionId = null;
    this.startedAt = null;
    this.appendQueue = Promise.resolve();
    this.drawTimer = null;
    this.pcmChunks = [];
    this.pcmBytes = 0;
    this.warnings = [];
    this.audioPeak = 0;
    this.systemAudioPeak = 0;
    this.hadSystemAudioTrack = false;
    this.currentSource = null;
    this.sourceReplaceQueue = Promise.resolve();
    this.deviceChangeTimer = null;
    this.deviceListener = () => {
      if (this.deviceChangeTimer) clearTimeout(this.deviceChangeTimer);
      this.deviceChangeTimer = setTimeout(() => this.reconnectAudioDevices(), 800);
    };
  }

  async acquireDisplay(source) {
    await api.prepareCapture(source.id);
    return navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: { ideal: 10, max: 15 }, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: true
    });
  }

  async attachDisplay(stream) {
    const video = elements.captureSourceVideo;
    video.srcObject = stream;
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Zoom video did not become available.')), 10000);
      video.onloadedmetadata = () => { clearTimeout(timeout); resolve(); };
      video.onerror = () => { clearTimeout(timeout); reject(new Error('Zoom video could not be opened.')); };
    });
    await video.play();
    const displayTrack = stream.getVideoTracks()[0];
    if (!displayTrack) throw new Error('Windows did not provide the Zoom video stream.');
    displayTrack.addEventListener('ended', () => {
      if (this.active && !this.stopping) this.warnings.push('Zoom briefly changed or closed its capture window.');
    }, { once: true });
    this.connectSystemAudio(stream);
  }

  connectSystemAudio(stream) {
    if (this.systemAudioSource) {
      try { this.systemAudioSource.disconnect(); } catch { /* already disconnected */ }
      this.systemAudioSource = null;
      this.systemAnalyser = null;
      this.systemSamples = null;
    }
    const tracks = stream.getAudioTracks();
    if (tracks.length === 0) {
      this.warnings.push('Windows loopback audio was unavailable for part of this meeting.');
      return;
    }
    this.hadSystemAudioTrack = true;
    this.systemAudioSource = this.audioContext.createMediaStreamSource(new MediaStream(tracks));
    this.systemAnalyser = this.audioContext.createAnalyser();
    this.systemAnalyser.fftSize = 1024;
    this.systemSamples = new Float32Array(this.systemAnalyser.fftSize);
    this.systemAudioSource.connect(this.mixBus);
    this.systemAudioSource.connect(this.systemAnalyser);
  }

  configureCanvas() {
    const settings = this.displayStream.getVideoTracks()[0].getSettings();
    const sourceWidth = Math.max(640, Number(settings.width) || 1280);
    const sourceHeight = Math.max(360, Number(settings.height) || 720);
    const scale = Math.min(1, 1920 / sourceWidth, 1080 / sourceHeight);
    const canvas = elements.captureCanvas;
    canvas.width = Math.max(2, Math.floor(sourceWidth * scale / 2) * 2);
    canvas.height = Math.max(2, Math.floor(sourceHeight * scale / 2) * 2);
    const context = canvas.getContext('2d', { alpha: false, desynchronized: true });
    const draw = () => {
      context.fillStyle = '#111725';
      context.fillRect(0, 0, canvas.width, canvas.height);
      if (elements.captureSourceVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
        context.drawImage(elements.captureSourceVideo, 0, 0, canvas.width, canvas.height);
      }
      if (this.systemAnalyser) {
        this.systemAnalyser.getFloatTimeDomainData(this.systemSamples);
        for (const sample of this.systemSamples) this.systemAudioPeak = Math.max(this.systemAudioPeak, Math.abs(sample));
      }
    };
    draw();
    this.drawTimer = setInterval(draw, 100);
    this.canvasStream = canvas.captureStream(10);
  }

  configureAudio() {
    this.audioContext = new AudioContext({ latencyHint: 'playback' });
    this.mixBus = this.audioContext.createGain();
    this.mediaDestination = this.audioContext.createMediaStreamDestination();
    this.mixBus.connect(this.mediaDestination);

    this.silentSource = this.audioContext.createConstantSource();
    this.silentSource.offset.value = 0;
    this.silentSource.connect(this.mixBus);
    this.silentSource.start();

    this.processor = this.audioContext.createScriptProcessor(4096, 2, 1);
    this.processorMute = this.audioContext.createGain();
    this.processorMute.gain.value = 0;
    this.mixBus.connect(this.processor);
    this.processor.connect(this.processorMute);
    this.processorMute.connect(this.audioContext.destination);
    this.processor.onaudioprocess = (event) => this.handleAudioProcess(event);
  }

  async openMicrophone(reportFailure = true) {
    if (!viewState.settings.includeMicrophone) return;
    try {
      const next = await navigator.mediaDevices.getUserMedia({
        video: false,
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false }
      });
      if (this.microphoneSource) {
        try { this.microphoneSource.disconnect(); } catch { /* already disconnected */ }
      }
      this.microphoneStream?.getTracks().forEach((track) => track.stop());
      this.microphoneStream = next;
      this.microphoneSource = this.audioContext.createMediaStreamSource(next);
      this.microphoneSource.connect(this.mixBus);
    } catch (error) {
      if (reportFailure) this.warnings.push(`Microphone was not included: ${error.message}`);
    }
  }

  async reopenMicrophone() {
    if (!this.active || this.stopping || !viewState.settings.includeMicrophone) return;
    await this.openMicrophone(false);
  }

  async reconnectAudioDevices() {
    if (!this.active || this.stopping) return;
    await this.reopenMicrophone();
    if (this.currentSource) await this.replaceSource(this.currentSource, false);
  }

  handleAudioProcess(event) {
    if (!this.active || this.stopping || !this.sessionId) return;
    const input = event.inputBuffer;
    const mono = new Float32Array(input.length);
    for (let channel = 0; channel < input.numberOfChannels; channel += 1) {
      const data = input.getChannelData(channel);
      for (let index = 0; index < data.length; index += 1) mono[index] += data[index] / input.numberOfChannels;
    }
    const pcm = downsampleToPcm16(mono, input.sampleRate, 16000);
    for (const sample of mono) this.audioPeak = Math.max(this.audioPeak, Math.abs(sample));
    this.pcmChunks.push(new Uint8Array(pcm.buffer));
    this.pcmBytes += pcm.byteLength;
    if (this.pcmBytes >= 32000) this.flushPcm();
  }

  flushPcm() {
    if (!this.sessionId || this.pcmBytes === 0) return;
    const combined = new Uint8Array(this.pcmBytes);
    let offset = 0;
    for (const chunk of this.pcmChunks) {
      combined.set(chunk, offset);
      offset += chunk.byteLength;
    }
    this.pcmChunks = [];
    this.pcmBytes = 0;
    const sessionId = this.sessionId;
    this.appendQueue = this.appendQueue.then(() => api.appendPcm(sessionId, combined.buffer));
  }

  mimeType(candidates) {
    return candidates.find((candidate) => MediaRecorder.isTypeSupported(candidate)) || '';
  }

  recordStream(stream, kind, options = {}) {
    const recorder = new MediaRecorder(stream, options);
    recorder.addEventListener('dataavailable', (event) => {
      if (!event.data || event.data.size === 0 || !this.sessionId) return;
      this.appendQueue = this.appendQueue.then(async () => {
        const data = await event.data.arrayBuffer();
        await api.appendChunk(this.sessionId, kind, data);
      });
    });
    recorder.addEventListener('error', (event) => {
      this.warnings.push(`${kind === 'video' ? 'Video' : 'Audio'} recorder reported: ${event.error?.message || 'unknown error'}`);
    });
    recorder.start(1000);
    return recorder;
  }

  async start(payload) {
    if (this.active || this.stopping) return;
    this.active = true;
    this.warnings = [];
    this.audioPeak = 0;
    this.systemAudioPeak = 0;
    this.hadSystemAudioTrack = false;
    this.startedAt = new Date();
    this.currentSource = payload.source;
    try {
      this.configureAudio();
      this.displayStream = await this.acquireDisplay(payload.source);
      await this.attachDisplay(this.displayStream);
      this.configureCanvas();
      await this.openMicrophone(true);
      if (this.audioContext.state === 'suspended') await this.audioContext.resume();

      const session = await api.createRecording({
        title: payload.title,
        sourceName: payload.source.name,
        startedAt: this.startedAt.toISOString()
      });
      this.sessionId = session.id;

      const audioTracks = this.mediaDestination.stream.getAudioTracks();
      const videoStream = new MediaStream([...this.canvasStream.getVideoTracks(), ...audioTracks]);
      const audioStream = new MediaStream(audioTracks);
      const videoMime = this.mimeType(['video/webm;codecs=vp8,opus', 'video/webm;codecs=vp9,opus', 'video/webm']);
      const audioMime = this.mimeType(['audio/webm;codecs=opus', 'audio/webm']);
      this.videoRecorder = this.recordStream(videoStream, 'video', {
        ...(videoMime ? { mimeType: videoMime } : {}),
        videoBitsPerSecond: 3500000,
        audioBitsPerSecond: 128000
      });
      this.audioRecorder = this.recordStream(audioStream, 'audio', {
        ...(audioMime ? { mimeType: audioMime } : {}),
        audioBitsPerSecond: 128000
      });
      navigator.mediaDevices.addEventListener('devicechange', this.deviceListener);
    } catch (error) {
      await this.cleanup();
      this.active = false;
      api.captureFailed(`Recording could not start: ${error.message}`);
    }
  }

  replaceSource(payload, rememberSource = true) {
    this.sourceReplaceQueue = this.sourceReplaceQueue.then(() => this.performSourceReplacement(payload, rememberSource));
    return this.sourceReplaceQueue;
  }

  async performSourceReplacement(payload, rememberSource = true) {
    if (!this.active || this.stopping) return;
    let nextStream;
    const previous = this.displayStream;
    try {
      nextStream = await this.acquireDisplay(payload);
      await this.attachDisplay(nextStream);
      this.displayStream = nextStream;
      if (rememberSource) this.currentSource = payload;
      previous?.getTracks().forEach((track) => track.stop());
    } catch (error) {
      nextStream?.getTracks().forEach((track) => track.stop());
      if (previous) {
        elements.captureSourceVideo.srcObject = previous;
        this.connectSystemAudio(previous);
        try { await elements.captureSourceVideo.play(); } catch { /* the next Zoom detection will retry */ }
      }
      this.warnings.push(`Zoom changed windows, but the new window could not be attached: ${error.message}`);
    }
  }

  stopRecorder(recorder) {
    if (!recorder || recorder.state === 'inactive') return Promise.resolve();
    return new Promise((resolve) => {
      recorder.addEventListener('stop', resolve, { once: true });
      recorder.stop();
    });
  }

  async stop(payload = {}) {
    if (!this.active || this.stopping) return;
    this.stopping = true;
    try {
      await Promise.all([this.stopRecorder(this.videoRecorder), this.stopRecorder(this.audioRecorder)]);
      this.flushPcm();
      await this.appendQueue;
      const durationSeconds = this.startedAt ? (Date.now() - this.startedAt.getTime()) / 1000 : 0;
      if (durationSeconds >= 5 && this.audioPeak < 0.001) {
        this.warnings.push('No audible signal was detected in the saved audio.');
      } else if (durationSeconds >= 10 && this.hadSystemAudioTrack && this.systemAudioPeak < 0.0005) {
        this.warnings.push('Windows provided a system-audio track, but no audible Zoom output was detected.');
      }
      const sessionId = this.sessionId;
      const details = {
        endedAt: new Date().toISOString(),
        warnings: [...new Set(this.warnings)],
        errorMessage: null
      };
      await this.cleanup();
      if (sessionId) await api.finishRecording(sessionId, details);
      await refreshLibrary();
    } catch (error) {
      try { await this.cleanup(); } catch { /* preserve the original finalization error */ }
      api.captureFailed(`Recording could not be finalized safely: ${error.message}`);
    } finally {
      this.sessionId = null;
      this.active = false;
      this.stopping = false;
    }
  }

  async cleanup() {
    navigator.mediaDevices.removeEventListener('devicechange', this.deviceListener);
    if (this.deviceChangeTimer) clearTimeout(this.deviceChangeTimer);
    this.deviceChangeTimer = null;
    if (this.drawTimer) clearInterval(this.drawTimer);
    this.drawTimer = null;
    this.processor && (this.processor.onaudioprocess = null);
    try { this.systemAudioSource?.disconnect(); } catch { /* no-op */ }
    try { this.systemAnalyser?.disconnect(); } catch { /* no-op */ }
    try { this.microphoneSource?.disconnect(); } catch { /* no-op */ }
    try { this.processor?.disconnect(); } catch { /* no-op */ }
    try { this.processorMute?.disconnect(); } catch { /* no-op */ }
    try { this.mixBus?.disconnect(); } catch { /* no-op */ }
    try { this.silentSource?.stop(); } catch { /* no-op */ }
    for (const stream of [this.displayStream, this.microphoneStream, this.canvasStream]) {
      stream?.getTracks().forEach((track) => track.stop());
    }
    elements.captureSourceVideo.pause();
    elements.captureSourceVideo.srcObject = null;
    if (this.audioContext && this.audioContext.state !== 'closed') await this.audioContext.close();
    this.displayStream = null;
    this.microphoneStream = null;
    this.canvasStream = null;
    this.audioContext = null;
    this.currentSource = null;
  }
}

function downsampleToPcm16(input, sourceRate, targetRate) {
  const ratio = sourceRate / targetRate;
  const outputLength = Math.max(1, Math.floor(input.length / ratio));
  const output = new Int16Array(outputLength);
  for (let outputIndex = 0; outputIndex < outputLength; outputIndex += 1) {
    const start = Math.floor(outputIndex * ratio);
    const end = Math.max(start + 1, Math.min(input.length, Math.floor((outputIndex + 1) * ratio)));
    let total = 0;
    for (let inputIndex = start; inputIndex < end; inputIndex += 1) total += input[inputIndex];
    const sample = Math.max(-1, Math.min(1, total / (end - start)));
    output[outputIndex] = sample < 0 ? Math.round(sample * 32768) : Math.round(sample * 32767);
  }
  return output;
}

const capture = new CaptureController();

async function beginSetup() {
  if (!elements.setupConsent.checked) {
    elements.setupProgress.hidden = false;
    elements.setupProgress.className = 'setup-progress error';
    elements.setupProgress.textContent = 'Please confirm that you will follow your local recording and consent requirements.';
    return;
  }
  elements.finishSetup.disabled = true;
  elements.setupProgress.hidden = false;
  elements.setupProgress.className = 'setup-progress';
  elements.setupProgress.textContent = 'Checking Windows audio and transcript support…';
  let micMessage = '';
  if (elements.setupMicrophone.checked) {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      stream.getTracks().forEach((track) => track.stop());
      micMessage = ' Microphone access is ready.';
    } catch {
      micMessage = ' Microphone access is off; computer audio will still be recorded.';
    }
  }
  const speech = await api.probeSpeech();
  const transcriptMessage = speech.available
    ? ` Local transcripts are ready${speech.languages?.length ? ` (${speech.languages.join(', ')})` : ''}.`
    : ' Audio and video are ready. Install a Windows speech language later if you want local transcripts.';
  viewState.settings = await api.completeOnboarding({
    autoRecord: elements.setupAutoRecord.checked,
    includeMicrophone: elements.setupMicrophone.checked,
    launchAtLogin: elements.setupLogin.checked,
    speechLanguage: speech.languages?.includes('en-US') ? 'en-US' : speech.languages?.[0] || 'en-US'
  });
  elements.setupProgress.textContent = `${micMessage}${transcriptMessage}`.trim();
  updateSettingsControls();
  setTimeout(() => {
    elements.onboarding.hidden = true;
    elements.app.hidden = false;
  }, 700);
}

async function updateSetting(key, checked) {
  viewState.settings = await api.updateSettings({ [key]: checked });
  updateSettingsControls();
}

async function initialize() {
  const initial = await api.getState();
  viewState.app = initial.app;
  viewState.settings = initial.settings;
  viewState.meetings = initial.meetings;
  viewState.selectedId = initial.meetings[0]?.id || null;
  elements.app.hidden = !initial.settings.onboardingCompleted;
  elements.onboarding.hidden = initial.settings.onboardingCompleted;
  updateSettingsControls();
  renderCaptureStatus();
  renderMeetingList();
  await renderMeetingDetail();
}

elements.captureButton.addEventListener('click', () => {
  if (viewState.app.captureState === 'recording') api.stopRecording();
  else api.startManualRecording().catch(showError);
});
elements.emptyRecordButton.addEventListener('click', () => api.startManualRecording().catch(showError));
elements.openRecycleBin.addEventListener('click', () => api.openRecycleBin());
elements.openSettings.addEventListener('click', () => elements.settingsDialog.showModal());
elements.openRecordingsFolder.addEventListener('click', () => api.openRecordings());
elements.finishSetup.addEventListener('click', beginSetup);
elements.autoRecordSetting.addEventListener('change', (event) => updateSetting('autoRecord', event.target.checked));
elements.microphoneSetting.addEventListener('change', (event) => updateSetting('includeMicrophone', event.target.checked));
elements.loginSetting.addEventListener('change', (event) => updateSetting('launchAtLogin', event.target.checked));
elements.checkSpeech.addEventListener('click', async () => {
  elements.speechStatus.textContent = 'Checking Windows speech support…';
  const result = await api.probeSpeech();
  elements.speechStatus.textContent = result.available
    ? `Local transcript support is ready${result.languages?.length ? `: ${result.languages.join(', ')}` : '.'}`
    : `${result.message || 'No Windows speech language was found.'} Use Windows Settings → Time & language → Speech to install one.`;
});
elements.renameMeeting.addEventListener('click', async () => {
  const meeting = selectedMeeting();
  if (!meeting) return;
  const title = window.prompt('Meeting name', meeting.title)?.trim();
  if (!title || title === meeting.title) return;
  await api.renameMeeting(meeting.id, title);
  await refreshLibrary();
});
elements.exportMeeting.addEventListener('click', async () => {
  const meeting = selectedMeeting();
  if (!meeting) return;
  const destination = await api.exportMeeting(meeting.id);
  if (destination) {
    viewState.app.statusMessage = `Video, audio, and transcript copied to ${destination}`;
    renderCaptureStatus();
  }
});
elements.deleteMeeting.addEventListener('click', () => requestDelete(selectedMeeting()));
elements.openMeetingFolder.addEventListener('click', () => {
  const meeting = selectedMeeting();
  if (meeting) api.openRecordingFolder(meeting.id);
});

for (const element of [elements.videoPlayer, elements.videoUnavailable]) {
  element.addEventListener('wheel', (event) => {
    event.preventDefault();
    event.stopPropagation();
    elements.detailPane.scrollBy({ top: event.deltaY || event.deltaX, behavior: 'auto' });
  }, { passive: false });
}

if (api) {
  api.onCaptureStart((payload) => capture.start(payload));
  api.onCaptureStop((payload) => capture.stop(payload));
  api.onCaptureSourceChanged((payload) => capture.replaceSource(payload));
  api.onStateChanged((state) => {
    viewState.app = state;
    renderCaptureStatus();
  });
  api.onLibraryChanged(() => refreshLibrary().catch(showError));
  initialize().catch(showError);
} else {
  elements.onboarding.hidden = false;
}
