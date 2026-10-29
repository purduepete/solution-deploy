import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer, publicDeployments } from '../site/server.mjs';
import { runInNewContext } from 'node:vm';

test('deployment information covers every solution and exposes only public fields', () => {
    const inventory = JSON.parse(readFileSync(new URL('../site/sites.json', import.meta.url)));
    const releases = JSON.parse(readFileSync(new URL('../environments/releases.json', import.meta.url)));
    releases.apps.pgweb.connectionString = 'PRIVATE_SENTINEL';
    releases.apps.pgweb.taskAction = 'PRIVATE_SENTINEL';
    const result = publicDeployments(releases, inventory);
    assert.equal(result.solutions.length, 15);
    assert.deepEqual(result.solutions.map((entry) => entry.id).sort(), inventory.sites.map((entry) => entry.id).sort());
    assert.match(result.scope, /not a live deployment check/);
    assert(!JSON.stringify(result).includes('PRIVATE_SENTINEL'));
    assert(!JSON.stringify(result).includes('C:\\\\'));
    for (const entry of result.solutions) {
        assert.deepEqual(Object.keys(entry).sort(), [
            'blocker',
            'componentNote',
            'components',
            'explicitComponents',
            'id',
            'method',
            'privateOnly',
            'procedureUrl',
            'repository',
            'support',
            'versionEvidence',
        ]);
        assert(entry.versionEvidence.trim());
        assert(entry.components.length);
    }
    assert.equal(result.solutions.find((entry) => entry.id === 'team-scoreboard').support, 'Controller Release');
    assert.equal(result.solutions.find((entry) => entry.id === 'fit-track').support, 'Fit Track Release');
    for (const id of ['web-bookmarks', 'work-log', 'web-inventory', 'plex', 'web-options', 'web-portfolio'])
        assert.equal(result.solutions.find((entry) => entry.id === id).support, 'Release Folder Swap');
    assert.match(result.solutions.find((entry) => entry.id === 'web-options').componentNote, /pinned-job/);
    const shared = result.solutions.find((entry) => entry.id === 'solution-deploy');
    assert.equal(shared.support, 'Shared Component Release');
    assert.equal(shared.blocker, null);
    for (const id of ['ride-and-lift', 'pgweb']) {
        const entry = result.solutions.find((solution) => solution.id === id);
        assert.equal(entry.support, 'Manual Update');
        assert.equal(entry.privateOnly, true);
        assert.equal(entry.repository, null);
    }
    delete releases.apps.plex;
    assert.throws(() => publicDeployments(releases, inventory), /incomplete for plex/);
});

test('deployment sections use accessible disclosures and render recorded evidence as text', () => {
    const source = readFileSync(new URL('../site/app.js', import.meta.url), 'utf8');
    const code = source.slice(
        source.indexOf('function deploymentSection('),
        source.indexOf('\nasync function loadDeployments(')
    );
    const element = (tag, text, className) => ({
        tag,
        text,
        className,
        children: [],
        append(...children) {
            this.children.push(...children);
        },
    });
    const render = runInNewContext(`${code}\ndeploymentSection`, { element });
    const section = render({
        support: 'Procedure Unverified',
        method: 'A recorded procedure',
        components: ['web', 'stock-collector'],
        versionEvidence: '<img src=x onerror=alert(1)>',
        blocker: 'Verify the publisher',
        componentNote: 'Preserve the watcher',
        privateOnly: true,
        explicitComponents: true,
        procedureUrl: 'https://github.com/purduepete/solution-deploy',
        lastRelease: { component: 'web', commit: 'abcdef1', completed: '2026-07-12T21:05:00.000Z' },
        releases: [{ component: 'web', commit: 'abcdef1', completed: '2026-07-12T21:05:00.000Z' }],
    });
    assert.equal(section.tag, 'section');
    const details = section.children[2];
    assert.equal(details.tag, 'details');
    assert.equal(details.children[0].tag, 'summary');
    const flatten = (node) => [node, ...node.children.flatMap(flatten)];
    const nodes = flatten(section);
    assert.match(section.children[1].text, /^Last Release: \d{2}\/\d{2}\/2026 \d{2}:05$/);
    assert(nodes.some((node) => /^Web: \d{2}\/\d{2}\/2026 \d{2}:05 \(abcdef1\)$/.test(node.text)));
    assert(nodes.some((node) => node.text === 'Stock Collector: Not recorded'));
    assert(nodes.some((node) => node.text === 'Procedure Unverified'));
    assert(nodes.some((node) => node.text === 'Stock Collector'));
    assert(nodes.some((node) => node.text === '<img src=x onerror=alert(1)>'));
    assert(nodes.some((node) => node.text === 'Verify the publisher'));
    assert(nodes.some((node) => node.text?.includes('Private-only')));
    assert.match(source, /card\.textContent/);
    assert.doesNotMatch(source, /innerHTML/);
});

test('site sorting supports alphabetical and newest deployment order', () => {
    const source = readFileSync(new URL('../site/app.js', import.meta.url), 'utf8');
    const code = source.slice(
        source.indexOf('function compareSites('),
        source.indexOf('\nasync function loadDeployments()')
    );
    const compareSites = runInNewContext(`${code}\ncompareSites`);
    const sites = [
        { id: 'zulu', name: 'Zulu' },
        { id: 'alpha', name: 'Alpha' },
        { id: 'beta', name: 'Beta' },
        { id: 'gamma', name: 'Gamma' },
    ];
    const deployments = new Map([
        ['zulu', { lastRelease: { completed: '2026-10-20T12:00:00.000Z' } }],
        ['alpha', { lastRelease: { completed: '2026-10-24T12:00:00.000Z' } }],
        ['beta', { lastRelease: null }],
        ['gamma', { lastRelease: { completed: '2026-10-24T12:00:00.000Z' } }],
    ]);
    assert.deepEqual(
        sites.toSorted((a, b) => compareSites(a, b, 'alphabetical', deployments)).map((site) => site.name),
        ['Alpha', 'Beta', 'Gamma', 'Zulu']
    );
    assert.deepEqual(
        sites.toSorted((a, b) => compareSites(a, b, 'deployment-date', deployments)).map((site) => site.name),
        ['Alpha', 'Gamma', 'Zulu', 'Beta']
    );
    const page = readFileSync(new URL('../site/index.html', import.meta.url), 'utf8');
    assert.match(page, /id="sort-alpha"[\s\S]*?aria-pressed="true"[\s\S]*?data-sort-mode="alphabetical"/);
    assert.match(page, /id="sort-deployment"[\s\S]*?aria-pressed="false"[\s\S]*?data-sort-mode="deployment-date"/);
    assert.match(page, /aria-label="Sort by deployment date, newest first"/);
    assert.doesNotMatch(page, /<(select|datalist)\b/i);
});

test('sort preference restores valid saved choices and handles unavailable storage', () => {
    const source = readFileSync(new URL('../site/app.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('function readSortMode('), source.indexOf('\nfunction compareSites('));
    for (const saved of [null, 'alphabetical', 'deployment-date', 'invalid']) {
        const read = runInNewContext(`${code}\nreadSortMode`, {
            localStorage: {
                getItem(key) {
                    assert.equal(key, 'solution-deploy-sort');
                    return saved;
                },
            },
        });
        assert.equal(read(), saved === 'deployment-date' ? saved : 'alphabetical');
    }
    const warnings = [];
    const read = runInNewContext(`${code}\nreadSortMode`, {
        localStorage: {
            getItem() {
                throw new Error('Storage blocked');
            },
        },
        console: { warn: (...args) => warnings.push(args) },
    });
    assert.equal(read(), 'alphabetical');
    assert.equal(warnings.length, 1);
    assert.match(warnings[0][0], /Cannot read the saved site sort order/);
});

test('sort selection uses square corners and a reduced-motion-aware sliding fill', () => {
    const css = readFileSync(new URL('../site/style.css', import.meta.url), 'utf8');
    for (const selector of ['sort-setting', 'sort-option']) {
        assert.match(css, new RegExp(`\\.${selector} \\{[^}]*border-radius: 0;`));
    }
    assert.match(css, /\.sort-setting::before \{[^}]*transition: transform 0\.25s ease-out;/);
    assert.match(css, /\.sort-setting\[data-sort-mode='deployment-date'\]::before \{[^}]*translateX\(40px\)/);
    assert.match(
        css,
        /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*\.sort-setting::before \{[^}]*transition: none;/
    );
});

test('deployment fetch failures are visible and preserve site-link loading', async () => {
    const source = readFileSync(new URL('../site/app.js', import.meta.url), 'utf8');
    const code = source.slice(
        source.indexOf('async function loadDeployments('),
        source.indexOf('\nasync function load()')
    );
    const banner = { textContent: '', hidden: true };
    const load = runInNewContext(`${code}\nloadDeployments`, {
        fetch: async () => ({ ok: false, status: 503 }),
        document: { getElementById: () => banner },
        console: { error() {} },
    });
    assert.equal(await load(), null);
    assert.equal(banner.hidden, false);
    assert.match(banner.textContent, /HTTP 503.*Site links remain available/);
});

test('history ranges include today and exactly the selected number of calendar days', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('function inHistoryRange('), source.indexOf('\nfunction render('));
    const includes = runInNewContext(`${code}\ninHistoryRange`);
    assert.equal(includes('2026-10-18', '2026-10-24', 7), true);
    assert.equal(includes('2026-10-17', '2026-10-24', 7), false);
    assert.equal(includes('2026-10-24', '2026-10-24', 7), true);
    assert.equal(includes('2026-10-25', '2026-10-24', 30), false);
    assert.equal(includes('2026-10-11', '2026-10-24', 14), true);
    assert.equal(includes('2026-09-25', '2026-10-24', 30), true);
    assert.equal(includes('2026-09-24', '2026-10-24', 30), false);
    assert.equal(includes('2026-10-27', '2026-11-02', 7), true);
    const page = readFileSync(new URL('../site/collectors.html', import.meta.url), 'utf8');
    for (const group of ['alerts', 'runs']) assert(page.includes(`id="${group}-range"`));
    assert.equal((page.match(/class="history-heading"/g) ?? []).length, 2);
    assert.doesNotMatch(page, /<(select|datalist)\b/i);
    assert.match(source, /option\.setAttribute\('role', 'menuitemradio'\)/);
    assert.match(source, /const historyDays = \{ alerts: 7, runs: 7 \}/);
});

test('collapsed job groups roll up card status', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('// A card has a problem'), source.indexOf('\nconst openGroupsKey'));
    const { jobProblem, jobGroupStatus } = runInNewContext(
        `const staleHeartbeatMs = 600000;\n${code}\n({ jobProblem, jobGroupStatus })`
    );
    const now = Date.parse('2026-10-29T16:40:00-07:00');
    const fresh = { heartbeatAt: '2026-10-29T16:39:00-07:00', lastError: 'capture_partial' };
    assert.equal(jobProblem({ status: 'complete' }, fresh, now), null);
    assert.equal(jobProblem({ status: 'running' }, fresh, now), null);
    assert.equal(jobProblem({ status: 'partial', vixOnly: true }, fresh, now), null);
    assert.equal(jobProblem({ status: 'partial' }, fresh, now), 'partial');
    assert.equal(jobProblem(undefined, undefined, now), 'no heartbeat');
    assert.equal(
        jobProblem({ status: 'complete' }, { heartbeatAt: '2026-10-29T16:20:00-07:00' }, now),
        'stale heartbeat'
    );
    assert.deepEqual(
        { ...jobGroupStatus([{ name: 'Option quotes', problem: null }]) },
        { count: '1 job', label: 'all complete', tone: 'good', names: '' }
    );
    assert.deepEqual(
        {
            ...jobGroupStatus([
                { name: 'Stock prices', problem: 'failed' },
                { name: 'Stock splits', problem: null },
                { name: 'Index closes', problem: 'stale heartbeat' },
            ]),
        },
        { count: '3 jobs', label: '2 issues', tone: 'bad', names: 'Stock prices failed, Index closes stale heartbeat' }
    );
    assert.match(source, /element\('details', undefined, 'day app-group'\)/);
    assert.match(source, /'solution-deploy-open-job-groups'/);
});

test('current checks show the monitor result without any audit section', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const page = readFileSync(new URL('../site/collectors.html', import.meta.url), 'utf8');
    assert.doesNotMatch(`${source}\n${page}`, /audit/i);
    assert(page.includes('id="current"'));
    const code = source.slice(source.indexOf('function renderCurrent('), source.indexOf('\nconst historyDays'));
    const node = (tag, text, className) => ({
        tag,
        text,
        className,
        children: [],
        listeners: {},
        attributes: {},
        setAttribute(name, value) {
            this.attributes[name] = value;
        },
        addEventListener(type, listener) {
            this.listeners[type] = listener;
        },
        append(...children) {
            this.children.push(...children);
        },
        prepend(...children) {
            this.children.unshift(...children);
        },
        replaceChildren(...children) {
            this.children = children;
        },
    });
    const target = node('div');
    const opened = [];
    const renderCurrent = runInNewContext(`${code}\nrenderCurrent`, {
        element: node,
        badge: (status) => node('span', status, 'badge'),
        stamp: (value) => `stamp:${value}`,
        alertIcon: () => node('svg'),
        openIssue: (row, detail) => opened.push([row, detail]),
        document: { getElementById: () => target },
    });
    renderCurrent(undefined);
    assert.match(target.children[0].text, /not published/);
    renderCurrent({ checkedAt: '2026-10-28T13:20:00-07:00', details: [] });
    assert.equal(target.children.length, 1);
    assert.equal(target.children[0].children[0].text, 'healthy');
    const detail = { text: 'Stock prices: the last 2 session runs are incomplete.', summary: 'Stock prices: quota' };
    renderCurrent({ checkedAt: '2026-10-28T13:20:00-07:00', details: [detail] });
    assert.equal(target.children[0].children[0].text, '1 open issue');
    const button = target.children[1].children[0].children[0];
    assert.equal(button.text, 'Stock prices: quota');
    button.listeners.click();
    assert.equal(opened[0][1], detail);
    assert.equal(opened[0][0].checkedAt, '2026-10-28T13:20:00-07:00');
});
test('alert issues open a dialog with cause, meaning and log lines', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('\nconst issueDialog = '), source.indexOf('\nfunction groupByDay('));
    const nodes = {};
    const node = (tag, text, className) => ({
        tag,
        text,
        className,
        children: [],
        listeners: {},
        attributes: {},
        setAttribute(name, value) {
            this.attributes[name] = value;
        },
        addEventListener(type, listener) {
            this.listeners[type] = listener;
        },
        append(...children) {
            this.children.push(...children);
        },
        replaceChildren(...children) {
            this.children = children;
        },
        querySelector: () => node('button'),
        showModal() {
            this.opened = true;
        },
    });
    for (const id of ['issue-dialog', 'issue-dialog-title', 'issue-dialog-body']) nodes[id] = node('div');
    const { issueLinks } = runInNewContext(`${code}\n({ issueLinks })`, {
        element: node,
        stamp: (value) => `stamp:${value}`,
        document: { getElementById: (id) => nodes[id], createElementNS: (_ns, tag) => node(tag) },
    });
    assert.equal(issueLinks({ issues: [] }), 'All checks healthy.');
    const row = {
        kind: 'alert',
        sentAt: '2026-10-28T13:11:29-07:00',
        issues: ['Option quote collection failed: Quote stream timed out with missing prices'],
        details: [
            {
                label: 'Option quote collection',
                summary: 'Option quote collection failed: Quote stream timed out with missing prices',
                cause: 'Quote stream timed out with missing prices',
                meaning: 'data for that slot may be incomplete',
                task: 'SolutionDeploy-web-options-collector',
                exitCode: 1,
                lastRun: '2026-10-28T13:10:15-07:00',
                logPath: 'C:\\logs\\collector-tick.log',
                log: ['13:11:18 ERROR Quote stream timed out with missing prices'],
            },
        ],
    };
    const link = issueLinks(row).children[0].children[0];
    assert.equal(link.tag, 'button');
    assert.equal(link.attributes['aria-haspopup'], 'dialog');
    assert.equal(link.text, undefined);
    assert.equal(link.children[0].tag, 'svg');
    assert.equal(link.title, 'Option quote collection failed');
    assert.equal(link.attributes['aria-label'], 'Option quote collection failed. Open details');
    link.listeners.click();
    assert.equal(nodes['issue-dialog'].opened, true);
    assert.equal(nodes['issue-dialog-title'].textContent, 'Option quote collection failed');
    const texts = nodes['issue-dialog-body'].children.flatMap((child) => [
        child.text,
        ...child.children.map((c) => c.text),
    ]);
    for (const expected of [
        'Cause',
        'What this means',
        'Log lines from this run',
        'SolutionDeploy-web-options-collector',
        '1',
    ])
        assert(texts.includes(expected), expected);
    assert(texts.includes('13:11:18 ERROR Quote stream timed out with missing prices'));
    const old = issueLinks({ kind: 'alert', sentAt: 'x', issues: ['Old text'] }).children[0].children[0];
    old.listeners.click();
    assert.equal(nodes['issue-dialog-title'].textContent, 'Monitor alert');
    assert(nodes['issue-dialog-body'].children.some((child) => /before detailed alert history/.test(child.text)));
});

test('monitoring information explains current checks and notification rules in a separate dialog', () => {
    const page = readFileSync(new URL('../site/collectors.html', import.meta.url), 'utf8');
    const content = page.slice(
        page.indexOf('<dialog id="monitoring-dialog"'),
        page.indexOf('<dialog id="issue-dialog"')
    );
    assert.match(page, /id="monitoring-info"[\s\S]*?aria-label="About collector monitoring and alerts"/);
    assert.match(page, /aria-controls="monitoring-dialog"/);
    assert.match(content, /aria-labelledby="monitoring-dialog-title"/);
    assert.match(content, /aria-label="Close monitoring information" autofocus/);
    assert.match(content, /class="issue-dialog-body monitoring-info-body" tabindex="0"/);
    const textContent = content.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
    for (const text of [
        'stock prices, option quotes, earnings dates, index closes and stock splits',
        'checks every minute',
        'snapshot every 5 minutes',
        'more than 10',
        'older than 12 minutes',
        'more than 2 minutes in the future',
        'latest 2 recorded session runs',
        'no later recovery run',
        'deadlines from the last 24 hours',
        '2 minutes after the deadline',
        'only gap is a stale',
        'When Pushover notifications are sent',
        'more than 24 hours after the last notification',
        'when all findings clear',
        'Clearing only some findings',
        'Failed delivery is not marked as sent',
        '30 days of history',
        'independently verify quote values',
        'may prevent notifications',
    ])
        assert(textContent.includes(text), text);
    assert.doesNotMatch(content, /<(select|datalist)\b|\btitle=/i);
});

test('monitoring information opens, dismisses and restores trigger focus without changing alert details', () => {
    const source = readFileSync(new URL('../site/collectors.js', import.meta.url), 'utf8');
    const code = source.slice(source.indexOf('const monitoringDialog = '), source.indexOf('const issueDialog = '));
    const listeners = {};
    const trigger = {
        attributes: {},
        addEventListener(type, handler) {
            listeners[`trigger:${type}`] = handler;
        },
        setAttribute(name, value) {
            this.attributes[name] = value;
        },
        focus() {
            this.focused = true;
        },
    };
    const body = { scrollTop: 100 };
    const closeButton = {
        addEventListener(type, handler) {
            listeners[`close:${type}`] = handler;
        },
    };
    const dialog = {
        open: false,
        showModal() {
            this.open = true;
        },
        close() {
            this.open = false;
            listeners['dialog:close']();
        },
        querySelector(selector) {
            return selector === '.issue-dialog-close' ? closeButton : body;
        },
        addEventListener(type, handler) {
            listeners[`dialog:${type}`] = handler;
        },
    };
    runInNewContext(code, {
        document: { getElementById: (id) => (id === 'monitoring-dialog' ? dialog : trigger) },
    });
    const open = () => {
        listeners['trigger:click']();
        assert.equal(dialog.open, true);
        assert.equal(trigger.attributes['aria-expanded'], 'true');
        assert.equal(body.scrollTop, 0);
    };
    const closed = () => {
        assert.equal(dialog.open, false);
        assert.equal(trigger.attributes['aria-expanded'], 'false');
        assert.equal(trigger.focused, true);
    };
    open();
    listeners['dialog:click']({ target: body });
    assert.equal(dialog.open, true);
    listeners['close:click']();
    closed();
    open();
    listeners['dialog:click']({ target: dialog });
    closed();
    open();
    listeners['dialog:keydown']({ key: 'Tab' });
    assert.equal(dialog.open, true);
    let prevented = false;
    listeners['dialog:keydown']({
        key: 'Escape',
        preventDefault() {
            prevented = true;
        },
    });
    assert.equal(prevented, true);
    closed();
    open();
    dialog.close();
    closed();
});

test('inventory describes every published host and its data source', () => {
    const inventory = JSON.parse(readFileSync(new URL('../site/sites.json', import.meta.url)));
    assert.equal(inventory.host, 'jimbrownhome1');
    assert.equal(inventory.sites.length, 15);
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

test('release records are read on every request and invalid records are skipped', async () => {
    const folder = mkdtempSync(join(tmpdir(), 'release-records-'));
    const commit = 'a'.repeat(40);
    const write = (name, record) => writeFileSync(join(folder, name), JSON.stringify(record));
    const server = createServer({ releaseRecordsPath: folder });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/deployments.json`;
    const solution = async (id) => (await (await fetch(url)).json()).solutions.find((entry) => entry.id === id);
    try {
        assert.equal((await solution('work-log')).lastRelease, null);
        write('work-log--web.json', {
            app: 'work-log',
            component: 'web',
            sourceCommit: commit,
            completedLocal: '2026-07-12T14:05:00-07:00',
            private: 'PRIVATE_SENTINEL',
        });
        write('web-options--collector.json', {
            app: 'web-options',
            component: 'collector',
            sourceCommit: commit,
            completedLocal: '2026-07-10T09:00:00-07:00',
        });
        write('web-options--web.json', {
            app: 'web-options',
            component: 'web',
            sourceCommit: commit,
            completedLocal: '2026-07-11T09:00:00-07:00',
        });
        write('plex--web.json', { app: 'plex', component: 'web', sourceCommit: 'bad', completedLocal: 'x' });
        write('ferry-tracker--app.json', {
            app: 'ferry-tracker',
            component: 'app',
            sourceCommit: commit,
            completedLocal: '2026-07-09T09:00:00-07:00',
        });
        writeFileSync(join(folder, 'pgweb--app.json'), '{broken');
        const workLog = await solution('work-log');
        assert.deepEqual(workLog.lastRelease, {
            component: 'web',
            commit: 'aaaaaaa',
            completed: '2026-07-12T21:05:00.000Z',
        });
        assert(!JSON.stringify(workLog).includes('PRIVATE_SENTINEL'));
        const options = await solution('web-options');
        assert.deepEqual(
            options.releases.map((entry) => entry.component),
            ['web', 'collector']
        );
        const ferry = await solution('ferry-tracker');
        assert.deepEqual(
            ferry.releases.map((entry) => entry.component),
            ['web', 'capture']
        );
        assert.equal(ferry.lastRelease.completed, '2026-07-09T16:00:00.000Z');
        assert.equal((await solution('plex')).lastRelease, null);
        assert.equal((await solution('pgweb')).lastRelease, null);
    } finally {
        server.closeAllConnections();
        await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
        rmSync(folder, { recursive: true, force: true });
    }
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
            '/deployments.json',
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
        assert.equal((await get('/deployments.json', 'HEAD')).statusCode, 200);
        assert.equal((await get('/deployments.json', 'POST')).statusCode, 405);
        assert.equal((await get('/environments/releases.json')).statusCode, 404);
        assert.equal((await get('/server.mjs')).statusCode, 404);
        assert.equal((await get('/%2e%2e/README.md')).statusCode, 404);
        assert.equal((await get('/.env')).statusCode, 404);
        assert.equal((await get('/health')).statusCode, 200);
    } finally {
        await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
});
