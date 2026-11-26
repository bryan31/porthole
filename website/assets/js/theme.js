/* Light (sky) and dark (sea) themes. The choice is remembered; without one the site follows
   the system appearance. The page announces changes with a "porthole:theme" event so the
   homepage can sweep its view between sky and sea. The initial theme is set by a small inline
   script in <head> so the first paint is already right. */
(() => {
  'use strict';
  const root = document.documentElement;
  const KEY = 'porthole-theme';
  const system = matchMedia('(prefers-color-scheme: light)');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const COLORS = { light: '#d9efff', dark: '#061331' };
  const t = (window.porthole && window.porthole.t) || ((k) => k);
  let fadeTimer = 0;

  const saved = () => { try { return localStorage.getItem(KEY); } catch (_) { return null; } };
  const save = (t) => { try { localStorage.setItem(KEY, t); } catch (_) { /* private mode */ } };

  function label() {
    const light = root.dataset.theme === 'light';
    document.querySelectorAll('.theme-toggle').forEach((b) => {
      const text = light ? t('toDark') : t('toLight');
      b.setAttribute('aria-label', text);
      b.title = text;
    });
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = COLORS[root.dataset.theme] || COLORS.dark;
  }

  function apply(theme, animate) {
    if (root.dataset.theme === theme) return;
    if (animate && !reduce.matches) {
      root.classList.add('theme-fade');
      clearTimeout(fadeTimer);
      fadeTimer = setTimeout(() => root.classList.remove('theme-fade'), 800);
    }
    root.dataset.theme = theme;
    label();
    window.dispatchEvent(new CustomEvent('porthole:theme', { detail: { theme, animate: !!animate } }));
  }

  document.querySelectorAll('.theme-toggle').forEach((b) => b.addEventListener('click', () => {
    const next = root.dataset.theme === 'light' ? 'dark' : 'light';
    save(next);
    apply(next, true);
  }));

  system.addEventListener('change', () => {
    const s = saved();
    if (s !== 'light' && s !== 'dark') apply(system.matches ? 'light' : 'dark', true);
  });

  label();
})();
