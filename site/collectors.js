const zone = 'America/Los_Angeles';
const dayFormat = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
});
const timeFormat = new Intl.DateTimeFormat('en-US', {
    timeZone: zone,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
});
const day = (value) => dayFormat.format(new Date(value));
const clock = (value) => (value ? timeFormat.format(new Date(value)) : '');
// day() returns the ISO yyyy-mm-dd key used for grouping and sorting; showDate() is what readers see.
const showDate = (iso) => iso.replace(/^(\d{4})-(\d{2})-(\d{2})$/, '$2/$3/$1');
const stamp = (value) => (value ? `${showDate(day(value))} ${clock(value)}` : 'Never');
const tone = {
    complete: 'good',
    pass: 'good',
    partial: 'warn',
    running: 'warn',
    pending: 'warn',
    not_run: 'warn',
    stale: 'warn',
    failed: 'bad',
    fail: 'bad',
    missed: 'bad',
    unreadable: 'bad',
};
const staleHeartbeatMs = 10 * 60 * 1000;
// One reader-facing name per kind of slot, whichever collector stored it.
const slotLabels = {
    session: 'Session',
    open_session: 'Session',
    close: 'Close',
    settle: 'Settle',
    recovery: 'Recovery',
    earnings: 'Daily',
    indices: 'Daily',
    splits: 'Daily',
};
const slotLabel = (kind) => slotLabels[kind] ?? kind;

const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = text;
    if (className) node.className = className;
    return node;
};
const badge = (status) => element('span', status.replace('_', ' '), `badge ${tone[status] ?? 'muted'}`);

function table(target, headers, rows, empty) {
    const head = element('thead');
    const headRow = element('tr');
    for (const [label, wide] of headers) headRow.append(element('th', label, wide ? 'wide' : undefined));
    head.append(headRow);
    const body = element('tbody');
    for (const cells of rows) {
        const row = element('tr');
        cells.forEach((cell, index) => {
            const td = element('td', undefined, headers[index][1] ? 'wide' : undefined);
            td.append(cell instanceof Node ? cell : document.createTextNode(cell ?? ''));
            row.append(td);
        });
        body.append(row);
    }
    if (!rows.length) {
        const row = element('tr');
        const td = element('td', empty, 'empty');
        td.colSpan = headers.length;
        row.append(td);
        body.append(row);
    }
    target.replaceChildren(head, body);
}

function groupByDay(items, key) {
    const groups = new Map();
    for (const item of items) {
        const date = key(item);
        if (!groups.has(date)) groups.set(date, []);
        groups.get(date).push(item);
    }
    return [...groups].sort(([a], [b]) => b.localeCompare(a));
}

// Each day is a collapsed <details>; days the reader opened stay open across refreshes.
function days(id, groups, empty) {
    const target = document.getElementById(id);
    const open = new Set([...target.querySelectorAll('details[open]')].map((node) => node.dataset.date));
    if (!groups.length) {
        target.replaceChildren(element('p', empty, 'empty'));
        return;
    }
    target.replaceChildren(
        ...groups.map((group) => {
            const details = element('details', undefined, 'day');
            details.dataset.date = group.date;
            details.open = open.has(group.date);
            const summary = element('summary');
            summary.append(element('span', group.label, 'day-date'));
            for (const part of group.summary.filter(Boolean)) summary.append(' ', part);
            const wrap = element('div', undefined, 'table-wrap');
            const tableNode = element('table');
            wrap.append(tableNode);
            table(tableNode, group.headers, group.rows, empty);
            details.append(summary, wrap);
            return details;
        })
    );
}

function auditOutcome(rows) {
    const required = rows.filter((row) => !row.informational);
    if (required.some((row) => ['fail', 'unreadable'].includes(row.status))) return 'fail';
    if (required.some((row) => row.status !== 'pass')) return 'not_run';
    return 'pass';
}

function render(snapshot) {
    const names = Object.fromEntries(snapshot.jobs.map((job) => [job.id, job.name]));
    const runs = [...snapshot.runs].sort((a, b) => new Date(b.scheduledAt) - new Date(a.scheduledAt));
    const now = Date.now();
    const today = day(now);

    const lastAt = new Map();
    const cards = snapshot.jobs.map((job) => {
        const card = element('article');
        card.append(element('h4', job.name), element('p', job.schedule, 'schedule'));
        const facts = element('dl', undefined, 'facts');
        const audits = snapshot.audits.filter((row) => row.job === job.id);
        if (audits.length) {
            const latest = audits.reduce((a, b) => (a.date > b.date ? a : b)).date;
            const rows = audits.filter((row) => row.date === latest);
            lastAt.set(job.id, new Date(rows[0].writtenAt).getTime());
            const last = element('dd');
            last.append(badge(auditOutcome(rows)), ` ${showDate(latest)} (written ${clock(rows[0].writtenAt)})`);
            facts.append(element('dt', 'Last audit'), last);
        } else if (job.id.endsWith('-audit')) {
            facts.append(element('dt', 'Last audit'), element('dd', 'No report yet'));
        } else {
            const lastRun = runs.find((run) => run.job === job.id);
            const last = element('dd');
            if (lastRun) {
                lastAt.set(job.id, new Date(lastRun.scheduledAt).getTime());
                const counts = lastRun.expected ? ` ${lastRun.ok}/${lastRun.expected}` : '';
                last.append(
                    badge(lastRun.status),
                    ` ${stamp(lastRun.scheduledAt)} ${slotLabel(lastRun.kind)}${counts}`
                );
            } else last.textContent = 'No runs in 7 days';
            facts.append(element('dt', 'Last slot'), last);
            const health = snapshot.health.find((row) => row.job === job.id);
            const beat = element('dd');
            if (health) {
                const stale = now - new Date(health.heartbeatAt) > staleHeartbeatMs;
                if (stale) beat.append(badge('stale'), ' ');
                beat.append(stamp(health.heartbeatAt));
                if (health.lastError) beat.append(element('span', ` ${health.lastError}`, 'note'));
            } else beat.textContent = 'None';
            facts.append(element('dt', 'Heartbeat'), beat);
        }
        card.append(facts);
        return { job, card };
    });
    // One group per app in catalog order; cards inside run newest activity first, never-run jobs last.
    const apps = [...new Set(snapshot.jobs.map((job) => job.app))];
    document.getElementById('jobs').replaceChildren(
        ...apps.map((app) => {
            const group = element('div', undefined, 'app-group');
            const grid = element('div', undefined, 'jobs');
            grid.append(
                ...cards
                    .filter(({ job }) => job.app === app)
                    .sort((a, b) => (lastAt.get(b.job.id) ?? -Infinity) - (lastAt.get(a.job.id) ?? -Infinity))
                    .map(({ card }) => card)
            );
            group.append(element('h3', app, 'app-title'), grid);
            return group;
        })
    );

    const runRow = (run) => [
        clock(run.scheduledAt),
        names[run.job] ?? run.job,
        slotLabel(run.kind),
        badge(run.status),
        run.expected ? `${run.ok}/${run.expected}` : '',
        run.detail ?? '',
    ];
    const runDays = groupByDay(runs, (run) => day(run.scheduledAt));
    days(
        'runs',
        runDays.map(([date, rows]) => {
            const count = (statuses) => rows.filter((run) => statuses.includes(run.status)).length;
            const bad = count(['missed', 'failed']);
            const partial = count(['partial']);
            return {
                date,
                label: date === today ? `${showDate(date)} (today)` : showDate(date),
                summary: [
                    `${rows.length} slots, ${count(['complete'])} complete`,
                    partial ? element('span', `${partial} partial`, 'badge warn') : null,
                    bad ? element('span', `${bad} missed or failed`, 'badge bad') : null,
                ],
                headers: [['Time'], ['Job'], ['Slot', true], ['Status'], ['Result', true], ['Detail', true]],
                rows: rows.map(runRow),
            };
        }),
        'No runs in the last 7 days.'
    );

    const audits = [...snapshot.audits].sort(
        (a, b) => a.audit.localeCompare(b.audit) || a.subject.localeCompare(b.subject)
    );
    days(
        'audits',
        groupByDay(audits, (row) => row.date).map(([date, rows]) => {
            const failed = rows.filter(
                (row) => !row.informational && ['fail', 'unreadable'].includes(row.status)
            ).length;
            return {
                date,
                label: showDate(date),
                summary: [
                    `${rows.length} checks`,
                    failed ? element('span', `${failed} failed`, 'badge bad') : badge(auditOutcome(rows)),
                ],
                headers: [['Audit'], ['Subject'], ['Result']],
                rows: rows.map((row) => {
                    const result = element('span');
                    result.append(badge(row.status));
                    if (row.informational) result.append(element('span', ' info', 'note'));
                    return [row.audit, row.subject, result];
                }),
            };
        }),
        'No audit reports in the last 14 days.'
    );
    const age = now - new Date(snapshot.generatedAt);
    document.getElementById('updated').textContent = `Snapshot built ${stamp(snapshot.generatedAt)}.`;
    const status = document.getElementById('status');
    status.textContent =
        age > 15 * 60 * 1000
            ? `Snapshot is ${Math.round(age / 60000)} minutes old. Check the SolutionDeploy-collector-status task.`
            : `${runs.length} slots in 7 days, ${snapshot.audits.length} audit results.`;
    status.className = age > 15 * 60 * 1000 ? 'stale' : '';
    const error = document.getElementById('error');
    error.textContent = snapshot.errors.length ? `Snapshot errors: ${snapshot.errors.join('; ')}` : '';
    error.hidden = !snapshot.errors.length;
}

async function load() {
    const response = await fetch('/collector-status.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`Collector status request failed (HTTP ${response.status}).`);
    const snapshot = await response.json();
    if (snapshot.schemaVersion !== 1) throw new Error(`Unsupported snapshot schema ${snapshot.schemaVersion}.`);
    render(snapshot);
}

const refresh = () =>
    load().catch((error) => {
        console.error('Cannot load collector status:', error);
        document.getElementById('status').textContent = 'Collector status unavailable';
        const message = document.getElementById('error');
        message.textContent = `${error.message} The page retries every minute.`;
        message.hidden = false;
    });
refresh();
setInterval(refresh, 60 * 1000);
