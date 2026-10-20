import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const script = readFileSync(new URL('./theme.js', import.meta.url), 'utf8');
function launch(stored, dark = false, blocked = false) {
  let ready, osChanged, focused;
  const listeners = {};
  const storage = new Map(stored === undefined ? [] : [['solution-deploy-theme', stored]]);
  const root = { dataset: {}, style: {}, classList: { toggle() {} } };
  const meta = {};
  function element(extra = {}) {
    return {
      attributes: {}, listeners: {},
      addEventListener(type, fn) { this.listeners[type] = fn; },
      setAttribute(key, value) { this.attributes[key] = value; },
      focus() { focused = this; },
      contains(target) { return target === this; },
      ...extra,
    };
  }
  const control = element();
  const value = element();
  const options = ['system', 'light', 'midnight'].map((preference) => element({
    dataset: { themePreference: preference },
    querySelector: () => ({ textContent: preference[0].toUpperCase() + preference.slice(1) }),
  }));
  const menu = element({
    hidden: true, querySelectorAll: () => options,
    contains(target) { return target === this || options.includes(target); },
  });
  const media = { matches: dark, addEventListener(_type, fn) { osChanged = fn; } };
  vm.runInNewContext(script, {
    document: { documentElement: root, querySelector: () => meta,
      getElementById: (id) => ({ theme: control, 'theme-value': value, 'theme-menu': menu })[id],
      addEventListener(type, fn) { if (type === 'DOMContentLoaded') ready = fn; else listeners[type] = fn; } },
    matchMedia: () => media,
    localStorage: {
      getItem(key) { if (blocked) throw Error('blocked'); return storage.get(key) ?? null; },
      setItem(key, value) { if (blocked) throw Error('blocked'); storage.set(key, value); },
    },
  });
  const beforeReady = root.dataset.theme;
  ready();
  return { root, meta, control, value, menu, options, storage, beforeReady,
    get focused() { return focused; },
    key(target, key) {
      let prevented = false;
      target.listeners.keydown({ key, preventDefault() { prevented = true; } });
      return prevented;
    },
    outside(type, target = {}) { listeners[type]({ target }); },
    choose(value) { options.find((option) => option.dataset.themePreference === value).listeners.click(); },
    os(value) { media.matches = value; osChanged(); } };
}

test('default, invalid and legacy dark preferences resolve to midnight', () => {
  for (const stored of [undefined, 'invalid', 'dark']) {
    const app = launch(stored);
    assert.equal(app.value.textContent, 'Midnight');
    assert.equal(app.beforeReady, 'midnight');
    assert.equal(app.root.dataset.theme, 'midnight');
    assert.equal(app.meta.content, '#0f172a');
  }
});

test('selectable system tracks OS, fixed themes ignore it, controls persist', () => {
  const app = launch('system');
  assert.equal(app.meta.content, '#ffffff');
  app.os(true);
  assert.equal(app.meta.content, '#0f172a');
  app.choose('light');
  app.os(true);
  assert.equal(app.meta.content, '#ffffff');
  assert.equal(app.root.style.colorScheme, 'light');
  app.choose('midnight');
  app.os(false);
  assert.equal(app.meta.content, '#0f172a');
  app.choose('system');
  assert.equal(app.storage.get('solution-deploy-theme'), 'system');
  assert.equal(app.meta.content, '#ffffff');
});

test('storage denial leaves system tracking functional', () => {
  const app = launch(undefined, false, true);
  app.choose('system');
  app.os(true);
  assert.equal(app.meta.content, '#0f172a');
});

test('menu opens at the saved preference and selection updates radio state and restores focus', () => {
  const app = launch('system');
  app.control.listeners.click();
  assert.equal(app.menu.hidden, false);
  assert.equal(app.control.attributes['aria-expanded'], 'true');
  assert.equal(app.focused, app.options[0]);
  app.choose('light');
  assert.equal(app.value.textContent, 'Light');
  assert.deepEqual(app.options.map((option) => option.attributes['aria-checked']), ['false', 'true', 'false']);
  assert.equal(app.storage.get('solution-deploy-theme'), 'light');
  assert.equal(app.menu.hidden, true);
  assert.equal(app.control.attributes['aria-expanded'], 'false');
  assert.equal(app.focused, app.control);
});

test('arrows wrap, Home and End jump, and navigation leaves the preference unchanged', () => {
  const app = launch();
  for (const key of ['ArrowDown', 'ArrowUp']) {
    assert.equal(app.key(app.control, key), true);
    assert.equal(app.focused, app.options[2]);
  }
  app.key(app.options[2], 'ArrowDown');
  assert.equal(app.focused, app.options[0]);
  app.key(app.options[0], 'ArrowUp');
  assert.equal(app.focused, app.options[2]);
  app.key(app.options[2], 'Home');
  assert.equal(app.focused, app.options[0]);
  app.key(app.options[0], 'End');
  assert.equal(app.focused, app.options[2]);
  app.key(app.control, 'Home');
  assert.equal(app.focused, app.options[0]);
  app.key(app.control, 'End');
  assert.equal(app.focused, app.options[2]);
  assert.equal(app.root.dataset.theme, 'midnight');
  assert.equal(app.storage.size, 0);
});

test('Escape returns focus and Tab allows browser navigation after dismissal', () => {
  const app = launch();
  app.control.listeners.click();
  assert.equal(app.key(app.options[2], 'Escape'), true);
  assert.equal(app.menu.hidden, true);
  assert.equal(app.focused, app.control);
  app.control.listeners.click();
  assert.equal(app.key(app.options[2], 'Tab'), false);
  assert.equal(app.menu.hidden, true);
  assert.equal(app.focused, app.control);
});

test('outside pointer and focus dismiss without stealing focus; internal events leave menu open', () => {
  const app = launch();
  for (const type of ['pointerdown', 'focusin']) {
    app.control.listeners.click();
    app.outside(type, app.options[0]);
    assert.equal(app.menu.hidden, false);
    app.outside(type);
    assert.equal(app.menu.hidden, true);
    assert.equal(app.focused, app.options[2]);
  }
  app.control.listeners.click();
  app.control.listeners.click();
  assert.equal(app.menu.hidden, true);
});

test('opaque full-width sticky header, standard surfaces and font load are retained', () => {
  const css = readFileSync(new URL('./style.css', import.meta.url), 'utf8');
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(css, /header\{position:sticky;top:0;z-index:10;width:100%;background:var\(--panel\)/);
  assert(css.includes('--bg:#020617;--panel:#0f172a'));
  assert(css.includes('--bg:#ffffff;--panel:#ffffff'));
  assert(!css.includes('backdrop-filter'));
  assert(html.includes('Roboto+Flex:opsz,wght@8..144,100..1000'));
  assert(html.indexOf('src="/theme.js"') < html.indexOf('href="/style.css"'));
  assert(!html.includes('<select'));
  assert(html.includes('aria-haspopup="menu"'));
  for (const value of ['system', 'light', 'midnight']) assert(html.includes(`data-theme-preference="${value}"`));
  assert(css.includes('scrollbar-color:var(--accent) var(--panel)'));
  assert(css.includes('max-width:100%'));
});
