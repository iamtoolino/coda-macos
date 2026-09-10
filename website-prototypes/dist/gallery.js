import {studies} from './data.js';

document.querySelector('#studies').innerHTML = studies.map(study => `<article class="study-card"><a class="preview-link" href="concept.html?v=${study.id}" aria-label="Explore ${study.name}"><div class="miniature"><iframe src="concept.html?v=${study.id}&embed=1&still=1" title="${study.name} preview" loading="lazy" tabindex="-1" inert></iframe></div></a><div class="study-info"><span class="study-number">${String(study.id).padStart(2, '0')}</span><div><h2><a href="concept.html?v=${study.id}">${study.name}</a></h2><p>${study.description}</p></div><a class="explore-link" href="concept.html?v=${study.id}" aria-label="Explore ${study.name}">Explore ↗</a></div></article>`).join('');

const sizing = new ResizeObserver(entries => {
  entries.forEach(({target, contentRect}) => target.style.setProperty('--preview-scale', contentRect.width / 1440));
});
document.querySelectorAll('.miniature').forEach(element => sizing.observe(element));

function comparePane(side, selected) {
  return `<section class="compare-pane"><label for="compare-${side}">${side === 'left' ? 'First' : 'Second'} direction</label><select id="compare-${side}">${studies.map(study => `<option value="${study.id}" ${study.id === selected ? 'selected' : ''}>${String(study.id).padStart(2, '0')} — ${study.name}</option>`).join('')}</select><a class="preview-link" href="concept.html?v=${selected}"><div class="miniature"><iframe src="concept.html?v=${selected}&embed=1&still=1" title="${studies[selected - 1].name} preview" tabindex="-1" inert></iframe></div></a><a class="compare-open" href="concept.html?v=${selected}">Explore ${studies[selected - 1].name} ↗</a></section>`;
}

document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => {
  const comparing = button.dataset.mode === 'compare';
  document.querySelector('#studies').hidden = comparing;
  document.querySelector('#compare').hidden = !comparing;
  document.querySelectorAll('[data-mode]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  if (comparing && !document.querySelector('#compare').children.length) {
    document.querySelector('#compare').innerHTML = comparePane('left', 4) + comparePane('right', 5);
    document.querySelectorAll('#compare .miniature').forEach(element => sizing.observe(element));
    document.querySelectorAll('#compare select').forEach(select => select.addEventListener('change', () => {
      const study = studies.find(item => item.id === Number(select.value));
      const pane = select.closest('.compare-pane');
      pane.querySelector('iframe').src = `concept.html?v=${study.id}&embed=1&still=1`;
      pane.querySelector('iframe').title = `${study.name} preview`;
      pane.querySelectorAll('a').forEach(link => link.href = `concept.html?v=${study.id}`);
      pane.querySelector('.compare-open').textContent = `Explore ${study.name} ↗`;
    }));
  }
}));
