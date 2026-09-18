'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_SETTINGS = Object.freeze({
  autoRecord: true,
  includeMicrophone: true,
  launchAtLogin: true,
  consentAcknowledged: false,
  onboardingCompleted: false,
  speechLanguage: 'en-US'
});

function writeJsonAtomic(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(temporaryPath, filePath);
}

class SettingsStore {
  constructor(filePath) {
    this.filePath = filePath;
    this.settings = this.#load();
  }

  #load() {
    try {
      const stored = JSON.parse(fs.readFileSync(this.filePath, 'utf8'));
      return { ...DEFAULT_SETTINGS, ...stored };
    } catch {
      return { ...DEFAULT_SETTINGS };
    }
  }

  get() {
    return { ...this.settings };
  }

  update(patch) {
    const allowed = Object.keys(DEFAULT_SETTINGS);
    const safePatch = Object.fromEntries(
      Object.entries(patch || {}).filter(([key]) => allowed.includes(key))
    );
    this.settings = { ...this.settings, ...safePatch };
    writeJsonAtomic(this.filePath, this.settings);
    return this.get();
  }
}

module.exports = { DEFAULT_SETTINGS, SettingsStore, writeJsonAtomic };
