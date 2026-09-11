import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {scenes, initialScene, sceneAsset} from '../docs/scenes.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../docs');
const html = readFileSync(resolve(root, 'index.html'), 'utf8');
assert.equal((html.match(/<div class="app-capture[^"]*" data-scene-view=/g) || []).length, 3);
assert.equal((html.match(/<h1>/g) || []).length, 1);
assert.ok(html.includes('#install'));
assert.ok(!html.includes('Not notarized'));
assert.ok(!html.includes('Different album.'));
assert.ok(!html.includes('prototype-nav'));
assert.ok(html.includes("document.documentElement.dataset.initialScene = String(index)"));
assert.ok(html.includes("document.documentElement.classList.add('scene-pending')"));
assert.equal((html.match(/\.scene-pending \[data-scene-view=/g) || []).length, 3);
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
const bootstrap = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(bootstrap);
const bootstrapCheck = spawnSync(process.execPath, ['--check'], {input: bootstrap, encoding: 'utf8'});
assert.equal(bootstrapCheck.status, 0, bootstrapCheck.stderr);
const script = readFileSync(resolve(root, 'site.mjs'), 'utf8');
assert.ok(script.includes('let paused = false;'));
assert.ok(script.includes('animate && !reducedMotion.matches'));
assert.ok(script.includes('Number(document.documentElement.dataset.initialScene)'));
assert.ok(script.includes("classList.remove('scene-pending')"));
console.log('Homepage checks passed: 12 screenshots, preselected random initial theme, three coordinated views, automatic playback default, local references, and JavaScript syntax.');
