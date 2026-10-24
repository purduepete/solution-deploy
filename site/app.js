const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
};

function deploymentSection(info) {
    const section = element('section', undefined, 'deployment');
    const heading = element('div', undefined, 'deployment-heading');
    heading.append(element('h3', 'Deployment'), element('span', info.support, 'badge muted'));
    const details = element('details');
    details.append(element('summary', 'Deployment Details'));
    const body = element('div', undefined, 'deployment-body');
    body.append(element('p', info.method));
    body.append(element('h3', 'Components / Jobs'));
    const components = element('ul');
    for (const name of info.components) {
        components.append(
            element(
                'li',
                name
                    .split('-')
                    .map((word) => word[0].toUpperCase() + word.slice(1))
                    .join(' ')
            )
        );
    }
    body.append(components, element('h3', 'Recorded Version Evidence'), element('p', info.versionEvidence));
    if (info.blocker) body.append(element('h3', 'Release Procedure Blocker'), element('p', info.blocker));
    if (info.componentNote) body.append(element('h3', 'Component Boundary'), element('p', info.componentNote));
    if (info.explicitComponents) body.append(element('p', 'Shared host jobs require explicit component selection.'));
    if (info.privateOnly) body.append(element('p', 'Private-only access is preserved. No public Cloudflare route.'));
    const links = element('p', undefined, 'deployment-links');
    const procedure = element('a', 'Deployment Procedure');
    procedure.href = info.procedureUrl;
    links.append(procedure);
    if (info.repository) {
        const repository = element('a', 'Source Repository');
        repository.href = info.repository;
        links.append(repository);
    }
    body.append(links);
    details.append(body);
    section.append(heading, details);
    return section;
}

async function loadDeployments() {
    try {
        const response = await fetch('/deployments.json', { cache: 'no-store' });
        if (!response.ok) throw new Error(`Deployment request failed (HTTP ${response.status}).`);
        const data = await response.json();
        if (!Array.isArray(data.solutions) || !data.solutions.length)
            throw new Error('Deployment inventory has no solutions.');
        return new Map(data.solutions.map((info) => [info.id, info]));
    } catch (error) {
        console.error('Cannot load deployment information:', error);
        const message = document.getElementById('deployment-error');
        message.textContent = `${error.message} Site links remain available. Reload or check the directory service log.`;
        message.hidden = false;
        return null;
    }
}

async function load() {
    const [response, deployments] = await Promise.all([fetch('/sites.json', { cache: 'no-store' }), loadDeployments()]);
    if (!response.ok) throw new Error(`Inventory request failed (HTTP ${response.status}).`);
    const inventory = await response.json();
    if (!Array.isArray(inventory.sites) || !inventory.sites.length) throw new Error('Inventory has no sites.');
    const root = document.getElementById('sites');
    const cards = inventory.sites
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((site) => {
            const card = element('article');
            card.append(
                element('p', inventory.host, 'host'),
                element('h2', site.name),
                element('p', site.purpose, 'purpose')
            );
            const links = element('dl', undefined, 'links');
            for (const [label, field] of [
                ['Cloudflare', 'cloudflareUrl'],
                ['Tailscale', 'tailscaleUrl'],
                ['Local LAN', 'localUrl'],
            ]) {
                if (!site[field]) continue;
                const url = new URL(site[field]);
                if (!['http:', 'https:'].includes(url.protocol))
                    throw new Error(`Invalid ${label} URL for ${site.id}.`);
                const value = element('dd');
                const link = element('a', site[field]);
                link.href = url.href;
                value.append(link);
                links.append(element('dt', label), value);
            }
            const data = element('div', undefined, 'data');
            data.append(
                element('h3', 'Current database / storage'),
                element('p', site.database),
                element('h3', 'Original source / retained dependency'),
                element('p', site.sourceDatabase)
            );
            card.append(links, data, element('p', site.notes, 'notes'));
            const deployment = deployments?.get(site.id);
            if (deployments && !deployment) throw new Error(`Deployment information missing for ${site.name}.`);
            if (deployment) card.append(deploymentSection(deployment));
            else card.append(element('p', 'Deployment information unavailable.', 'notes'));
            root.append(card);
            return {
                card,
                text: `${Object.values(site).join(' ')} ${card.textContent}`.toLowerCase(),
            };
        });
    const [year, month, day] = inventory.updated.split('-');
    document.getElementById('updated').textContent = `Inventory updated ${month}/${day}/${year}.`;
    const filter = () => {
        const query = document.getElementById('search').value.trim().toLowerCase();
        let visible = 0;
        for (const { card, text } of cards) {
            card.hidden = !text.includes(query);
            if (!card.hidden) visible++;
        }
        document.getElementById('summary').textContent = `${visible} of ${cards.length} sites`;
        document.getElementById('empty').hidden = visible !== 0;
    };
    document.getElementById('search').addEventListener('input', filter);
    filter();
}

load().catch((error) => {
    console.error('Cannot load solution directory:', error);
    document.getElementById('sites').replaceChildren();
    document.getElementById('summary').textContent = 'Inventory unavailable';
    const message = document.getElementById('error');
    message.textContent = `${error.message} Reload the page or check the host service log.`;
    message.hidden = false;
});
