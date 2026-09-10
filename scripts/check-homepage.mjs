import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {scenes, initialScene, sceneAsset} from '../docs/scenes.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../docs');
const html = readFileSync(resolve(root, 'index.html'), 'utf8');
assert.equal((html.match(/data-scene-view=/g) || []).length, 3);
assert.equal((html.match(/<h1>/g) || []).length, 1);
assert.ok(html.includes('#install'));
assert.ok(!html.includes('Not notarized'));
assert.ok(!html.includes('Different album.'));
assert.ok(!html.includes('prototype-nav'));
for (let i = 0; i < scenes.length; i++) {
  assert.equal(initialScene(() => (i + .5) / scenes.length), i);
  for (const view of ['nps', 'home', 'album']) assert.ok(existsSync(resolve(root, sceneAsset(i, view))));
}
for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
  if (!match[1].startsWith('https:')) assert.ok(existsSync(resolve(root, match[1])), `Missing ${match[1]}`);
}
for (const file of ['site.mjs', 'scenes.mjs']) {
  const result = spawnSync(process.execPath, ['--check', resolve(root, file)], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
}
const script = readFileSync(resolve(root, 'site.mjs'), 'utf8');
assert.ok(script.includes('let paused = false;'));
assert.ok(script.includes('animate && !reducedMotion.matches'));
console.log('Homepage checks passed: 12 screenshots, random initial theme, three coordinated views, automatic playback default, local references, and JavaScript syntax.');
