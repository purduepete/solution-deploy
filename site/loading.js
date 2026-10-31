const LOADING_DELAY_MS = 250;
const NAVIGATION_KEY = 'solution-directory-navigation';
const pagePaths = new Set(['/', '/collectors']);
const navigationType = performance.getEntriesByType('navigation')[0]?.type;
try {
    const destination = sessionStorage.getItem(NAVIGATION_KEY);
    sessionStorage.removeItem(NAVIGATION_KEY);
    if (navigationType === 'back_forward' || (navigationType !== 'reload' && destination === location.pathname))
        document.documentElement.classList.add('page-navigation');
} catch (error) {
    console.warn('Cannot restore directory navigation state:', error);
}
addEventListener('click', (event) => {
    const link = event.target.closest('a[href]');
    if (
        !link ||
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey ||
        (link.target && link.target !== '_self')
    )
        return;
    const url = new URL(link.href);
    if (url.origin !== location.origin || !pagePaths.has(url.pathname) || url.pathname === location.pathname) return;
    try {
        sessionStorage.setItem(NAVIGATION_KEY, url.pathname);
    } catch (error) {
        console.warn('Cannot save directory navigation state:', error);
    }
});

window.startPageLoading = (label) => {
    const overlay = document.getElementById('page-loading');
    let ready = false;
    const timer = setTimeout(() => {
        const ring = document.createElement('div');
        ring.className = 'spinner-wrap';
        ring.setAttribute('role', 'status');
        const spinner = document.createElement('span');
        spinner.className = 'spinner';
        spinner.setAttribute('aria-hidden', 'true');
        const text = document.createElement('span');
        text.className = 'sr-only';
        text.textContent = label;
        ring.append(spinner, text);
        overlay?.append(ring);
    }, LOADING_DELAY_MS);
    return (success = true) => {
        clearTimeout(timer);
        const first = document.documentElement.classList.contains('page-initial-loading');
        overlay?.remove();
        document.documentElement.classList.remove('page-initial-loading');
        if (!success || ready) return;
        ready = true;
        document.querySelector('main')?.classList.add('data-enter');
        if (first) {
            const shell = document.documentElement.classList.contains('page-navigation')
                ? document.querySelectorAll('header h1, header .intro')
                : document.querySelectorAll('header');
            for (const element of shell) element.classList.add('data-enter');
        }
    };
};
