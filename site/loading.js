// Page loading state shared by the directory pages. The #page-loading overlay in
// the markup hides the content at once; the ring appears only after 250ms, so a
// fast load never flashes it. finish() removes the overlay and fades the content in.
const LOADING_DELAY_MS = 250;

window.startPageLoading = (label) => {
    const overlay = document.getElementById('page-loading');
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
    return () => {
        clearTimeout(timer);
        if (!overlay?.isConnected) return;
        overlay.remove();
        document.querySelector('main')?.classList.add('data-enter');
        for (const text of document.querySelectorAll('header h1, header .intro')) text.classList.add('data-enter');
    };
};
