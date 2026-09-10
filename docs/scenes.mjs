export const scenes = [
  {id: 'sigh', album: 'Goh-Ka', color: '34, 118, 126', light: '#74c1c6'},
  {id: 'satriani', album: 'The Elephants of Mars', color: '91, 48, 131', light: '#b194d3'},
  {id: 'shadow', album: 'Imperium Delirium', color: '50, 100, 62', light: '#9bbf90'},
  {id: 'pizza', album: 'Press Start', color: '132, 47, 103', light: '#d692bf'},
];

export function initialScene(random = Math.random) {
  return Math.floor(random() * scenes.length);
}

export function sceneAsset(index, view) {
  return `assets/${scenes[index].id}${view === 'nps' ? '' : `-${view}`}.png`;
}
