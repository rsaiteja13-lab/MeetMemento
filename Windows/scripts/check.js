'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const required = [
  'package.json',
  'src/main.js',
  'src/preload.js',
  'src/renderer/index.html',
  'src/renderer/styles.css',
  'src/renderer/renderer.js',
  'resources/transcribe.ps1',
  'resources/icon.png'
];

for (const relativePath of required) {
  if (!fs.existsSync(path.join(root, relativePath))) throw new Error(`Missing required Windows app file: ${relativePath}`);
}

const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const lockfileText = fs.readFileSync(path.join(root, 'package-lock.json'), 'utf8');
if (/oraclecorp|artifacthub/i.test(lockfileText)) throw new Error('The Windows lockfile contains a private registry URL.');
const packagedFiles = packageJson.build?.files || [];
if (JSON.stringify(packagedFiles) !== JSON.stringify(['src/**/*', 'package.json'])) {
  throw new Error('The Windows package must use the reviewed source-only allowlist.');
}
const resources = packageJson.build?.extraResources || [];
if (resources.length !== 1 || resources[0].from !== 'resources/transcribe.ps1') {
  throw new Error('The Windows package must include only the local transcription helper as an extra resource.');
}

const javascriptFiles = [];
function collect(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === 'dist') continue;
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) collect(entryPath);
    else if (entry.name.endsWith('.js')) javascriptFiles.push(entryPath);
  }
}
collect(path.join(root, 'src'));
collect(path.join(root, 'scripts'));
collect(path.join(root, 'tests'));
for (const filePath of javascriptFiles) execFileSync(process.execPath, ['--check', filePath], { stdio: 'pipe' });

const html = fs.readFileSync(path.join(root, 'src/renderer/index.html'), 'utf8');
if (!html.includes("default-src 'self'")) throw new Error('The renderer Content Security Policy is missing.');
if (/<script(?![^>]*src=)/i.test(html)) throw new Error('Inline scripts are not allowed.');
const htmlIds = [...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]);
if (new Set(htmlIds).size !== htmlIds.length) throw new Error('The Windows interface contains duplicate element IDs.');
const renderer = fs.readFileSync(path.join(root, 'src/renderer/renderer.js'), 'utf8');
const elementBlock = renderer.match(/Object\.fromEntries\(\[([\s\S]*?)\]\.map/);
if (!elementBlock) throw new Error('The renderer element map could not be verified.');
for (const match of elementBlock[1].matchAll(/'([^']+)'/g)) {
  if (!htmlIds.includes(match[1])) throw new Error(`The renderer references a missing interface element: ${match[1]}`);
}

const main = fs.readFileSync(path.join(root, 'src/main.js'), 'utf8');
for (const expected of ['contextIsolation: true', 'nodeIntegration: false', 'sandbox: true', "audio: 'loopback'"]) {
  if (!main.includes(expected)) throw new Error(`Required security or capture setting is missing: ${expected}`);
}

const forbiddenExtensions = new Set(['.mp3', '.m4a', '.wav', '.mp4', '.mov', '.webm', '.mkv']);
function inspectTree(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === 'dist') continue;
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) inspectTree(entryPath);
    else if (forbiddenExtensions.has(path.extname(entry.name).toLowerCase())) {
      throw new Error(`A recording-like file is present in the distributable source tree: ${path.relative(root, entryPath)}`);
    }
  }
}
inspectTree(root);

process.stdout.write(`Windows checks passed (${javascriptFiles.length} JavaScript files, safe package allowlist).\n`);
