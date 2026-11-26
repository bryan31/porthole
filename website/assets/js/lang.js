/* Site languages. Each language is its own set of static pages:
 *    ./          English (the default)
 *    zh-hans/    简体中文
 *    zh-hant/    繁體中文
 * This file holds the few strings that the other scripts write themselves, and runs the
 * language menu in the navigation bar. A choice made in the menu is remembered in
 * localStorage "porthole-lang"; the default (English) pages read it in a small inline
 * script in <head> and move to the chosen version on arrival. Without a choice they take
 * the first browser language the site has (zh-Hant/TW/HK/MO -> 繁體, other zh -> 简体,
 * en -> stay), and stay English when the browser lists none of them.
 * Load this before theme.js, home.js and docs.js. */
(() => {
  'use strict';
  const root = document.documentElement;
  const KEY = 'porthole-lang';
  const lang = /^en\b/i.test(root.lang) ? 'en' : /hant|tw|hk|mo/i.test(root.lang) ? 'zh-hant' : 'zh-hans';

  const STRINGS = {
    'zh-hans': {
      toDark: '切换到深色主题：海底',
      toLight: '切换到浅色主题：天空',
      copy: '拷贝',
      copied: '已拷贝',
      copyCommand: '拷贝这段命令',
      linkHere: '链接到这一节',
      mac: '本机',
      server: 'SSH 服务器',
      channel: 'SSH 加密通道',
      channelShort: 'SSH 加密',
    },
    'zh-hant': {
      toDark: '切換到深色主題：海底',
      toLight: '切換到淺色主題：天空',
      copy: '拷貝',
      copied: '已拷貝',
      copyCommand: '拷貝這段指令',
      linkHere: '連結到這一節',
      mac: '本機',
      server: 'SSH 伺服器',
      channel: 'SSH 加密通道',
      channelShort: 'SSH 加密',
    },
    en: {
      toDark: 'Switch to the dark theme: under the sea',
      toLight: 'Switch to the light theme: the sky',
      copy: 'Copy',
      copied: 'Copied',
      copyCommand: 'Copy this command',
      linkHere: 'Link to this section',
      mac: 'This Mac',
      server: 'SSH server',
      channel: 'Encrypted SSH',
      channelShort: 'SSH',
    },
  };

  window.porthole = {
    lang,
    t: (key) => (STRINGS[lang] && STRINGS[lang][key]) || STRINGS.en[key] || key,
  };

  /* ---- Language menu: <details class="lang-menu"> works without script; this adds the rest. */
  const save = (l) => { try { localStorage.setItem(KEY, l); } catch (_) { /* private mode */ } };

  document.querySelectorAll('.lang-menu').forEach((menu) => {
    const summary = menu.querySelector('summary');
    const close = (focus) => {
      if (!menu.open) return;
      menu.open = false;
      if (focus && summary) summary.focus();
    };
    const onDoc = (e) => { if (!menu.contains(e.target)) close(false); };
    const onKey = (e) => { if (e.key === 'Escape') close(true); };
    menu.addEventListener('toggle', () => {
      if (menu.open) {
        document.addEventListener('pointerdown', onDoc);
        document.addEventListener('keydown', onKey);
      } else {
        document.removeEventListener('pointerdown', onDoc);
        document.removeEventListener('keydown', onKey);
      }
    });

    menu.querySelectorAll('a[data-lang]').forEach((a) => a.addEventListener('click', () => {
      save(a.dataset.lang);
      // stay on the same part of the page in the other language
      if (location.hash && !a.hash) a.href += location.hash;
    }));
  });
})();
