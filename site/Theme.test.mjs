import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const script = readFileSync(new URL('./theme.js', import.meta.url), 'utf8');
function launch(stored, dark = false, blocked = false) {
  let ready, changed, osChanged;
  const storage = new Map(stored === undefined ? [] : [['solution-deploy-theme', stored]]);
  const root = { dataset: {}, style: {}, classList: { toggle() {} } };
  const meta = {};
  const control = { value: '', addEventListener(_type, fn) { changed = fn; } };
  const media = { matches: dark, addEventListener(_type, fn) { osChanged = fn; } };
  vm.runInNewContext(script, {
    document: { documentElement: root, querySelector: () => meta,
      getElementById: () => control, addEventListener(_type, fn) { ready = fn; } },
    matchMedia: () => media,
    localStorage: {
      getItem(key) { if (blocked) throw Error('blocked'); return storage.get(key) ?? null; },
      setItem(key, value) { if (blocked) throw Error('blocked'); storage.set(key, value); },
    },
  });
  ready();
  return { root, meta, control, storage,
    choose(value) { control.value = value; changed(); },
    os(value) { media.matches = value; osChanged(); } };
}

test('default, invalid and legacy dark preferences resolve to midnight', () => {
  for (const stored of [undefined, 'invalid', 'dark']) {
    const app = launch(stored);
    assert.equal(app.control.value, 'midnight');
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

test('opaque full-width sticky header, standard surfaces and font load are retained', () => {
  const css = readFileSync(new URL('./style.css', import.meta.url), 'utf8');
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(css, /header\{position:sticky;top:0;z-index:10;width:100%;background:var\(--panel\)/);
  assert(css.includes('--bg:#020617;--panel:#0f172a'));
  assert(css.includes('--bg:#ffffff;--panel:#ffffff'));
  assert(!css.includes('backdrop-filter'));
  assert(html.includes('Roboto+Flex:opsz,wght@8..144,100..1000'));
  assert(html.indexOf('src="/theme.js"') < html.indexOf('href="/style.css"'));
  for (const value of ['system', 'light', 'midnight']) assert(html.includes(`value="${value}"`));
});
