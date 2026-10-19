import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { request } from 'node:http';
import { createServer } from '../site/server.mjs';

test('inventory describes every published host and its data source', () => {
  const inventory = JSON.parse(readFileSync(new URL('../site/sites.json', import.meta.url)));
  assert.equal(inventory.host, 'jimbrownhome1');
  assert.equal(inventory.sites.length, 11);
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
  const routing = readFileSync(new URL('../scripts/Set-CloudflareHostnames.ps1', import.meta.url), 'utf8');
  for (const site of inventory.sites) {
    assert(!ids.has(site.id)); ids.add(site.id);
    for (const field of ['purpose', 'database', 'sourceDatabase', 'notes']) assert(site[field]?.trim());
    const publicUrl = new URL(site.cloudflareUrl);
    const localUrl = new URL(site.localUrl);
    const privateUrl = new URL(site.tailscaleUrl);
    assert.equal(publicUrl.hostname, `${site.id}.jimlertech.com`);
    assert.equal(publicUrl.protocol, 'https:');
    assert.equal(localUrl.hostname, '192.168.2.14');
    assert.equal(privateUrl.hostname, 'jimbrownhome1.tail8ad282.ts.net');
    assert.equal(privateUrl.protocol, 'https:');
    assert(!local.has(localUrl.port)); local.add(localUrl.port);
    assert(!privateUrls.has(privateUrl.port)); privateUrls.add(privateUrl.port);
    const originPort = { plex: '18793', 'work-log': '18794', 'web-inventory': '18795',
      'web-portfolio': '18796', 'web-options': '18797', 'solution-deploy': '18798' }[site.id] ?? localUrl.port;
    assert(routing.includes(`'${publicUrl.hostname}'=${originPort}`), `Route mismatch for ${site.id}`);
    assert.equal(localUrl.port, site.id === 'solution-deploy' ? '' : privateUrl.port);
  }
  for (const id of ['web-portfolio', 'web-options']) {
    const site = inventory.sites.find((entry) => entry.id === id);
    assert.match(site.database, /LIVE Azure SQL:.*webportfolio/);
    assert.match(site.sourceDatabase, /retained unchanged/);
  }
  assert.match(inventory.sites.find((site) => site.id === 'web-inventory').notes, /D:\\SolutionDeploy/);
  assert.match(inventory.sites.find((site) => site.id === 'plex').sourceDatabase, /jimbrownhome:32400/);
});

test('server exposes only fixed read-only assets with protective headers', async () => {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const root = `http://127.0.0.1:${server.address().port}`;
  const get = (path, method = 'GET') => new Promise((resolve, reject) => {
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
    for (const path of ['/', '/style.css', '/theme.js', '/app.js', '/sites.json', '/health']) {
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
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
