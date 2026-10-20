import http from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
  ['/theme.js', ['theme.js', 'text/javascript; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/sites.json', ['sites.json', 'application/json; charset=utf-8']],
  ['/favicon.svg', ['favicon.svg', 'image/svg+xml']],
  ['/apple-touch-icon.png', ['apple-touch-icon.png', 'image/png']],
]);

export function createServer() {
  const content = new Map([...files].map(([url, [name, type]]) => [
    url, { body: readFileSync(new URL(name, import.meta.url)), type },
  ]));
  const inventory = JSON.parse(content.get('/sites.json').body);
  if (!Array.isArray(inventory.sites) || !inventory.sites.length) throw new Error('Inventory has no sites.');
  return http.createServer((req, res) => {
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'self' https://site-dock.jimlertech.com https://jimbrownhome1.tail8ad282.ts.net:8790");
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cache-Control', 'no-store');
    if (!['GET', 'HEAD'].includes(req.method)) {
      res.writeHead(405, { Allow: 'GET, HEAD' }).end('Read-only directory');
      return;
    }
    const url = req.url.split('?')[0];
    const file = url === '/health' ? { body: Buffer.from('{"status":"ok"}'), type: 'application/json' } : content.get(url);
    if (!file) {
      res.writeHead(404).end('Not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': file.type, 'Content-Length': file.body.length });
    res.end(req.method === 'HEAD' ? undefined : file.body);
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 18798);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be an integer from 1 to 65535.');
  const server = createServer();
  server.on('error', (error) => {
    console.error('Solution directory server failed:', error);
    process.exitCode = 1;
  });
  server.listen(port, '127.0.0.1', () => console.log(`Solution directory listening at http://127.0.0.1:${port}`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
}
