import test from 'node:test';
import assert from 'node:assert/strict';
import { assessFirstLoad, firstLoadTargets, installFirstLoadProbe } from '../scripts/FirstLoadProbe.mjs';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const good = () => ({
    pendingFrames: 12,
    earlyFrames: 0,
    shellAt: 1000,
    contentAt: 1000,
    animations: [{ start: 990, duration: 600 }],
    failed: false,
});

test('first-load timing covers every maintained public solution including Bookmarks', () => {
    const sites = JSON.parse(readFileSync(new URL('../site/sites.json', import.meta.url))).sites;
    assert.deepEqual(
        Object.keys(firstLoadTargets).sort(),
        sites
            .filter((site) => site.cloudflareUrl)
            .map((site) => site.id)
            .sort()
    );
});

test('synchronized 600ms entrance passes, including a ready cache without pending frames', () => {
    assert.ok(assessFirstLoad(good(), false).ok);
    assert.ok(assessFirstLoad({ ...good(), pendingFrames: 0 }, false).ok);
});

test('early shell, missing content, delayed arrival and wrong duration fail', () => {
    for (const probe of [
        null,
        { ...good(), contentAt: null },
        { ...good(), earlyFrames: 1 },
        { ...good(), contentAt: 1100 },
        { ...good(), animations: [] },
        { ...good(), animations: [{ start: 990, duration: 900 }] },
        {
            ...good(),
            animations: [
                { start: 990, duration: 600 },
                { start: 1100, duration: 600 },
            ],
        },
    ])
        assert.equal(assessFirstLoad(probe, false).ok, false);
});

test('reduced motion and failures require immediate unanimated arrival', () => {
    assert.ok(assessFirstLoad({ ...good(), animations: [] }, true).ok);
    assert.ok(assessFirstLoad({ ...good(), animations: [], failed: true }, false).ok);
    assert.equal(assessFirstLoad(good(), true).ok, false);
    assert.equal(assessFirstLoad({ ...good(), failed: true }, false).ok, false);
});

test('browser probe measures inherited opacity from first paint through the shared entrance', () => {
    let pending = true;
    const queued = [];
    const document = {};
    const view = {
        performance: { timeOrigin: 0 },
        frameElement: null,
        getComputedStyle: (node) => ({
            visibility: 'visible',
            display: 'block',
            opacity: node === root && pending ? '0' : '1',
        }),
    };
    const root = {
        ownerDocument: { defaultView: view },
        getAttribute: () => (pending ? 'pending' : 'ready'),
        getAnimations: () =>
            pending
                ? []
                : [
                      {
                          startTime: 900,
                          effect: {
                              getKeyframes: () => [{ opacity: '0' }, { opacity: '1' }],
                              getTiming: () => ({ duration: 600 }),
                          },
                      },
                  ],
    };
    const element = () => ({
        ownerDocument: { defaultView: view },
        parentElement: root,
        getBoundingClientRect: () => ({ width: 100 }),
        getAnimations: () => [],
    });
    document.querySelector = () => root;
    document.querySelectorAll = () => [element()];
    const window = {};
    const context = {
        document,
        window,
        self: window,
        top: window,
        performance: { now: () => 0, timeOrigin: 0 },
        requestAnimationFrame: (fn) => queued.push(fn),
        targets: { shell: 'header', content: 'main' },
    };
    runInNewContext(`(${installFirstLoadProbe.toString()})(targets)`, context);
    queued.shift()(0);
    assert.equal(window.__webStandardFirstLoad.pendingFrames, 1);
    assert.equal(window.__webStandardFirstLoad.earlyFrames, 0);
    pending = false;
    queued.shift()(900);
    assert.ok(assessFirstLoad(window.__webStandardFirstLoad, false).ok);
});
