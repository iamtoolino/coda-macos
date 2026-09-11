import {scenes, initialScene, sceneAsset} from './scenes.mjs';

const frames = [...document.querySelectorAll('[data-scene-view]')];
const controls = [...document.querySelectorAll('[data-motion]')];
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const bootstrapIndex = Number(document.documentElement.dataset.initialScene);
let index = Number.isInteger(bootstrapIndex) && scenes[bootstrapIndex] ? bootstrapIndex : initialScene();
let paused = false;
let visible = true;
let ready = false;
let firstChange = true;
let timer;
let request = 0;

function updateControls() {
  controls.forEach(button => {
    button.hidden = false;
    button.textContent = paused ? 'Play preview' : 'Pause preview';
  });
}

function schedule() {
  clearTimeout(timer);
  if (!ready || paused || !visible || document.hidden) {
    if (ready) request++; // A pending decode must not start a new transition after pausing.
    return;
  }
  timer = setTimeout(async () => {
    firstChange = false;
    await showScene((index + 1) % scenes.length);
    schedule();
  }, firstChange ? 3500 : 6500);
}

async function showScene(nextIndex, animate = true) {
  const ticket = ++request;
  let prepared;
  try {
    // Prepare the whole theme before changing any of the three screenshots.
    prepared = await Promise.all(frames.map(async frame => {
      const view = frame.dataset.sceneView;
      const image = view === 'nps' ? new Image(1836, 1572) : new Image(2060, 1606);
      image.src = sceneAsset(nextIndex, view);
      image.alt = `Coda ${view === 'nps' ? 'Now Playing' : view === 'home' ? 'Home' : 'Album'} view with the ${scenes[nextIndex].album} color theme.`;
      await image.decode();
      return {frame, image};
    }));
  } catch { return false; } // Keep the complete current theme if an image cannot load.
  if (ticket !== request) return false;
  index = nextIndex;
  document.body.style.setProperty('--scene-rgb', scenes[index].color);
  document.body.style.setProperty('--scene-light', scenes[index].light);
  await Promise.all(prepared.map(async ({frame, image}) => {
    const previous = [...frame.children];
    image.style.opacity = '0';
    frame.append(image);
    if (animate && !reducedMotion.matches) {
      const transition = image.animate([{opacity: 0}, {opacity: 1}], {duration: 850, easing: 'ease-in-out', fill: 'forwards'});
      await transition.finished.catch(() => {});
      image.style.opacity = '1';
      transition.cancel();
    } else image.style.opacity = '1';
    previous.forEach(old => old.remove());
  }));
  return true;
}

controls.forEach(button => button.addEventListener('click', () => {
  paused = !paused;
  updateControls();
  schedule();
}));

const visibleFrames = new Set();
const observer = new IntersectionObserver(entries => {
  entries.forEach(entry => entry.isIntersecting ? visibleFrames.add(entry.target) : visibleFrames.delete(entry.target));
  const nextVisible = visibleFrames.size > 0;
  if (nextVisible !== visible) { visible = nextVisible; schedule(); }
}, {threshold: .12});
frames.forEach(frame => observer.observe(frame));
document.addEventListener('visibilitychange', schedule);

// Each visit starts automatically. Reduced motion uses instant swaps, not an opt-in loop.
ready = await showScene(index, false);
if (!ready && index !== 0) ready = await showScene(0, false);
document.documentElement.classList.remove('scene-pending');
if (ready) {
  updateControls();
  schedule();
}
