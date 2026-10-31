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
    no_work: 'muted',
    partial: 'warn',
    running: 'warn',
    pending: 'warn',
    stale: 'warn',
    failed: 'bad',
    missed: 'bad',
    alert: 'bad',
    recovered: 'good',
    healthy: 'good',
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

// Custom tooltip for any element with data-tip; native title tooltips are not themed.
const tooltip = element('div', undefined, 'tooltip');
tooltip.id = 'tooltip';
tooltip.setAttribute('role', 'tooltip');
tooltip.hidden = true;
document.body.append(tooltip);
let tipTarget = null;
let hideTimer;

function showTip(target) {
    clearTimeout(hideTimer);
    if (tipTarget && tipTarget !== target) tipTarget.removeAttribute('aria-describedby');
    tipTarget = target;
    tooltip.textContent = target.dataset.tip;
    tooltip.hidden = false;
    target.setAttribute('aria-describedby', tooltip.id);
    const box = target.getBoundingClientRect();
    const tip = tooltip.getBoundingClientRect();
    const left = Math.min(Math.max(8, box.left + box.width / 2 - tip.width / 2), innerWidth - tip.width - 8);
    const below = box.bottom + 6 + tip.height <= innerHeight - 8;
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${below ? box.bottom + 6 : box.top - tip.height - 6}px`;
}

function hideTip() {
    clearTimeout(hideTimer);
    if (!tipTarget) return;
    tipTarget.removeAttribute('aria-describedby');
    tipTarget = null;
    tooltip.hidden = true;
}

document.addEventListener('pointerover', (event) => {
    if (event.pointerType === 'touch') return;
    const target = event.target.closest?.('[data-tip]');
    if (target) showTip(target);
    else if (tooltip.contains(event.target)) clearTimeout(hideTimer);
});
document.addEventListener('pointerout', (event) => {
    if (!tipTarget) return;
    const next = event.relatedTarget;
    if (next && (tipTarget.contains(next) || tooltip.contains(next))) return;
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hideTip, 150);
});
document.addEventListener('focusin', (event) => {
    const target = event.target.closest?.('[data-tip]');
    if (target?.matches(':focus-visible')) showTip(target);
});
document.addEventListener('focusout', hideTip);
document.addEventListener('click', hideTip, true);
document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hideTip();
});
addEventListener('scroll', hideTip, true);

const monitoringDialog = document.getElementById('monitoring-dialog');
const monitoringInfo = document.getElementById('monitoring-info');
monitoringInfo.addEventListener('click', () => {
    monitoringDialog.showModal();
    monitoringInfo.setAttribute('aria-expanded', 'true');
    monitoringDialog.querySelector('.issue-dialog-body').scrollTop = 0;
});
monitoringDialog.querySelector('.issue-dialog-close').addEventListener('click', () => monitoringDialog.close());
monitoringDialog.addEventListener('click', (event) => {
    if (event.target === monitoringDialog) monitoringDialog.close();
});
monitoringDialog.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
        event.preventDefault();
        monitoringDialog.close();
    }
});
monitoringDialog.addEventListener('close', () => {
    monitoringInfo.setAttribute('aria-expanded', 'false');
    monitoringInfo.focus();
});

const issueDialog = document.getElementById('issue-dialog');
issueDialog.querySelector('.issue-dialog-close').addEventListener('click', () => issueDialog.close());
// A click on the backdrop lands on the dialog element itself.
issueDialog.addEventListener('click', (event) => {
    if (event.target === issueDialog) issueDialog.close();
});

function openIssue(row, detail) {
    document.getElementById('issue-dialog-title').textContent = detail.label
        ? `${detail.label} failed`
        : row.kind === 'alert'
          ? 'Monitor alert'
          : 'Monitor notification';
    const body = document.getElementById('issue-dialog-body');
    const parts = [element('p', detail.summary ?? detail.text, 'issue-lead')];
    const facts = element('dl', undefined, 'facts issue-facts');
    const fact = (label, value) => {
        if (value === undefined || value === null || value === '') return;
        facts.append(element('dt', label), element('dd', String(value)));
    };
    fact('Alert sent', row.sentAt ? stamp(row.sentAt) : '');
    fact('Checked', row.checkedAt ? stamp(row.checkedAt) : '');
    fact('Run started', detail.lastRun ? stamp(detail.lastRun) : '');
    fact('Task', detail.task);
    fact('Exit code', detail.exitCode);
    fact('Log file', detail.logPath);
    parts.push(facts);
    const section = (title, content) => {
        if (!content) return;
        parts.push(element('h3', title), content);
    };
    section('Cause', detail.cause ? element('p', detail.cause) : null);
    section('What this means', detail.meaning ? element('p', detail.meaning) : null);
    if (detail.log?.length) section('Log lines from this run', element('pre', detail.log.join('\n'), 'issue-log'));
    else if (detail.task && detail.exitCode)
        section('Log lines from this run', element('p', 'No log lines were captured for this run.', 'note'));
    if (!detail.meaning && !detail.task)
        parts.push(element('p', 'This alert was recorded before detailed alert history was kept.', 'note'));
    body.replaceChildren(...parts);
    issueDialog.showModal();
    body.scrollTop = 0;
}

// Lucide "triangle-alert" outline.
function alertIcon() {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    for (const [name, value] of Object.entries({
        viewBox: '0 0 24 24',
        width: '20',
        height: '20',
        fill: 'none',
        stroke: 'currentColor',
        'stroke-width': '2',
        'stroke-linecap': 'round',
        'stroke-linejoin': 'round',
        'aria-hidden': 'true',
    }))
        svg.setAttribute(name, value);
    for (const d of [
        'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3',
        'M12 9v4',
        'M12 17h.01',
    ]) {
        const path = document.createElementNS(ns, 'path');
        path.setAttribute('d', d);
        svg.append(path);
    }
    return svg;
}

function issueLabel(detail) {
    if (detail.label) return `${detail.label} failed`;
    return (detail.summary ?? detail.text ?? 'Alert').split(/[.:]/)[0];
}

function issueLinks(row) {
    if (!row.issues?.length) return 'All checks healthy.';
    const list = element('ul', undefined, 'issue-list');
    row.issues.forEach((text, index) => {
        const detail = row.details?.[index] ?? { text, summary: text };
        const link = element('button', undefined, 'issue-link');
        link.type = 'button';
        link.dataset.tip = issueLabel(detail);
        link.setAttribute('aria-label', `${issueLabel(detail)}. Open details`);
        link.setAttribute('aria-haspopup', 'dialog');
        link.append(alertIcon());
        link.addEventListener('click', () => openIssue(row, detail));
        const item = element('li');
        item.append(link);
        list.append(item);
    });
    return list;
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

// The monitor's latest result: what is wrong right now, separate from the notification history.
function renderCurrent(monitor) {
    const target = document.getElementById('current');
    if (!monitor?.checkedAt) {
        target.replaceChildren(element('p', 'The monitor has not published a result yet.', 'empty'));
        return;
    }
    const details = monitor.details ?? [];
    const head = element('p', undefined, 'current-head');
    head.append(
        details.length
            ? element('span', details.length === 1 ? '1 open issue' : `${details.length} open issues`, 'badge bad')
            : badge('healthy'),
        ` Checked ${stamp(monitor.checkedAt)}`
    );
    if (!details.length) {
        target.replaceChildren(head);
        return;
    }
    const row = { checkedAt: monitor.checkedAt, kind: 'alert' };
    const list = element('ul', undefined, 'current-list');
    for (const detail of details) {
        const button = element('button', detail.summary ?? detail.text, 'current-issue');
        button.type = 'button';
        button.setAttribute('aria-haspopup', 'dialog');
        button.prepend(alertIcon());
        button.addEventListener('click', () => openIssue(row, detail));
        const item = element('li');
        item.append(button);
        list.append(item);
    }
    target.replaceChildren(head, list);
}

const historyDays = { alerts: 7, runs: 7 };
let currentSnapshot;

function historyDropdown(controls, group) {
    const title = document.getElementById(`${group}-title`).textContent;
    const trigger = element('button', `${historyDays[group]} days`);
    trigger.type = 'button';
    trigger.setAttribute('aria-label', `${title} date range`);
    trigger.setAttribute('aria-haspopup', 'menu');
    trigger.setAttribute('aria-expanded', 'false');
    const menu = element('div', undefined, 'history-menu');
    menu.id = `${group}-range-menu`;
    menu.hidden = true;
    menu.setAttribute('role', 'menu');
    menu.setAttribute('aria-label', `${title} days`);
    trigger.setAttribute('aria-controls', menu.id);
    const options = [7, 14, 30].map((count) => {
        const option = element('button', `${count} days`);
        option.type = 'button';
        option.dataset.days = count;
        option.tabIndex = -1;
        option.setAttribute('role', 'menuitemradio');
        return option;
    });
    const close = (focus = false) => {
        menu.hidden = true;
        trigger.setAttribute('aria-expanded', 'false');
        if (focus) trigger.focus();
    };
    const open = (index = [7, 14, 30].indexOf(historyDays[group])) => {
        menu.hidden = false;
        trigger.setAttribute('aria-expanded', 'true');
        options[index].focus();
    };
    trigger.addEventListener('click', () => (menu.hidden ? open() : close(true)));
    trigger.addEventListener('keydown', (event) => {
        if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
            event.preventDefault();
            open(event.key === 'Home' ? 0 : event.key === 'End' ? 2 : undefined);
        }
    });
    options.forEach((option, index) => {
        option.addEventListener('click', () => {
            historyDays[group] = Number(option.dataset.days);
            close(true);
            render(currentSnapshot);
        });
        option.addEventListener('keydown', (event) => {
            let next;
            if (event.key === 'ArrowDown') next = (index + 1) % options.length;
            if (event.key === 'ArrowUp') next = (index + options.length - 1) % options.length;
            if (event.key === 'Home') next = 0;
            if (event.key === 'End') next = options.length - 1;
            if (next !== undefined) {
                event.preventDefault();
                options[next].focus();
            } else if (event.key === 'Escape') {
                event.preventDefault();
                close(true);
            } else if (event.key === 'Tab') close(true);
        });
    });
    for (const name of ['pointerdown', 'focusin']) {
        document.addEventListener(name, (event) => {
            if (!controls.contains(event.target)) close();
        });
    }
    menu.append(...options);
    controls.append(trigger, menu);
}

// A card has a problem when its last slot ended badly or its heartbeat is missing or stale.
function jobProblem(lastRun, health, now) {
    if (lastRun && !['complete', 'no_work', 'running', 'pending'].includes(lastRun.status) && !lastRun.vixOnly)
        return lastRun.status;
    if (!health) return 'no heartbeat';
    if (now - new Date(health.heartbeatAt) > staleHeartbeatMs) return 'stale heartbeat';
    return null;
}

// The line shown on a collapsed app group: job count, one rollup badge and the jobs that need a look.
function jobGroupStatus(entries) {
    const count = entries.length === 1 ? '1 job' : `${entries.length} jobs`;
    const problems = entries.filter((entry) => entry.problem);
    if (!problems.length) return { count, label: 'all complete', tone: 'good', names: '' };
    return {
        count,
        label: problems.length === 1 ? '1 issue' : `${problems.length} issues`,
        tone: 'bad',
        names: problems.map((entry) => `${entry.name} ${entry.problem}`).join(', '),
    };
}

const openGroupsKey = 'solution-deploy-open-job-groups';
function openJobGroups() {
    try {
        const saved = JSON.parse(localStorage.getItem(openGroupsKey) ?? '[]');
        return new Set(Array.isArray(saved) ? saved : []);
    } catch {
        return new Set();
    }
}

function inHistoryRange(date, today, count) {
    const start = new Date(`${today}T00:00:00Z`);
    start.setUTCDate(start.getUTCDate() - count + 1);
    return date >= start.toISOString().slice(0, 10) && date <= today;
}

function render(snapshot) {
    currentSnapshot = snapshot;
    const names = Object.fromEntries(snapshot.jobs.map((job) => [job.id, job.name]));
    const runs = [...snapshot.runs].sort((a, b) => new Date(b.scheduledAt) - new Date(a.scheduledAt));
    const now = Date.now();
    const today = day(now);
    for (const group of Object.keys(historyDays)) {
        const controls = document.getElementById(`${group}-range`);
        if (!controls.children.length) historyDropdown(controls, group);
        controls.firstElementChild.textContent = `${historyDays[group]} days`;
        for (const button of controls.querySelectorAll('[role="menuitemradio"]')) {
            button.setAttribute('aria-checked', String(Number(button.dataset.days) === historyDays[group]));
        }
    }

    const lastAt = new Map();
    const cards = snapshot.jobs.map((job) => {
        const card = element('article');
        card.append(element('h4', job.name), element('p', job.schedule, 'schedule'));
        const facts = element('dl', undefined, 'facts');
        const lastRun = runs.find((run) => run.job === job.id);
        const last = element('dd');
        if (lastRun) {
            lastAt.set(job.id, new Date(lastRun.scheduledAt).getTime());
            const counts = lastRun.expected ? ` ${lastRun.ok}/${lastRun.expected} usable` : '';
            last.append(badge(lastRun.status), ` ${stamp(lastRun.scheduledAt)} ${slotLabel(lastRun.kind)}${counts}`);
            if (lastRun.vixOnly) last.append(element('span', ' Only VIX stale, accepted.', 'note'));
        } else last.textContent = 'No runs in the available history';
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
        if (health?.lastSuccessAt)
            facts.append(element('dt', 'Last success'), element('dd', stamp(health.lastSuccessAt)));
        card.append(facts);
        return { job, card, problem: jobProblem(lastRun, health, now) };
    });
    // One collapsible group per app in catalog order; cards inside run newest activity first, never-run jobs last.
    // Groups start collapsed; the ones the reader opened stay open across refreshes and reloads.
    const apps = [...new Set(snapshot.jobs.map((job) => job.app))];
    const openGroups = openJobGroups();
    document.getElementById('jobs').replaceChildren(
        ...apps.map((app) => {
            const entries = cards
                .filter(({ job }) => job.app === app)
                .sort((a, b) => (lastAt.get(b.job.id) ?? -Infinity) - (lastAt.get(a.job.id) ?? -Infinity));
            const group = element('details', undefined, 'day app-group');
            group.open = openGroups.has(app);
            group.addEventListener('toggle', () => {
                const current = openJobGroups();
                if (group.open) current.add(app);
                else current.delete(app);
                localStorage.setItem(openGroupsKey, JSON.stringify([...current]));
            });
            const status = jobGroupStatus(entries.map(({ job, problem }) => ({ name: job.name, problem })));
            const summary = element('summary');
            summary.append(
                element('span', app, 'day-date'),
                ' ',
                status.count,
                ' ',
                element('span', status.label, `badge ${status.tone}`)
            );
            if (status.names) summary.append(' ', element('span', status.names, 'note'));
            const grid = element('div', undefined, 'jobs');
            grid.append(...entries.map(({ card }) => card));
            group.append(summary, grid);
            return group;
        })
    );

    const runRow = (run) => [
        clock(run.scheduledAt),
        names[run.job] ?? run.job,
        slotLabel(run.kind),
        badge(run.status),
        run.expected ? `${run.ok}/${run.expected} usable` : '',
        [run.detail, run.vixOnly ? 'only VIX stale, accepted' : ''].filter(Boolean).join('; '),
    ];
    const visibleRuns = runs.filter((run) => inHistoryRange(day(run.scheduledAt), today, historyDays.runs));
    const runDays = groupByDay(visibleRuns, (run) => day(run.scheduledAt));
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
        `No runs in the last ${historyDays.runs} days.`
    );

    const alerts = [...(snapshot.alerts ?? [])].sort((a, b) => b.sentAt.localeCompare(a.sentAt));
    days(
        'alerts',
        groupByDay(
            alerts.filter((row) => inHistoryRange(day(row.sentAt), today, historyDays.alerts)),
            (row) => day(row.sentAt)
        ).map(([date, rows]) => {
            const raised = rows.filter((row) => row.kind === 'alert').length;
            return {
                date,
                label: date === today ? `${showDate(date)} (today)` : showDate(date),
                summary: [
                    rows.length === 1 ? '1 notification' : `${rows.length} notifications`,
                    raised
                        ? element('span', raised === 1 ? '1 alert' : `${raised} alerts`, 'badge bad')
                        : badge('recovered'),
                ],
                headers: [['Time'], ['Kind'], ['Issues']],
                rows: rows.map((row) => [clock(row.sentAt), badge(row.kind), issueLinks(row)]),
            };
        }),
        `No monitor notifications in the last ${historyDays.alerts} days.`
    );

    renderCurrent(snapshot.monitor);
    const age = now - new Date(snapshot.generatedAt);
    document.getElementById('updated').textContent = `Snapshot built ${stamp(snapshot.generatedAt)}.`;
    const status = document.getElementById('status');
    status.textContent =
        age > 15 * 60 * 1000
            ? `Snapshot is ${Math.round(age / 60000)} minutes old. Check the SolutionDeploy-collector-status task.`
            : `${visibleRuns.length} slots in ${historyDays.runs} days.`;
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

const finishLoading = startPageLoading('Loading collector status');
const refresh = () =>
    load()
        .then(() => true)
        .catch((error) => {
            console.error('Cannot load collector status:', error);
            document.getElementById('status').textContent = 'Collector status unavailable';
            const message = document.getElementById('error');
            message.textContent = `${error.message} The page retries every minute.`;
            message.hidden = false;
            return false;
        })
        .then(finishLoading);
refresh();
setInterval(refresh, 60 * 1000);
