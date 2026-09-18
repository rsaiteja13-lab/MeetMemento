'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { formatTranscript } = require('./transcript-format');

function runPowerShell(scriptPath, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      ...args
    ], { windowsHide: true });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.once('error', reject);
    child.once('close', (code) => {
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(stderr.trim() || stdout.trim() || `Windows speech recognition exited with code ${code}.`));
    });
  });
}

class TranscriptService {
  constructor(scriptPath) {
    this.scriptPath = scriptPath;
  }

  async probe() {
    if (process.platform !== 'win32') {
      return { available: false, languages: [], message: 'Windows speech recognition can only be checked on Windows.' };
    }
    try {
      const output = await runPowerShell(this.scriptPath, ['-Probe']);
      return JSON.parse(output);
    } catch (error) {
      return { available: false, languages: [], message: error.message };
    }
  }

  async transcribe(wavPath, folderPath, language = 'en-US') {
    const resultPath = path.join(folderPath, 'transcription-result.json');
    await runPowerShell(this.scriptPath, [
      '-InputPath', wavPath,
      '-OutputPath', resultPath,
      '-Language', language
    ]);
    const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
    fs.rmSync(resultPath, { force: true });
    if (result.status !== 'complete' || !Array.isArray(result.segments) || result.segments.length === 0) {
      return {
        status: 'failed',
        transcript: '',
        language: result.language || language,
        error: result.error || 'Windows did not detect speech in the saved audio.'
      };
    }
    const transcript = formatTranscript(result.segments);
    fs.writeFileSync(path.join(folderPath, 'transcript.txt'), `${transcript}\n`, 'utf8');
    return { status: 'complete', transcript, language: result.language || language, error: null };
  }
}

module.exports = { TranscriptService, runPowerShell };
