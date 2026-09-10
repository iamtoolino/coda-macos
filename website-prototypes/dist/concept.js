import {studies, scenes, views, sceneAsset, sceneImage, capture} from './data.js';
import {renderLayout} from './layouts.js';

const params = new URLSearchParams(location.search);
const id = Math.min(8, Math.max(1, Number(params.get('v')) || 1));
const study = studies.find(item => item.id === id) || studies[0];
document.title = `Coda — ${study.name}`;
document.body.className = `concept concept-${study.id}${params.has('embed') ? ' embedded' : ''}`;
document.body.style.setProperty('--scene-rgb', scenes[0].color);
document.body.style.setProperty('--scene-light', scenes[0].light);
if (!params.has('embed')) document.querySelector('#prototype-nav').innerHTML = `<nav class="prototype-bar" aria-label="Design study navigation"><a href="index.html">← All eight studies</a><span>${String(study.id).padStart(2, '0')} / 08 <b>${study.name}</b></span><div><a href="concept.html?v=${study.id === 1 ? 8 : study.id - 1}" aria-label="Previous study">←</a><a href="concept.html?v=${study.id === 8 ? 1 : study.id + 1}" aria-label="Next study">→</a></div></nav>`;

const still = params.has('still');
const coordinated = [2, 3].includes(study.id);
let sceneIndex = coordinated && !still ? Math.floor(Math.random() * scenes.length) : study.id === 8 ? 3 : 0;
document.querySelector('#app').innerHTML = renderLayout(study.id, sceneIndex);

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const autoScenes = [1, 2, 3, 5].includes(study.id) && !still;
let userPaused = reducedMotion.matches || !autoScenes;
let inView = true;
let sceneTimer;
let imageRequest = 0;
let firstScene = true;

function setPalette(index) {
  document.body.style.setProperty('--scene-rgb', scenes[index].color);
  document.body.style.setProperty('--scene-light', scenes[index].light);
}
setPalette(sceneIndex);

function updateMotionButton() {
  document.querySelectorAll('[data-motion]').forEach(button => {
    button.textContent = userPaused ? 'Play preview' : 'Pause preview';
    button.setAttribute('aria-pressed', String(userPaused));
  });
}

function scheduleScene() {
  clearTimeout(sceneTimer);
  if (!autoScenes || userPaused || !inView || document.hidden) return;
  sceneTimer = setTimeout(async () => {
    firstScene = false;
    await selectScene((sceneIndex + 1) % scenes.length);
    scheduleScene();
  }, firstScene ? 3500 : 6500);
}

async function selectScene(index) {
  const frames = [...document.querySelectorAll('[data-scene-frame]')];
  if (!frames.length || !scenes[index]) return;
  const ticket = ++imageRequest;
  let prepared;
  try {
    prepared = await Promise.all(frames.map(async frame => {
      const view = frame.dataset.sceneView || 'nps';
      const next = view === 'nps' ? new Image(1836, 1572) : new Image(2060, 1606);
      next.src = `assets/${sceneAsset(index, view)}`;
      next.alt = `Coda ${view === 'nps' ? 'Now Playing' : view === 'home' ? 'Home' : 'Album'} view with the ${scenes[index].album} color theme.`;
      await next.decode();
      return {frame, next};
    }));
  } catch { return; }
  if (ticket !== imageRequest) return;
  // Decode the whole theme before committing any frame, keeping all views in sync.
  setPalette(index);
  sceneIndex = index;
  document.querySelectorAll('[data-scene]').forEach(button => button.setAttribute('aria-pressed', String(Number(button.dataset.scene) === index)));
  document.querySelectorAll('[data-scene-caption]').forEach(label => label.textContent = `${scenes[index].artist} — ${scenes[index].album}`);
  await Promise.all(prepared.map(async ({frame, next}) => {
    const previous = [...frame.children];
    next.style.opacity = '0';
    frame.append(next);
    if (!reducedMotion.matches && !still) {
      const animation = next.animate([{opacity: 0}, {opacity: 1}], {duration: 850, easing: 'ease-in-out', fill: 'forwards'});
      await animation.finished.catch(() => {});
      next.style.opacity = '1';
      animation.cancel();
    } else next.style.opacity = '1';
    previous.forEach(image => image.remove());
  }));
}

document.querySelectorAll('[data-scene]').forEach(button => button.addEventListener('click', () => {
  userPaused = true;
  clearTimeout(sceneTimer);
  updateMotionButton();
  selectScene(Number(button.dataset.scene));
}));
document.querySelectorAll('[data-motion]').forEach(button => button.addEventListener('click', () => {
  userPaused = !userPaused;
  updateMotionButton();
  scheduleScene();
}));

if (autoScenes) {
  const visibleFrames = new Set();
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => entry.isIntersecting ? visibleFrames.add(entry.target) : visibleFrames.delete(entry.target));
    const nowInView = visibleFrames.size > 0;
    if (nowInView !== inView) { inView = nowInView; scheduleScene(); }
  }, {threshold: .12});
  document.querySelectorAll('[data-scene-frame]').forEach(frame => observer.observe(frame));
}

document.addEventListener('visibilitychange', scheduleScene);
reducedMotion.addEventListener('change', () => {
  if (reducedMotion.matches) {
    userPaused = true;
    stopWalkthrough();
  }
  updateMotionButton();
  scheduleScene();
});
updateMotionButton();
scheduleScene();

document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => {
  const view = views.find(item => item.id === button.dataset.view);
  document.querySelector('#view-frame').innerHTML = view.kind === 'nps' ? sceneImage() : capture(view.file, `Coda ${view.label} screenshot.`);
  setPalette(view.kind === 'nps' ? 0 : 3);
  document.querySelectorAll('[data-view]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  document.querySelector('#view-caption').textContent = {
    now: 'Now Playing. Artwork at the center; your queue in view.',
    home: 'Browse. Your artists and albums, together in one place.',
    album: 'An album, its track list, and whatever comes next.',
  }[view.id];
}));

let walkthroughTimer;
let walkthroughPlaying = false;
function stopWalkthrough() {
  clearTimeout(walkthroughTimer);
  walkthroughPlaying = false;
  const button = document.querySelector('[data-walkthrough]');
  if (button) button.textContent = 'Take a look ▷';
}
function showChapter(chapter) {
  document.querySelector('#journey-frame').innerHTML = chapter === 2 ? sceneImage(3) : capture(chapter === 0 ? 'home.png' : 'album.png', chapter === 0 ? 'Coda Home: your collection.' : 'Coda Album: choosing Press Start.');
  document.querySelectorAll('[data-chapter]').forEach(button => button.setAttribute('aria-pressed', String(Number(button.dataset.chapter) === chapter)));
}
document.querySelectorAll('[data-chapter]').forEach(button => button.addEventListener('click', () => {
  stopWalkthrough();
  showChapter(Number(button.dataset.chapter));
}));
document.querySelector('[data-walkthrough]')?.addEventListener('click', () => {
  if (walkthroughPlaying) { stopWalkthrough(); return; }
  walkthroughPlaying = true;
  document.querySelector('[data-walkthrough]').textContent = 'Pause walkthrough';
  showChapter(0);
  walkthroughTimer = setTimeout(() => {
    showChapter(1);
    walkthroughTimer = setTimeout(() => {
      showChapter(2);
      stopWalkthrough();
      document.querySelector('[data-walkthrough]').textContent = 'Replay walkthrough ▷';
    }, 4500);
  }, 4500);
});
document.addEventListener('visibilitychange', () => { if (document.hidden) stopWalkthrough(); });
