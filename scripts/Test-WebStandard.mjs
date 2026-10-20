#!/usr/bin/env node
// Read-only live check of every app in site/sites.json against
// copilot/global-instructions/web-standards.instructions.md. Write requests from the apps are blocked.
//
//   node scripts/Test-WebStandard.mjs                 Tailscale URLs, headless
//   node scripts/Test-WebStandard.mjs --public        Cloudflare URLs with the saved Access session
//   node scripts/Test-WebStandard.mjs --public --signin   Opens Edge once so you can sign in to Access
//   --app fit-track,plex   limit the run      --no-open   do not open the HTML report
import { chromium } from 'playwright-core';
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const devRoot = resolve(repo, '..');
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const publicMode = flag('--public');
const signIn = flag('--signin');
const only = args.includes('--app') ? args[args.indexOf('--app') + 1].split(',') : null;
const profileDir = join(process.env.LOCALAPPDATA ?? repo, 'JimlerTech', 'SolutionDeploy', 'web-standard-profile');

// Theme storage per app. Excluded apps are reported but never fail the run.
const apps = {
    'ferry-tracker': { key: 'ferry-tracker-theme' },
    'home-automation': { key: 'smart-devices-theme' },
    'site-dock': { key: 'sitedock.theme' },
    'fit-track': { key: 'fittrack_theme' },
    'web-bookmarks': { key: null, excluded: true },
    plex: { key: 'plex-theme' },
    'work-log': { key: 'wl_theme', skip: ['api'], hide: '#helpbar' }, // api/ is the retired Azure Functions copy; helpbar is a first-visit overlay
    'web-inventory': { key: 'theme' },
    'web-portfolio': { key: 'config_theme_preference', json: true, excluded: true, skip: ['scripts'] },
    'web-options': { key: 'config_theme_preference' },
    'solution-deploy': { key: 'solution-deploy-theme', source: 'solution-deploy/site' },
};
const MIDNIGHT = ['#020617', '#0f172a'];
const LIGHT = ['#ffffff'];

const sites = JSON.parse(readFileSync(join(repo, 'site', 'sites.json'), 'utf8')).sites.filter(
    (s) => !only || only.includes(s.id)
);

function hex(rgb) {
    const m = String(rgb).match(/\d+(\.\d+)?/g);
    if (!m) return String(rgb).toLowerCase();
    return (
        '#' +
        m
            .slice(0, 3)
            .map((n) => Number(n).toString(16).padStart(2, '0'))
            .join('')
    );
}

// Native <select>/<datalist> in app source. Tests, docs and build output are skipped.
const skipDirs = new Set([
    'node_modules',
    'dist',
    'build',
    'coverage',
    '.git',
    'test',
    'tests',
    'docs',
    'wwwroot',
    'bin',
    'obj',
    '.venv',
    '__pycache__',
    'reports',
    'artifacts',
    '.local',
    'playwright-report',
    'test-results',
]);
const srcExt = new Set(['.html', '.tsx', '.jsx', '.ts', '.js', '.mjs', '.ps1', '.psm1', '.py', '.cshtml', '.razor']);
const nativeRe = /<(select|datalist)[\s>]|createElement\(\s*['"](select|datalist)['"]/;
function scanNative(dir, skip = [], found = []) {
    let entries;
    try {
        entries = readdirSync(dir);
    } catch {
        return found;
    }
    for (const name of entries) {
        const p = join(dir, name);
        const st = statSync(p);
        if (st.isDirectory()) {
            if (!skipDirs.has(name) && !skip.includes(name)) scanNative(p, [], found);
            continue;
        }
        if (!srcExt.has(extname(name)) || /\.(test|spec)\./.test(name) || st.size > 2e6) continue;
        readFileSync(p, 'utf8')
            .split('\n')
            .forEach((line, i) => {
                if (nativeRe.test(line)) found.push(`${relative(devRoot, p)}:${i + 1}`);
            });
    }
    return found;
}

async function pageState(page, hide) {
    return page.evaluate((hide) => {
        if (hide) document.querySelectorAll(hide).forEach((e) => (e.style.display = 'none'));
        const root = document.documentElement;
        const bgOf = (el) => {
            for (let e = el; e; e = e.parentElement) {
                const c = getComputedStyle(e).backgroundColor;
                if (c && !/rgba\(.*,\s*0\)$/.test(c) && c !== 'transparent') return c;
            }
            return getComputedStyle(root).backgroundColor;
        };
        return {
            classes: root.className,
            dataTheme: root.dataset.theme ?? '',
            themeColor: document.querySelector('meta[name="theme-color"]')?.content ?? '',
            topColor: bgOf(document.elementFromPoint(innerWidth / 2, 2)),
        };
    }, hide ?? null);
}
const resolvedAs = (s, want) => (want === 'midnight' ? MIDNIGHT : LIGHT).includes(s.themeColor.toLowerCase());

async function checkApp(context, site, cfg) {
    const base = publicMode ? site.cloudflareUrl : site.tailscaleUrl;
    const origin = new URL(base).origin;
    const checks = [];
    const add = (name, ok, detail = '') => checks.push({ name, ok: Boolean(ok), detail: String(detail) });
    const errors = [];
    let writes = 0;
    const page = await context.newPage();
    await page.route('**/*', (route) => {
        const r = route.request();
        if (new URL(r.url()).origin === origin && !['GET', 'HEAD', 'OPTIONS'].includes(r.method())) {
            writes++;
            return route.abort();
        }
        return route.continue();
    });
    page.on('console', (m) => {
        // Third-party failures (Site Dock probes favorite icons) are outside the app's control.
        const at = m.location()?.url ?? '';
        const framed = m.text().match(/^Framing '([^']+)'/)?.[1];
        if (framed && !framed.startsWith(origin)) return;
        if (m.type() === 'error' && (!at || at.startsWith(origin))) errors.push(m.text().slice(0, 200));
    });
    page.on('pageerror', (e) => errors.push(String(e.message).slice(0, 200)));
    page.on('dialog', (d) => d.dismiss().catch(() => {}));
    await page.setViewportSize({ width: 1024, height: 800 });
    const load = async () => {
        await page.goto(base, { waitUntil: 'load', timeout: 30000 });
        await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
    };
    try {
        await page.emulateMedia({ colorScheme: 'light' });
        await load();
        if (/cloudflareaccess\.com/.test(page.url())) {
            add('Access session', false, 'Sign-in needed: run with --public --signin');
            return { site, cfg, checks, errors, writes };
        }
        add('Page loads', true, page.url());

        if (cfg.key) {
            const setPref = (v) =>
                page.evaluate(
                    ([k, val]) => {
                        if (val === null) localStorage.removeItem(k);
                        else localStorage.setItem(k, val);
                    },
                    [cfg.key, v === null ? null : cfg.json ? JSON.stringify(v) : v]
                );
            await setPref(null);
            await load();
            let s = await pageState(page, cfg.hide);
            add('Default is Midnight (OS light)', resolvedAs(s, 'midnight'), `theme-color ${s.themeColor}`);
            add(
                'theme-color matches top bar',
                hex(s.topColor) === s.themeColor.toLowerCase(),
                `top ${hex(s.topColor)}, meta ${s.themeColor}`
            );
            await page.emulateMedia({ colorScheme: 'dark' });
            await setPref('system');
            await load();
            s = await pageState(page, cfg.hide);
            add('System + OS dark = Midnight', resolvedAs(s, 'midnight'), `theme-color ${s.themeColor}`);
            await page.emulateMedia({ colorScheme: 'light' });
            await page.waitForTimeout(600);
            s = await pageState(page, cfg.hide);
            add('System follows live OS change', resolvedAs(s, 'light'), `theme-color ${s.themeColor}`);
            add(
                'theme-color matches top bar (light)',
                hex(s.topColor) === s.themeColor.toLowerCase(),
                `top ${hex(s.topColor)}, meta ${s.themeColor}`
            );
            await setPref(null);
            await page.emulateMedia({ colorScheme: 'dark' });
            await load();
        } else {
            add('Theme preference', true, 'Not checked (no known storage key)');
        }

        const head = await page.evaluate(() => {
            const meta = (n) => document.querySelector(`meta[name="${n}"]`)?.content ?? null;
            return {
                title: document.title,
                viewport: meta('viewport') ?? '',
                appTitle: meta('apple-mobile-web-app-title'),
                capable: meta('mobile-web-app-capable'),
                statusBar: meta('apple-mobile-web-app-status-bar-style'),
                themeColor: meta('theme-color'),
                touchIcon: document.querySelector('link[rel="apple-touch-icon"]')?.getAttribute('href') ?? null,
                svgIcon: document.querySelector('link[rel="icon"][type="image/svg+xml"]')?.getAttribute('href') ?? null,
            };
        });
        add('Title has display name', head.title.includes(site.name), head.title);
        add('apple-mobile-web-app-title', head.appTitle === site.name, head.appTitle ?? 'missing');
        add(
            'viewport-fit=cover, no zoom lock',
            /viewport-fit=cover/.test(head.viewport) && !/user-scalable=no|maximum-scale=1(\.0)?\b/.test(head.viewport),
            head.viewport
        );
        add('No status-bar-style meta', head.statusBar === null, head.statusBar ?? '');
        add('theme-color meta', Boolean(head.themeColor), head.themeColor ?? 'missing');
        add('mobile-web-app-capable', head.capable === 'yes', head.capable ?? 'missing');
        add('apple-touch-icon link', Boolean(head.touchIcon), head.touchIcon ?? 'missing');
        add('SVG favicon link', Boolean(head.svgIcon), head.svgIcon ?? 'missing');

        const svg = await context.request.get(origin + '/favicon.svg');
        add(
            '/favicon.svg',
            svg.status() === 200 && /svg/.test(svg.headers()['content-type'] ?? ''),
            `${svg.status()} ${svg.headers()['content-type'] ?? ''}`
        );
        const png = await context.request.get(origin + '/apple-touch-icon.png');
        const bytes = png.status() === 200 ? await png.body() : Buffer.alloc(0);
        const size = bytes.length > 24 ? `${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}` : 'none';
        add('/apple-touch-icon.png 180x180', size === '180x180', `${png.status()} ${size}`);

        const font = await page.evaluate(async () => {
            await document.fonts.ready;
            return {
                family: getComputedStyle(document.body).fontFamily,
                loaded: document.fonts.check('16px "Roboto Flex"'),
            };
        });
        add(
            'Roboto Flex body font',
            /^["']?Roboto Flex/.test(font.family) && !/\bInter\b/.test(font.family),
            font.family.slice(0, 80)
        );
        add('Roboto Flex loaded', font.loaded);

        const native = await page.locator('select, datalist').count();
        add('No native dropdowns on page', native === 0, native ? `${native} found` : '');

        // One theme control in the top bar, aligned with the controls next to it.
        const bar = await page.evaluate(() => {
            const vis = [...document.querySelectorAll('button,[role=combobox],[aria-haspopup]')]
                .map((e) => ({ e, r: e.getBoundingClientRect() }))
                .filter(({ r }) => r.width > 0 && r.height > 0 && r.top < 120 && r.left > innerWidth / 2)
                .filter(({ e }, i, a) => !a.some((o, j) => j !== i && o.e.contains(e)));
            const label = (e) => `${e.getAttribute('aria-label') ?? ''} ${e.title ?? ''} ${e.textContent ?? ''}`.trim();
            const theme = vis.filter(({ e }) => /\btheme\b|appearance|^(system|light|midnight|dark)\b/i.test(label(e)));
            if (theme.length !== 1)
                return { count: theme.length, labels: theme.map(({ e }) => label(e).slice(0, 30)), off: [] };
            const t = theme[0].r;
            const off = vis
                .filter(({ r }) => r.bottom > t.top && r.top < t.bottom)
                .filter(({ r }) => Math.abs(r.top - t.top) > 2 || Math.abs(r.height - t.height) > 2)
                .map(({ e, r }) => `${label(e).slice(0, 20)} top ${Math.round(r.top)} h ${Math.round(r.height)}`);
            return { count: 1, labels: [], off, at: `top ${Math.round(t.top)} h ${Math.round(t.height)}` };
        });
        add('One header theme control', bar.count <= 1, bar.labels.join(' | '));
        add(
            'Header controls aligned',
            bar.off.length === 0,
            bar.off.length ? `theme ${bar.at}; ${bar.off.join(', ')}` : ''
        );

        await page.setViewportSize({ width: 390, height: 844 });
        await page.waitForTimeout(400);
        const width = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
        add('No sideways scroll at 390px', width[0] <= width[1] + 1, `${width[0]} / ${width[1]}`);
    } catch (e) {
        add('Run', false, e.message.split('\n')[0]);
    } finally {
        await page.close();
    }
    const src = scanNative(join(devRoot, cfg.source ?? site.id), cfg.skip);
    add(
        'No native dropdowns in source',
        src.length === 0,
        src.slice(0, 8).join(', ') + (src.length > 8 ? ` +${src.length - 8}` : '')
    );
    add('No console or CSP errors', errors.length === 0, errors.slice(0, 3).join(' | '));
    add('No write requests', writes === 0, writes ? `${writes} blocked` : '');
    return { site, cfg, checks, errors, writes };
}

function report(results, started) {
    const esc = (s) =>
        String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
    const fails = results.filter((r) => !r.cfg.excluded).flatMap((r) => r.checks.filter((c) => !c.ok)).length;
    const rows = results
        .map((r) => {
            const bad = r.checks.filter((c) => !c.ok).length;
            const k = r.cfg.excluded ? 'na' : bad ? 'bad' : 'ok';
            const items = r.checks
                .map(
                    (c) =>
                        `<li class="${c.ok ? 'ok' : r.cfg.excluded ? 'na' : 'bad'}"><span class="dot"></span>` +
                        `<b>${esc(c.name)}</b>${c.detail ? ` <code>${esc(c.detail)}</code>` : ''}</li>`
                )
                .join('');
            return `<div class="card ${k}"><header><h3>${esc(r.site.name)}</h3><span class="pill">${r.cfg.excluded ? 'excluded' : bad ? `${bad} failing` : 'pass'}</span></header><ul>${items}</ul></div>`;
        })
        .join('');
    const when = new Date().toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' });
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Web standard check</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap" rel="stylesheet">
<script>(function(){var t=localStorage.getItem('wsc-theme')||(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark');document.documentElement.dataset.theme=t})()</script>
<style>:root{--bg:#020617;--panel:#0f172a;--line:#293548;--text:#f1f5f9;--muted:#94a3b8;--accent:#818cf8;--ok:#34d399;--bad:#f87171;--na:#64748b}
[data-theme=light]{--bg:#fff;--panel:#f8fafc;--line:#e2e8f0;--text:#0f172a;--muted:#475569;--accent:#4f46e5;--ok:#059669;--bad:#dc2626;--na:#94a3b8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 Inter,system-ui,sans-serif}.wrap{max-width:1400px;margin:0 auto;padding:28px}
.top{display:flex;gap:16px;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:16px}h1{margin:0;font-size:22px}h1 span{color:var(--accent)}.sub{color:var(--muted)}
button{margin-left:auto;background:var(--panel);color:var(--text);border:1px solid var(--line);padding:7px 12px;font:inherit;cursor:pointer}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:12px;margin-top:20px}.card{background:var(--panel);border:1px solid var(--line);border-top:3px solid var(--k);padding:12px 16px}
.card header{display:flex;align-items:center}.card h3{margin:0 auto 0 0;font-size:15px}.pill{font-size:11px;padding:2px 8px;border:1px solid var(--k);color:var(--k)}
ul{list-style:none;margin:10px 0 0;padding:0}li{margin:5px 0;font-size:12.5px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--k);margin-right:8px}
code{font:11.5px Consolas,monospace;color:var(--muted);word-break:break-all}.ok{--k:var(--ok)}.bad{--k:var(--bad)}.na{--k:var(--na)}</style></head><body><div class="wrap">
<div class="top"><div><h1>Web standard <span>check</span></h1><div class="sub">${results.length} apps via ${publicMode ? 'Cloudflare (signed in)' : 'Tailscale'} /
${fails} failing checks / ${when} (local) / ${Math.round((Date.now() - started) / 1000)}s</div>
<div class="sub">Read-only: write requests blocked. iPhone and iPad rendering still needs a device check.</div></div>
<button onclick="var t=document.documentElement.dataset.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=t;localStorage.setItem('wsc-theme',t)">Theme</button></div>
<div class="cards">${rows}</div></div></body></html>`;
}

const started = Date.now();
const APP_TIMEOUT_MS = 120000;
const launch = { channel: 'msedge', headless: !signIn };
let browser = null;
const context = publicMode
    ? await chromium.launchPersistentContext(profileDir, launch)
    : await (browser = await chromium.launch(launch)).newContext();
try {
    // Headed Edge shuts down when its last tab closes. Keep an anchor tab between app checks.
    const anchor = context.pages()[0] ?? (await context.newPage());
    if (signIn) {
        await anchor.goto(sites[0].cloudflareUrl);
        console.log('Sign in to Cloudflare Access in the Edge window. Waiting up to 5 minutes...');
        await anchor.waitForURL((u) => u.origin === new URL(sites[0].cloudflareUrl).origin, { timeout: 300000 });
        await anchor.goto('about:blank');
    }
    const results = [];
    for (const site of sites) {
        const cfg = apps[site.id] ?? { key: null };
        let timer;
        const r = await Promise.race([
            checkApp(context, site, cfg),
            new Promise((done) => {
                timer = setTimeout(
                    () =>
                        done({
                            site,
                            cfg,
                            errors: [],
                            writes: 0,
                            checks: [{ name: 'Run', ok: false, detail: `No result after ${APP_TIMEOUT_MS / 1000}s` }],
                        }),
                    APP_TIMEOUT_MS
                );
            }),
        ]);
        clearTimeout(timer);
        for (const p of context.pages()) if (p !== anchor) await p.close().catch(() => {});
        const bad = r.checks.filter((c) => !c.ok);
        console.log(
            `${bad.length ? (cfg.excluded ? 'INFO' : 'FAIL') : 'PASS'} ${site.name}` +
                bad.map((c) => `\n     - ${c.name}${c.detail ? `: ${c.detail}` : ''}`).join('')
        );
        results.push(r);
    }
    const outDir = join(repo, 'reports');
    mkdirSync(outDir, { recursive: true });
    const out = join(outDir, `web-standard-${publicMode ? 'public' : 'tailscale'}.html`);
    writeFileSync(out, report(results, started));
    console.log(`Report: ${out}`);
    if (!flag('--no-open')) execFile('cmd', ['/c', 'start', '', out]);
    process.exitCode = results.some((r) => !r.cfg.excluded && r.checks.some((c) => !c.ok)) ? 1 : 0;
} finally {
    await context.close();
    await browser?.close();
}
