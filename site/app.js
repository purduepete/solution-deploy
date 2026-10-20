const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
};

async function load() {
    const response = await fetch('/sites.json', { cache: 'no-store' });
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
            root.append(card);
            return { card, text: Object.values(site).join(' ').toLowerCase() };
        });
    document.getElementById('updated').textContent = `Inventory updated ${inventory.updated}.`;
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
