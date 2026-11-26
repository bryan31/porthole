/* Documentation page: table of contents that follows the reader, copy buttons on code. */
(() => {
  'use strict';
  const t = (window.porthole && window.porthole.t) || ((k) => k);

  const toc = document.getElementById('toc-details');
  const links = Array.from(document.querySelectorAll('.toc a[href^="#"]'));
  const narrow = matchMedia('(max-width: 900px)');

  // On narrow screens the contents start folded and fold again after a jump.
  if (toc && narrow.matches) toc.open = false;
  links.forEach((a) => a.addEventListener('click', () => { if (toc && narrow.matches) toc.open = false; }));

  // Highlight the section being read.
  const targets = links
    .map((a) => document.getElementById(a.getAttribute('href').slice(1)))
    .filter(Boolean);
  const byId = new Map(links.map((a) => [a.getAttribute('href').slice(1), a]));
  let current = null;
  const setActive = (id) => {
    if (id === current) return;
    current = id;
    links.forEach((a) => a.classList.toggle('active', a.getAttribute('href') === '#' + id));
    const link = byId.get(id);
    if (link && !narrow.matches) link.scrollIntoView({ block: 'nearest' });
  };
  const update = () => {
    const line = 120;
    let id = targets.length ? targets[0].id : null;
    for (const el of targets) {
      if (el.getBoundingClientRect().top - line <= 0) id = el.id;
      else break;
    }
    setActive(id);
  };
  let ticking = false;
  addEventListener('scroll', () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; update(); });
  }, { passive: true });
  update();

  // A "#" link beside each heading (shown on hover), so a section or question can be linked to.
  document.querySelectorAll('.doc h2, .doc h3').forEach((h) => {
    const id = h.id || (h.tagName === 'H2' && h.parentElement.id);
    if (!id) return;
    const a = document.createElement('a');
    a.className = 'heading-anchor';
    a.href = '#' + id;
    a.textContent = '#';
    a.setAttribute('aria-label', t('linkHere'));
    h.appendChild(a);
  });

  // Copy buttons on code blocks.
  document.querySelectorAll('.doc pre').forEach((pre) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'copy-btn';
    btn.textContent = t('copy');
    btn.setAttribute('aria-label', t('copyCommand'));
    btn.addEventListener('click', async () => {
      const code = pre.querySelector('code');
      try {
        await navigator.clipboard.writeText((code || pre).textContent.trim());
        btn.dataset.copied = '';
        btn.textContent = t('copied');
        setTimeout(() => { delete btn.dataset.copied; btn.textContent = t('copy'); }, 1600);
      } catch (_) { /* clipboard unavailable; the text is still selectable */ }
    });
    pre.appendChild(btn);
  });
})();
