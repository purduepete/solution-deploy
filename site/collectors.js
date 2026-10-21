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
const stamp = (value) => (value ? `${day(value)} ${clock(value)}` : 'Never');
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

const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = text;
    if (className) node.className = className;
    return node;
};
const badge = (status) => element('span', status.replace('_', ' '), `badge ${tone[status] ?? 'muted'}`);

function table(id, headers, rows, empty) {
    const target = document.getElementById(id);
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

    const cards = snapshot.jobs.map((job) => {
        const card = element('article');
        card.append(element('p', job.app, 'host'), element('h3', job.name), element('p', job.schedule, 'schedule'));
        const facts = element('dl', undefined, 'facts');
        const audits = snapshot.audits.filter((row) => row.job === job.id);
        if (audits.length) {
            const latest = audits.reduce((a, b) => (a.date > b.date ? a : b)).date;
            const rows = audits.filter((row) => row.date === latest);
            const last = element('dd');
            last.append(badge(auditOutcome(rows)), ` ${latest} (written ${clock(rows[0].writtenAt)})`);
            facts.append(element('dt', 'Last audit'), last);
        } else if (job.id.endsWith('-audit')) {
            facts.append(element('dt', 'Last audit'), element('dd', 'No report yet'));
        } else {
            const lastRun = runs.find((run) => run.job === job.id);
            const last = element('dd');
            if (lastRun) {
                const counts = lastRun.expected ? ` ${lastRun.ok}/${lastRun.expected}` : '';
                last.append(badge(lastRun.status), ` ${stamp(lastRun.scheduledAt)} ${lastRun.kind}${counts}`);
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
        return card;
    });
    document.getElementById('jobs').replaceChildren(...cards);

    table(
        'today',
        [['Time'], ['Job'], ['Slot', true], ['Status'], ['Result', true], ['Detail', true]],
        runs
            .filter((run) => day(run.scheduledAt) === today)
            .map((run) => [
                clock(run.scheduledAt),
                names[run.job] ?? run.job,
                run.kind,
                badge(run.status),
                run.expected ? `${run.ok}/${run.expected}` : '',
                run.detail ?? '',
            ]),
        'No slots have come due today.'
    );

    const groups = new Map();
    for (const run of runs) {
        const key = `${day(run.scheduledAt)}|${run.job}`;
        const group = groups.get(key) ?? {
            date: day(run.scheduledAt),
            job: run.job,
            total: 0,
            complete: 0,
            partial: 0,
            bad: 0,
        };
        group.total++;
        if (run.status === 'complete') group.complete++;
        else if (run.status === 'partial') group.partial++;
        else if (['missed', 'failed'].includes(run.status)) group.bad++;
        groups.set(key, group);
    }
    const order = snapshot.jobs.map((job) => job.id);
    table(
        'week',
        [['Date'], ['Job'], ['Slots'], ['Complete'], ['Partial', true], ['Missed or failed']],
        [...groups.values()]
            .sort((a, b) => b.date.localeCompare(a.date) || order.indexOf(a.job) - order.indexOf(b.job))
            .map((g) => [
                g.date,
                names[g.job] ?? g.job,
                String(g.total),
                String(g.complete),
                String(g.partial),
                g.bad ? element('span', String(g.bad), 'badge bad') : '0',
            ]),
        'No runs in the last 7 days.'
    );

    table(
        'audits',
        [['Date'], ['Audit'], ['Subject'], ['Result']],
        [...snapshot.audits]
            .sort(
                (a, b) =>
                    b.date.localeCompare(a.date) || a.audit.localeCompare(b.audit) || a.subject.localeCompare(b.subject)
            )
            .map((row) => {
                const result = element('span');
                result.append(badge(row.status));
                if (row.informational) result.append(element('span', ' info', 'note'));
                return [row.date, row.audit, row.subject, result];
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
