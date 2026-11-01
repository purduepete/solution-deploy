import http from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { isIPv4 } from 'node:net';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';

const files = new Map([
    ['/', ['index.html', 'text/html; charset=utf-8']],
    ['/style.css', ['style.css', 'text/css; charset=utf-8']],
    ['/theme.js', ['theme.js', 'text/javascript; charset=utf-8']],
    ['/loading.js', ['loading.js', 'text/javascript; charset=utf-8']],
    ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
    ['/collectors', ['collectors.html', 'text/html; charset=utf-8']],
    ['/collectors.js', ['collectors.js', 'text/javascript; charset=utf-8']],
    ['/sites.json', ['sites.json', 'application/json; charset=utf-8']],
    ['/favicon.svg', ['favicon.svg', 'image/svg+xml']],
    ['/apple-touch-icon.png', ['apple-touch-icon.png', 'image/png']],
]);

// Written every 5 minutes by scripts/Update-CollectorStatus.ps1, so it is read per request, never cached.
const defaultStatusPath = fileURLToPath(new URL('../data/collector-status.json', import.meta.url));
const defaultReleaseInventoryPath = fileURLToPath(new URL('../environments/releases.json', import.meta.url));
// One file per app and component, written by CommonRelease.psm1 after each successful release.
const defaultReleaseRecordsPath = fileURLToPath(new URL('../data/releases', import.meta.url));
const faviconTypes = new Set([
    'image/svg+xml',
    'image/x-icon',
    'image/vnd.microsoft.icon',
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
]);
const maxFaviconBytes = 512 * 1024;

export async function readFavicon(site, hostname) {
    const source = new URL(site.localUrl);
    const path = site.faviconPath ?? '/favicon.svg';
    if (source.protocol !== 'http:' || !isIPv4(source.hostname) || source.username || source.password)
        throw new Error('Favicon source must be a LAN HTTP IPv4 URL without credentials.');
    if (
        typeof path !== 'string' ||
        !/^\/(?:[a-z0-9._-]+\/)*[a-z0-9._-]+$/i.test(path) ||
        path.split('/').includes('..')
    )
        throw new Error('Favicon path must be a root-relative file path.');

    return new Promise((resolve, reject) => {
        const request = http.get(
            {
                hostname,
                family: 4,
                port: source.port || 80,
                path,
                // The host can resolve its own .local name to Tailscale before the LAN address.
                lookup: (_name, _options, callback) => callback(null, source.hostname, 4),
                headers: { Host: source.host, 'Accept-Encoding': 'identity' },
            },
            (response) => {
                const type = (response.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
                if (response.statusCode !== 200 || !faviconTypes.has(type)) {
                    response.resume();
                    reject(
                        new Error(`Favicon returned HTTP ${response.statusCode} with content type ${type || 'none'}.`)
                    );
                    return;
                }
                const chunks = [];
                let size = 0;
                response.on('data', (chunk) => {
                    size += chunk.length;
                    if (size > maxFaviconBytes) {
                        response.destroy(new Error('Favicon exceeds the 512 KiB limit.'));
                        return;
                    }
                    chunks.push(chunk);
                });
                response.on('error', reject);
                response.on('end', () => {
                    if (!size) reject(new Error('Favicon response was empty.'));
                    else resolve({ body: Buffer.concat(chunks), type });
                });
            }
        );
        const timer = setTimeout(() => request.destroy(new Error('Favicon request timed out.')), 5000);
        request.on('error', reject);
        request.on('close', () => clearTimeout(timer));
    });
}

export async function readReleaseRecords(directory) {
    let names;
    try {
        names = await readdir(directory);
    } catch {
        return [];
    }
    const records = [];
    for (const name of names.filter((file) => /^[a-z0-9-]+--[a-z0-9-]+\.json$/.test(file))) {
        try {
            const record = JSON.parse(await readFile(join(directory, name), 'utf8'));
            if (
                /^[a-z0-9-]+$/.test(record.app) &&
                /^[a-z0-9-]+$/.test(record.component) &&
                /^[a-f0-9]{40}$/.test(record.sourceCommit) &&
                !Number.isNaN(Date.parse(record.completedLocal))
            )
                records.push(record);
        } catch {
            // A record being rewritten or damaged is skipped; the rest still show.
        }
    }
    return records;
}

export function withReleaseRecords(deployments, records) {
    return {
        ...deployments,
        solutions: deployments.solutions.map((solution) => {
            const releases = records
                .filter((record) => record.app === solution.id)
                // A controller release records the whole app as 'app'; it releases every listed component.
                .flatMap((record) =>
                    (record.component === 'app' ? solution.components : [record.component]).map((component) => ({
                        component,
                        commit: record.sourceCommit.slice(0, 7),
                        completed: new Date(record.completedLocal).toISOString(),
                    }))
                )
                .sort((a, b) => b.completed.localeCompare(a.completed));
            return { ...solution, releases, lastRelease: releases[0] || null };
        }),
    };
}

export function publicDeployments(releases, inventory) {
    const methods = {
        controller: ['Controller Release', 'The existing protected controller runs the complete routine release.'],
        'fit-track': [
            'Fit Track Release',
            'Fit Track release of the full frontend and backend through the common Release command.',
        ],
        'hand-placed': [
            'Release Folder Swap',
            'Builds the pushed commit, stages a new release folder, then restarts the app on it through the common Release command.',
        ],
        shared: [
            'Shared Component Release',
            'Releases one named host component from the pushed commit through the common Release command, then confirms it.',
        ],
        blocked: ['Procedure Unverified', 'The common release procedure is not yet verified for this solution.'],
        manual: ['Manual Update', 'This installation uses a manual or distribution update, not a Git release.'],
    };
    return {
        scope: 'Maintained deployment inventory, not a live deployment check.',
        solutions: inventory.sites.map(({ id }) => {
            const entry = releases.apps?.[id];
            const method = methods[entry?.procedure];
            if (
                !method ||
                !Array.isArray(entry.components) ||
                !entry.components.length ||
                !entry.components.every((name) => typeof name === 'string' && name.trim()) ||
                typeof entry.versionEvidence !== 'string' ||
                !entry.versionEvidence.trim() ||
                (['blocked', 'manual'].includes(entry.procedure) && !entry.blocker?.trim())
            )
                throw new Error(`Deployment inventory is incomplete for ${id}.`);
            // Explicit public fields only. Never publish internal paths, secrets, task actions or release requests.
            return {
                id,
                support: method[0],
                method: method[1],
                components: entry.components,
                versionEvidence: entry.versionEvidence,
                blocker: entry.blocker || null,
                componentNote: entry.watcherBlocker || entry.componentNote || null,
                explicitComponents: entry.explicitComponents === true,
                privateOnly: entry.privateOnly === true,
                repository: entry.procedure === 'manual' ? null : `https://github.com/purduepete/${id}`,
                procedureUrl:
                    'https://github.com/purduepete/solution-deploy/blob/main/docs/Deployment.md#one-entry-point-existing-procedures',
            };
        }),
    };
}

export function createServer({
    statusPath = process.env.COLLECTOR_STATUS_PATH || defaultStatusPath,
    releaseInventoryPath = defaultReleaseInventoryPath,
    releaseRecordsPath = process.env.RELEASE_RECORDS_PATH || defaultReleaseRecordsPath,
    faviconLoader = readFavicon,
    logger = console,
} = {}) {
    const content = new Map(
        [...files].map(([url, [name, type]]) => [url, { body: readFileSync(new URL(name, import.meta.url)), type }])
    );
    const inventory = JSON.parse(content.get('/sites.json').body);
    if (!Array.isArray(inventory.sites) || !inventory.sites.length) throw new Error('Inventory has no sites.');
    const deployments = publicDeployments(JSON.parse(readFileSync(releaseInventoryPath, 'utf8')), inventory);
    const faviconSites = new Map(
        inventory.sites.filter((site) => site.faviconPath !== null).map((site) => [site.id, site])
    );
    return http.createServer(async (req, res) => {
        res.setHeader(
            'Content-Security-Policy',
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'self' https://site-dock.jimlertech.com https://jimbrownhome1.tail8ad282.ts.net:8790"
        );
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Referrer-Policy', 'no-referrer');
        res.setHeader('Cache-Control', 'no-store');
        if (!['GET', 'HEAD'].includes(req.method)) {
            res.writeHead(405, { Allow: 'GET, HEAD' }).end('Read-only directory');
            return;
        }
        const url = req.url.split('?')[0];
        if (url.startsWith('/site-favicons/')) {
            const id = url.slice('/site-favicons/'.length);
            const site = faviconSites.get(id);
            if (!site) {
                res.writeHead(404).end('Favicon not found');
                return;
            }
            try {
                const icon = await faviconLoader(site, `${inventory.host}.local`);
                res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
                res.writeHead(200, { 'Content-Type': icon.type, 'Content-Length': icon.body.length });
                res.end(req.method === 'HEAD' ? undefined : icon.body);
            } catch (error) {
                logger.warn(`Cannot load favicon for ${id}: ${error.message}`);
                res.writeHead(502).end('Favicon unavailable');
            }
            return;
        }
        if (url === '/deployments.json') {
            const body = Buffer.from(
                JSON.stringify(withReleaseRecords(deployments, await readReleaseRecords(releaseRecordsPath)))
            );
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length });
            res.end(req.method === 'HEAD' ? undefined : body);
            return;
        }
        if (url === '/collector-status.json') {
            let body;
            try {
                body = await readFile(statusPath);
            } catch {
                res.writeHead(503, { 'Content-Type': 'application/json' }).end(
                    '{"error":"Collector status unavailable"}'
                );
                return;
            }
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length });
            res.end(req.method === 'HEAD' ? undefined : body);
            return;
        }
        const file =
            url === '/health' ? { body: Buffer.from('{"status":"ok"}'), type: 'application/json' } : content.get(url);
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
    if (!Number.isInteger(port) || port < 1 || port > 65535)
        throw new Error('PORT must be an integer from 1 to 65535.');
    const server = createServer();
    server.on('error', (error) => {
        console.error('Solution directory server failed:', error);
        process.exitCode = 1;
    });
    server.listen(port, '127.0.0.1', () => console.log(`Solution directory listening at http://127.0.0.1:${port}`));
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
}
