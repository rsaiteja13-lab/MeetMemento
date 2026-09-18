'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { SettingsStore } = require('../src/lib/settings-store');

test('persists settings and ignores unknown properties', (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'meetmemento-settings-'));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filePath = path.join(directory, 'settings.json');
  const store = new SettingsStore(filePath);
  assert.equal(store.get().autoRecord, true);
  store.update({ autoRecord: false, untrustedSetting: 'ignored' });
  const restored = new SettingsStore(filePath).get();
  assert.equal(restored.autoRecord, false);
  assert.equal(Object.hasOwn(restored, 'untrustedSetting'), false);
});
