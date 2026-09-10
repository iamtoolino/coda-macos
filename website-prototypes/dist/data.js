export const repo = 'https://github.com/iamtoolino/coda-macos';
export const studies = [
  {id: 1, name: 'Native showroom', mood: 'Clear. Familiar. Quietly polished.', description: 'A classic product page, with room for the app to speak.', effort: 'Low'},
  {id: 2, name: 'Sleeve notes', mood: 'An editorial listening issue.', description: 'A narrow typographic margin beside an oversized app window.', effort: 'Medium'},
  {id: 3, name: 'Living window', mood: 'Four albums. Four atmospheres.', description: 'A calm looping showcase; the page follows the album.', effort: 'High'},
  {id: 4, name: 'Choose a sleeve', mood: 'A small invitation to explore.', description: 'Choose an album and change the room yourself.', effort: 'High'},
  {id: 5, name: 'Listening room', mood: 'The app becomes the whole scene.', description: 'An immersive opening with almost no surrounding copy.', effort: 'Extra high'},
  {id: 6, name: 'Product poster', mood: 'One composition. Nothing extra.', description: 'A compact product portrait with three inspectable views.', effort: 'Low'},
  {id: 7, name: 'Open contact sheet', mood: 'One player, seen in different lights.', description: 'One complete window and two carefully framed glimpses.', effort: 'Max'},
  {id: 8, name: 'One album, three moments', mood: 'From finding to listening.', description: 'A three-still walkthrough of choosing an album and settling in.', effort: 'Medium'},
];
export const scenes = [
  {id: 'sigh', file: 'sigh.png', artist: 'Sigh', album: 'Goh-Ka', color: '34, 118, 126', light: '#74c1c6'},
  {id: 'satriani', file: 'satriani.png', artist: 'Joe Satriani', album: 'The Elephants of Mars', color: '91, 48, 131', light: '#b194d3'},
  {id: 'shadow', file: 'shadow.png', artist: 'Shadow of Intent', album: 'Imperium Delirium', color: '50, 100, 62', light: '#9bbf90'},
  {id: 'pizza', file: 'pizza.png', artist: 'Samurai Pizza Cats', album: 'Press Start', color: '132, 47, 103', light: '#d692bf'},
];
export const views = [
  {id: 'now', file: 'sigh.png', label: 'Now Playing', kind: 'nps'},
  {id: 'home', file: 'home.png', label: 'Browse', kind: 'library'},
  {id: 'album', file: 'album.png', label: 'Album', kind: 'library'},
];
export function sceneAsset(index, view = 'nps') {
  return view === 'nps' ? scenes[index].file : `${scenes[index].id}-${view}.png`;
}
export function themedCapture(index, view) {
  const scene = scenes[index];
  return `<div class="app-capture matched" data-scene-frame data-scene-view="${view}"><img src="assets/${sceneAsset(index, view)}" alt="Coda ${view === 'home' ? 'Home' : 'Album'} view with the ${scene.album} color theme." width="2060" height="1606" loading="lazy" decoding="async"></div>`;
}
export function sceneImage(index = 0, extra = '') {
  const scene = scenes[index];
  return `<div class="app-capture nps ${extra}" data-scene-frame><img src="assets/${scene.file}" alt="Coda Now Playing: ${scene.album} by ${scene.artist}, with the listening queue visible." width="1836" height="1572" decoding="async"></div>`;
}
export function capture(file, label, extra = '') {
  return `<div class="app-capture library ${extra}"><img src="assets/${file}" alt="${label}" width="2246" height="1730" loading="lazy" decoding="async"></div>`;
}
export function sleeve(index) {
  return `<span class="sleeve-art"><img src="assets/${scenes[index].file}" alt="" width="1836" height="1572" loading="lazy"></span>`;
}
export function download(text = 'Download for Mac') {
  return `<a class="download" href="${repo}/releases/latest" target="_blank" rel="noopener">${text}<span aria-hidden="true">↓</span></a>`;
}
export function header(showDownload = false) {
  return `<header class="site-header"><a class="brand" href="index.html"><img src="assets/CodaAppIcon.svg" alt="" width="34" height="34">Coda</a><nav aria-label="Coda links"><a href="${repo}" target="_blank" rel="noopener">GitHub</a>${showDownload ? download() : ''}</nav></header>`;
}
export function footer() {
  return `<footer class="site-footer"><span>Free & open source.<br><span class="secondary">An independent community project.</span></span><span class="footer-links"><a href="${repo}#install" target="_blank" rel="noopener">Installation help <span class="secondary">· Not notarized</span></a><a href="${repo}" target="_blank" rel="noopener">Source on GitHub</a></span></footer>`;
}
export function requirements() { return '<p class="requirements">macOS 26+ · Apple silicon · Your own music server</p>'; }
export function sceneControls() {
  return `<div class="scene-controls"><span class="scene-caption" data-scene-caption>Sigh <span>— Goh-Ka</span></span><div class="scene-actions"><div class="scene-dots" aria-label="Choose a preview scene">${scenes.map((s, i) => `<button type="button" data-scene="${i}" aria-label="Show ${s.album} by ${s.artist}" aria-pressed="${i === 0}"><span></span></button>`).join('')}</div><button class="motion-button" type="button" data-motion aria-pressed="false">Pause preview</button></div></div>`;
}
