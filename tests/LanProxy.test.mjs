import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { createLanProxy, permittedSource, productionConfig } from '../site/lan-proxy.mjs';

const quiet = { log() {}, error() {} };
const trustedOrigin = 'https://jimbrownhome1.tail8ad282.ts.net:8795';

async function fixture(t, handler, options = {}) {
  const upstream = http.createServer(handler);
  const upstreamSockets = new Set();
  upstream.on('connection', socket => {
    upstreamSockets.add(socket);
    socket.once('close', () => upstreamSockets.delete(socket));
  });
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  const upstreamPort = upstream.address().port;
  const proxy = createLanProxy({
    bindAddress: '127.0.0.1', lanAddress: '127.0.0.1', allowLoopback: true,
    listeners: [{ port: 0, upstreamPort, privatePort: options.privatePort ?? 8795 }],
  }, quiet);
  t.after(async () => {
    await proxy.close();
    for (const socket of upstreamSockets) socket.destroy();
    await new Promise(done => upstream.close(done));
  });
  const [address] = await proxy.start();
  return { upstream, upstreamPort, proxy, port: address.port, origin: `http://127.0.0.1:${address.port}` };
}

function request(f, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: f.port, path: options.path ?? '/', method: options.method ?? 'GET',
      headers: { Host: `127.0.0.1:${f.port}`, ...options.headers }, agent: false,
    }, res => {
      const data = [];
      res.on('data', chunk => data.push(chunk));
      res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(data).toString() }));
    });
    req.on('error', reject);
    req.end(options.body);
  });
}

async function raw(f, bytes) {
  const socket = net.connect(f.port, '127.0.0.1');
  socket.setTimeout(3000, () => socket.destroy(new Error('Raw request timed out')));
  await once(socket, 'connect');
  const chunks = [];
  socket.on('data', data => chunks.push(data));
  const finished = once(socket, 'end');
  socket.write(bytes);
  await finished;
  socket.destroy();
  return Buffer.concat(chunks).toString();
}

test('production mapping is explicit, immutable and never wildcard', () => {
  assert.equal(productionConfig.bindAddress, '192.168.2.14');
  assert.equal(productionConfig.lanAddress, '192.168.2.14');
  assert.equal(productionConfig.allowLoopback, false);
  assert.deepEqual(productionConfig.listeners.map(item => [item.port, item.upstreamPort, item.privatePort]), [
    [80,18798,8798], [8787,8787,8787], [8788,8788,8788], [8790,8790,8790],
    [8791,8791,8791], [8792,8792,8792], [8793,18793,8793], [8794,18794,8794],
    [8795,18795,8795], [8796,18796,8796], [8797,18797,8797], [8798,18798,8798],
  ]);
  assert.ok(Object.isFrozen(productionConfig.listeners[0]));
  for (const bindAddress of [undefined, '0.0.0.0', '::', '127.0.0.1', '192.168.2.15']) {
    assert.throws(() => createLanProxy({ ...productionConfig, bindAddress }), /Bind address/);
  }
  assert.throws(() => createLanProxy({
    ...productionConfig, listeners: [{ port: 0, upstreamPort: 1, privatePort: 1 }],
  }), /Invalid listener/);
});

test('source IPv4 CIDR is checked independently of forwarding claims', () => {
  for (const source of ['192.168.2.1', '192.168.2.14', '192.168.2.254']) assert.ok(permittedSource(source));
  for (const source of ['192.168.20.1', '192.168.3.1', '10.0.0.1', '127.0.0.1', '::1', '::ffff:192.168.2.1', '192.168.2.256']) {
    assert.equal(permittedSource(source), false, source);
  }
  assert.ok(permittedSource('127.0.0.1', true));
});

test('Host, Origin, fetch-site and request-target guards never reach upstream', async t => {
  let hits = 0;
  const f = await fixture(t, (req, res) => { hits++; res.end('ok'); });
  for (const headers of [
    { Host: 'foreign.example' }, { Host: `127.0.0.1:${f.port + 1}` },
    { Origin: 'https://foreign.example' }, { Origin: trustedOrigin }, { Origin: 'null' },
    { Origin: `${f.origin}/` }, { 'Sec-Fetch-Site': 'cross-site' },
    { 'Sec-Fetch-Site': 'same-origin, cross-site' },
  ]) assert.equal((await request(f, { headers })).status, 403);
  assert.equal((await request(f, { path: 'http://foreign.example/' })).status, 400);
  assert.match(await raw(f, `GET / HTTP/1.1\r\nHost: 127.0.0.1:${f.port}\r\nHost: foreign.example\r\nConnection: close\r\n\r\n`), /^HTTP\/1.1 (400|403)/);
  assert.match(await raw(f, `GET / HTTP/1.1\r\nHost: 127.0.0.1:${f.port}\r\nOrigin: ${f.origin}\r\nOrigin: ${f.origin}\r\nConnection: close\r\n\r\n`), /^HTTP\/1.1 403/);
  assert.equal(hits, 0);
  assert.equal((await request(f, { headers: { Origin: f.origin, 'Sec-Fetch-Site': 'same-origin' } })).status, 200);
  assert.equal(hits, 1);
});

test('upstream gets loopback Host, trusted Origin, original tokens and no client identity', async t => {
  let received;
  const f = await fixture(t, (req, res) => { received = req; res.end('ok'); });
  const response = await request(f, {
    path: '/api/items?token=keep%2Bme', method: 'POST', body: 'payload',
    headers: {
      Origin: f.origin, Authorization: 'Bearer untouched', Cookie: 'session=unchanged', 'X-Api-Key': 'unchanged',
      Forwarded: 'for=192.168.2.10', 'X-Forwarded-Host': 'evil', 'X-Forwarded-Proto': 'https',
      'X-Forwarded-For': '192.168.2.1', 'X-Real-IP': '192.168.2.1',
      'True-Client-IP': '192.168.2.1', 'CF-Access-Jwt-Assertion': 'spoof',
      'CF-Access-Authenticated-User-Email': 'spoof@example.com', 'CF-Connecting-IP': '192.168.2.1',
      'Cloudflare-Identity': 'spoof', Connection: 'close, x-hop', 'X-Hop': 'remove',
      'Proxy-Authorization': 'remove', 'X-Original-Host': 'evil',
    },
  });
  assert.equal(response.status, 200);
  assert.equal(received.url, '/api/items?token=keep%2Bme');
  assert.equal(received.method, 'POST');
  assert.equal(received.headers.host, `127.0.0.1:${f.upstreamPort}`);
  assert.equal(received.headers.origin, trustedOrigin);
  assert.equal(received.headers.authorization, 'Bearer untouched');
  assert.equal(received.headers.cookie, 'session=unchanged');
  assert.equal(received.headers['x-api-key'], 'unchanged');
  for (const name of ['forwarded','x-forwarded-host','x-forwarded-proto','x-forwarded-for','x-real-ip',
    'true-client-ip','cf-access-jwt-assertion','cf-access-authenticated-user-email','cf-connecting-ip',
    'cloudflare-identity','x-hop','proxy-authorization','x-original-host']) assert.equal(received.headers[name], undefined, name);
});

test('redirects, ordinary cookies, CSP and hop headers are adapted only as required', async t => {
  const f = await fixture(t, (req, res) => {
    res.writeHead(302, {
      Location: `${trustedOrigin}/app?x=1#two`,
      'Set-Cookie': ['sid=abc; Path=/app; Secure; HttpOnly; SameSite=Lax', 'other=x; Domain=jimbrownhome1.tail8ad282.ts.net; Secure; Path=/'],
      'Content-Security-Policy': ["default-src 'self'; upgrade-insecure-requests; frame-ancestors 'self' https://example.com; object-src 'none'", "frame-ancestors 'none'; script-src 'self'"],
      'Content-Security-Policy-Report-Only': "default-src 'self'; upgrade-insecure-requests",
      'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'SAMEORIGIN',
      Connection: 'close, x-private-hop', 'X-Private-Hop': 'remove',
    });
    res.end('redirect');
  });
  const result = await request(f);
  assert.equal(result.headers.location, `${f.origin}/app?x=1#two`);
  assert.deepEqual(result.headers['set-cookie'], ['sid=abc; Path=/app; HttpOnly; SameSite=Lax', 'other=x; Path=/']);
  const policy = result.headers['content-security-policy'];
  assert.ok(!policy.includes('upgrade-insecure-requests'));
  assert.ok(policy.includes("default-src 'self'"));
  assert.ok(policy.includes("object-src 'none'"));
  assert.ok(policy.includes("frame-ancestors 'self' https://example.com http://127.0.0.1:8790"));
  assert.ok(policy.includes("frame-ancestors http://127.0.0.1:8790"));
  assert.equal(result.headers['content-security-policy-report-only'], "default-src 'self'");
  assert.equal(result.headers['x-content-type-options'], 'nosniff');
  assert.equal(result.headers['x-frame-options'], 'SAMEORIGIN');
  assert.equal(result.headers['x-private-hop'], undefined);
});

test('relative and foreign redirects and CSP without frame-ancestors remain unchanged', async t => {
  const f = await fixture(t, (req, res) => {
    res.writeHead(302, { Location: req.url === '/relative' ? '/app' : 'https://elsewhere.example/a', 'Content-Security-Policy': "default-src 'self'" });
    res.end();
  });
  assert.equal((await request(f, { path: '/relative' })).headers.location, '/app');
  const result = await request(f);
  assert.equal(result.headers.location, 'https://elsewhere.example/a');
  assert.equal(result.headers['content-security-policy'], "default-src 'self'");
});

test('HTTPS-only and foreign-domain cookies fail explicitly without silent loss', async t => {
  for (const cookie of ['__Host-sid=abc; Secure; Path=/', '__Secure-sid=abc; Secure',
    'sid=abc; SameSite=None; Secure', 'sid=abc; Partitioned; Secure', 'sid=abc; Domain=foreign.example']) {
    await t.test(cookie.split(';')[0], async t => {
      const f = await fixture(t, (req, res) => { res.setHeader('Set-Cookie', cookie); res.end('private'); });
      const result = await request(f);
      assert.equal(result.status, 502);
      assert.equal(result.headers['set-cookie'], undefined);
      assert.ok(!result.body.includes('private'));
    });
  }
});

test('WorkLog GET root redirects and all HEAD requests fail before reaching upstream', async t => {
  const hits = [];
  const f = await fixture(t, (req, res) => { hits.push([req.method, req.url, req.headers.origin]); res.end('app'); }, { privatePort: 8794 });
  const root = await request(f);
  assert.equal(root.status, 302);
  assert.equal(root.headers.location, '/app');
  for (const path of ['/', '/app', '/api/tasks']) assert.equal((await request(f, { method: 'HEAD', path })).status, 405);
  assert.equal(hits.length, 0);
  assert.equal((await request(f, { path: '/app?view=day' })).body, 'app');
  assert.deepEqual(hits, [['GET', '/app?view=day', 'https://jimbrownhome1.tail8ad282.ts.net:8794']]);
});

test('upload reaches upstream before client finishes sending', { timeout: 5000 }, async t => {
  let first;
  const arrived = new Promise(done => { first = done; });
  const f = await fixture(t, (req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; first(); });
    req.on('end', () => res.end(body));
  });
  const req = http.request({ hostname: '127.0.0.1', port: f.port, method: 'POST', path: '/upload', headers: { Host: `127.0.0.1:${f.port}` }, agent: false });
  const response = new Promise((done, reject) => {
    req.on('error', reject);
    req.on('response', res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => done(body));
      res.on('error', reject);
    });
  });
  req.write('first-');
  await arrived;
  req.end('last');
  assert.equal(await response, 'first-last');
});

test('SSE arrives before upstream ends and client disconnect closes upstream', { timeout: 5000 }, async t => {
  let finish;
  const upstreamClosed = new Promise(done => { finish = done; });
  const f = await fixture(t, (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write('data: first\n\n');
    res.on('close', finish);
  });
  const req = http.get({ hostname: '127.0.0.1', port: f.port, headers: { Host: `127.0.0.1:${f.port}` }, agent: false });
  const [response] = await once(req, 'response');
  const [chunk] = await once(response, 'data');
  assert.equal(chunk.toString(), 'data: first\n\n');
  response.destroy();
  await upstreamClosed;
});

test('WebSocket upgrade relays headers, initial bytes and bidirectional frames', { timeout: 5000 }, async t => {
  const f = await fixture(t, (req, res) => res.end());
  let headers;
  f.upstream.on('upgrade', (req, socket, head) => {
    headers = req.headers;
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: fixture\r\n\r\nwelcome');
    if (head.length) socket.write(head);
    socket.on('data', chunk => socket.write(chunk));
  });
  const socket = net.connect(f.port, '127.0.0.1');
  t.after(() => socket.destroy());
  await once(socket, 'connect');
  let data = Buffer.alloc(0);
  let initial;
  const initialReceived = new Promise(done => { initial = done; });
  let echoed;
  const echoReceived = new Promise(done => { echoed = done; });
  socket.on('data', chunk => {
    data = Buffer.concat([data, chunk]);
    if (data.includes(Buffer.from('welcomeinitial'))) initial();
    if (data.includes(Buffer.from('later'))) echoed();
  });
  socket.write(`GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${f.port}\r\nOrigin: ${f.origin}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nCF-Access-Jwt-Assertion: spoof\r\n\r\ninitial`);
  await initialReceived;
  assert.match(data.toString(), /^HTTP\/1.1 101/);
  assert.equal(headers.host, `127.0.0.1:${f.upstreamPort}`);
  assert.equal(headers.origin, trustedOrigin);
  assert.equal(headers['cf-access-jwt-assertion'], undefined);
  socket.write('later');
  await echoReceived;
});

test('WebSocket guard rejection and refused upstream handshake return HTTP errors', async t => {
  let upgrades = 0;
  const f = await fixture(t, (req, res) => { res.writeHead(401); res.end('denied'); });
  f.upstream.on('upgrade', (req, socket) => {
    upgrades++;
    socket.end('HTTP/1.1 401 Unauthorized\r\nContent-Length: 6\r\nConnection: close\r\n\r\ndenied');
  });
  const headers = `GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${f.port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n`;
  assert.match(await raw(f, `${headers}Origin: https://foreign.example\r\n\r\n`), /^HTTP\/1.1 403/);
  assert.equal(upgrades, 0);
  const result = await raw(f, `${headers}Origin: ${f.origin}\r\n\r\n`);
  assert.match(result, /^HTTP\/1.1 401/);
  assert.ok(result.endsWith('denied'));
  assert.equal(upgrades, 1);
});

test('upstream connection failures return 502', async t => {
  const f = await fixture(t, (req, res) => res.end());
  await new Promise(done => f.upstream.close(done));
  assert.equal((await request(f)).status, 502);
});

test('startup collision closes every already-started listener', async t => {
  const blocker = net.createServer();
  blocker.listen(0, '127.0.0.1');
  await once(blocker, 'listening');
  t.after(() => new Promise(done => blocker.close(done)));
  const proxy = createLanProxy({
    bindAddress: '127.0.0.1', lanAddress: '127.0.0.1', allowLoopback: true,
    listeners: [
      { port: 0, upstreamPort: 1, privatePort: 8795 },
      { port: blocker.address().port, upstreamPort: 1, privatePort: 8796 },
    ],
  }, quiet);
  await assert.rejects(proxy.start(), { code: 'EADDRINUSE' });
  assert.ok(proxy.servers.every(server => !server.listening));
  await proxy.close();
});
