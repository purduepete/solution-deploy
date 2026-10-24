import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from '../site/server.mjs';
import { runInNewContext } from 'node:vm';

test('audit info uses report counts, distinguishes unavailable data and renders errors as text', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('let auditInfoId'), source.indexOf('\nfunction table('));
    const element = (tag, text) => ({
        tag,
        text,
        children: [],
        type: '',
        setAttribute() {},
        addEventListener() {},
        append(...children) {
            this.children.push(...children);
        },
    });
    const info = runInNewContext(`${code}\nauditInfo`, {
        element,
        crypto: {},
        Number,
    });
    const first = info({ audit: 'Stock', subject: 'splits' });
    const second = info({ audit: 'Stock', subject: 'splits' });
    assert.notEqual(first.children[1].id, second.children[1].id);
    const text = (row) =>
        info({ audit: 'Stock', subject: 'splits', ...row })
            .children[1].children.map((child) => child.text)
            .join('\n');
    assert.match(text({ counts: { azure: 0, local: 0, mismatched: 0 } }), /Azure: 0\nLocal: 0\nMismatched: 0/);
    assert.match(text({ counts: { azure: 3, local: 2, missing_local: 1 } }), /Missing locally: 1/);
    assert.match(text({}), /Comparison counts unavailable/);
    assert.match(text({ counts: {}, error: 'azure_TimeoutError' }), /Comparison error: azure_TimeoutError/);
});

test('inventory describes every published host and its data source', () => {
    const inventory = JSON.parse(readFileSync(new URL('../site/sites.json', import.meta.url)));
    assert.equal(inventory.host, 'jimbrownhome1');
    assert.equal(inventory.sites.length, 14);
    const page = readFileSync(new URL('../site/index.html', import.meta.url), 'utf8');
    assert.match(page, /192\.168\.2\.0\/24/);
    assert(!page.includes('Local URLs use loopback'));
    for (const [id, name] of Object.entries({
        'fit-track': 'Fit Track',
        'web-options': 'Web Options',
        'web-portfolio': 'Web Portfolio',
        'web-bookmarks': 'Web Bookmarks',
        'web-inventory': 'Web Inventory',
        'work-log': 'Work Log',
        'site-dock': 'Site Dock',
        'solution-deploy': 'Solution Directory',
        plex: 'Plex Track',
    })) {
        assert.equal(inventory.sites.find((site) => site.id === id)?.name, name);
    }
    const ids = new Set();
    const local = new Set();
    const privateUrls = new Set();
    const privateOnly = new Set(['ride-and-lift', 'pgweb']);
    const routing = readFileSync(new URL('../scripts/Set-CloudflareHostnames.ps1', import.meta.url), 'utf8');
    for (const site of inventory.sites) {
        assert(!ids.has(site.id));
        ids.add(site.id);
        for (const field of ['purpose', 'database', 'sourceDatabase', 'notes']) assert(site[field]?.trim());
        const localUrl = new URL(site.localUrl);
        const privateUrl = new URL(site.tailscaleUrl);
        assert.equal(localUrl.hostname, '192.168.2.14');
        assert.equal(privateUrl.hostname, 'jimbrownhome1.tail8ad282.ts.net');
        assert.equal(privateUrl.protocol, 'https:');
        assert(!local.has(localUrl.port));
        local.add(localUrl.port);
        assert(!privateUrls.has(privateUrl.port));
        privateUrls.add(privateUrl.port);
        if (!site.cloudflareUrl) {
            assert(privateOnly.has(site.id), `${site.id} needs a Cloudflare URL`);
            assert.match(site.notes, /no Cloudflare path/);
            continue;
        }
        const publicUrl = new URL(site.cloudflareUrl);
        assert.equal(publicUrl.hostname, `${site.id}.jimlertech.com`);
        assert.equal(publicUrl.protocol, 'https:');
        const originPort =
            {
                plex: '18793',
                'work-log': '18794',
                'web-inventory': '18795',
                'web-portfolio': '18796',
                'web-options': '18797',
                'solution-deploy': '18798',
            }[site.id] ?? localUrl.port;
        assert(routing.includes(`'${publicUrl.hostname}'=${originPort}`), `Route mismatch for ${site.id}`);
        assert.equal(localUrl.port, site.id === 'solution-deploy' ? '' : privateUrl.port);
    }
    for (const id of ['web-portfolio', 'web-options']) {
        const site = inventory.sites.find((entry) => entry.id === id);
        assert.match(site.database, /LIVE Azure SQL:.*webportfolio/);
        assert.match(site.sourceDatabase, /retained unchanged/);
    }
    const webOptions = inventory.sites.find((site) => site.id === 'web-options');
    assert.match(webOptions.database, /Local PostgreSQL: web_options/);
    assert.match(webOptions.sourceDatabase, /SELECT-only contract discovery/);
    assert.match(inventory.sites.find((site) => site.id === 'web-inventory').notes, /D:\\SolutionDeploy/);
    assert.match(inventory.sites.find((site) => site.id === 'plex').sourceDatabase, /jimbrownhome:32400/);
});

test('stock collector messaging lists the current settlement schedule', () => {
    const generator = readFileSync(new URL('../scripts/Update-CollectorStatus.ps1', import.meta.url), 'utf8');
    const schedule = generator.match(/id = 'stock-prices';[\s\S]*?schedule = '([^']+)'/)?.[1];
    assert.equal(
        schedule,
        'Trading days: Session every 10 minutes 06:00-12:50, Close 13:00, Settle 13:10. Every day: Final settle 17:00.'
    );
    assert(!schedule.includes('13:20'));
});

test('collector status is read from disk on every request', async () => {
    const folder = mkdtempSync(join(tmpdir(), 'collector-status-'));
    const statusPath = join(folder, 'collector-status.json');
    const server = createServer({ statusPath });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/collector-status.json`;
    try {
        let response = await fetch(url);
        assert.equal(response.status, 503);
        assert.equal(response.headers.get('cache-control'), 'no-store');
        writeFileSync(statusPath, '{"schemaVersion":1,"runs":[]}');
        response = await fetch(url);
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { schemaVersion: 1, runs: [] });
        writeFileSync(statusPath, '{"schemaVersion":1,"runs":[1]}');
        assert.deepEqual((await (await fetch(url)).json()).runs, [1]);
        assert.equal((await fetch(url, { method: 'POST' })).status, 405);
    } finally {
        server.closeAllConnections();
        await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
        rmSync(folder, { recursive: true, force: true });
    }
});

test('collectors page links back to the directory and loads only its own script', () => {
    const page = readFileSync(new URL('../site/collectors.html', import.meta.url), 'utf8');
    assert.match(page, /<script src="\/collectors\.js" defer><\/script>/);
    assert(!page.includes('/app.js'));
    assert.match(page, /href="\/"/);
    assert.match(page, /id="theme-menu"/);
    assert.match(readFileSync(new URL('../site/index.html', import.meta.url), 'utf8'), /href="\/collectors"/);
});

test('server exposes only fixed read-only assets with protective headers', async () => {
    const server = createServer();
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const root = `http://127.0.0.1:${server.address().port}`;
    const get = (path, method = 'GET') =>
        new Promise((resolve, reject) => {
            const req = request(root + path, { method, agent: false }, (response) => {
                response.resume();
                response.on('error', reject);
                response.on('end', () => resolve(response));
            });
            req.setTimeout(10000, () => req.destroy(new Error('Directory test request timed out.')));
            req.on('error', reject);
            req.end();
        });
    try {
        for (const path of [
            '/',
            '/style.css',
            '/theme.js',
            '/app.js',
            '/collectors',
            '/collectors.js',
            '/sites.json',
            '/favicon.svg',
            '/apple-touch-icon.png',
            '/health',
        ]) {
            const response = await get(path);
            assert.equal(response.statusCode, 200);
            assert.equal(response.headers['cache-control'], 'no-store');
            assert.equal(response.headers['x-content-type-options'], 'nosniff');
            assert.match(response.headers['content-security-policy'], /script-src 'self'/);
            assert(!response.headers['access-control-allow-origin']);
        }
        assert.equal((await get('/sites.json', 'HEAD')).statusCode, 200);
        assert.equal((await get('/sites.json', 'POST')).statusCode, 405);
        assert.equal((await get('/server.mjs')).statusCode, 404);
        assert.equal((await get('/%2e%2e/README.md')).statusCode, 404);
        assert.equal((await get('/.env')).statusCode, 404);
        assert.equal((await get('/health')).statusCode, 200);
    } finally {
        await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
});
