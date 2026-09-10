import assert from 'node:assert/strict';
import {readFileSync, existsSync, readdirSync, statSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {studies, scenes, views} from './dist/data.js';
import {renderLayout} from './dist/layouts.js';

const project = dirname(fileURLToPath(import.meta.url));
const root = resolve(project, 'dist');
const documents = ['index.html', 'concept.html'].map(file => readFileSync(resolve(root, file), 'utf8'));
assert.equal(studies.length, 8);
assert.equal(new Set(studies.map(study => study.id)).size, 8);
assert.equal(scenes.length, 4);
assert.equal(views.length, 3);

for (const study of studies) {
  const markup = renderLayout(study.id);
  assert.equal((markup.match(/<main\b/g) || []).length, 1, `${study.name}: one main surface`);
  assert.equal((markup.match(/<h1\b/g) || []).length, 1, `${study.name}: one main heading`);
  assert.ok(markup.includes('/releases/latest'), `${study.name}: download link`);
  assert.ok(markup.includes('#install'), `${study.name}: installation help`);
  assert.ok(markup.includes('Not notarized'), `${study.name}: current installation caveat`);
  assert.ok(markup.includes('OpenSubsonic'), `${study.name}: server compatibility`);
  assert.ok(markup.includes('macOS 26'), `${study.name}: minimum macOS version`);
  assert.ok(markup.includes('Apple silicon'), `${study.name}: processor requirement`);
  documents.push(markup);
}

const assetReferences = new Set(scenes.map(scene => `assets/${scene.file}`).concat(views.map(view => `assets/${view.file}`)));
for (const markup of documents) {
  for (const match of markup.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const ref = match[1];
    if (/^https:\/\//.test(ref)) {
      assert.ok(ref.startsWith('https://github.com/iamtoolino/coda-macos'), `Unexpected external link: ${ref}`);
    } else if (!ref.startsWith('#')) {
      assetReferences.add(ref.split('?')[0]);
    }
  }
  for (const match of markup.matchAll(/<img\b[^>]*>/g)) assert.ok(/\balt="/.test(match[0]), 'Every screenshot needs alternative text');
  assert.ok(!markup.includes('undefined'), 'Unresolved template value');
}
for (const ref of assetReferences) {
  const path = resolve(root, ref);
  assert.ok(path.startsWith(root + '/'), `Local reference escapes the site: ${ref}`);
  assert.ok(existsSync(path) && statSync(path).isFile(), `Missing local asset: ${ref}`);
}
for (const file of readdirSync(root).filter(file => file.endsWith('.js'))) {
  const result = spawnSync(process.execPath, ['--check', resolve(root, file)], {encoding: 'utf8'});
  assert.equal(result.status, 0, `${file}: ${result.stderr}`);
}
const css = readFileSync(resolve(root, 'styles.css'), 'utf8');
for (const id of [2, 4, 5, 6, 7, 8]) assert.ok(css.includes(`.concept-${id}`), `Missing distinct concept ${id} styling`);
assert.ok(css.includes('prefers-reduced-motion'));
assert.ok(css.includes('max-width: 720px'));
assert.equal(JSON.parse(readFileSync(resolve(project, '.openai/hosting.json'))).static.directory, 'dist');
console.log(`Validated 8 layouts, 4 album scenes, 3 product views, ${assetReferences.size} local references, and all JavaScript modules.`);
console.log('Static checks only. Human comparison should include wide desktop, narrow laptop, and phone widths, motion controls, sleeve selection, and the three-view walkthrough.');
