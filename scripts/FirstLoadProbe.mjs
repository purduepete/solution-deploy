export const firstLoadTargets = {
    'ferry-tracker': { shell: '.app-header', content: '.view-content' },
    'home-automation': {
        shell: '#app-header',
        content: '[data-loading-content]',
        pendingClass: 'shell-loading',
        frames: true,
    },
    'site-dock': { shell: '.sidebar, .workspace-header, .login-header', content: '.workspace, .login-card' },
    'fit-track': { shell: '.app-bar', content: '.page-view:not([hidden]) > div' },
    'web-bookmarks': { shell: '#colMain > .input-group', content: '#colMain' },
    plex: { shell: '.theme-setting', content: '.card' },
    'work-log': { shell: '.rpt-hero', content: '.page' },
    'web-inventory': { shell: '.topbar', content: '.page > :not(.page-loading)' },
    'web-portfolio': { shell: 'nav.sticky, aside', content: 'main' },
    'web-options': { shell: 'header, nav', content: 'main' },
    'solution-deploy': { shell: 'header', content: 'main', pendingClass: 'page-initial-loading' },
    'team-scoreboard': { shell: 'header', content: 'main' },
    'idea-notes': { shell: '.topbar', content: '.workspace' },
};

export function installFirstLoadProbe(targets) {
    if (self !== top || !targets) return;
    const probe = { pendingFrames: 0, earlyFrames: 0, shellAt: null, contentAt: null, animations: [], failed: false };
    window.__webStandardFirstLoad = probe;
    const opacity = (element) => {
        let value = 1;
        for (let node = element; node; node = node.parentElement || node.ownerDocument.defaultView.frameElement) {
            const style = node.ownerDocument.defaultView.getComputedStyle(node);
            if (style.visibility !== 'visible' || style.display === 'none') return 0;
            value *= Number(style.opacity);
        }
        return value;
    };
    const nodes = (selector) => {
        const found = [...document.querySelectorAll(selector)];
        if (targets.frames) {
            for (const frame of document.querySelectorAll('iframe')) {
                if (opacity(frame) > 0 && frame.contentDocument)
                    found.push(...frame.contentDocument.querySelectorAll(selector));
            }
        }
        return found.filter((element) => element.getBoundingClientRect().width > 0);
    };
    const started = performance.now();
    const sample = (now) => {
        const root = targets.pendingClass ? document.documentElement : document.querySelector('[data-first-load]');
        if (root) {
            const state = root.getAttribute('data-first-load');
            const pending = targets.pendingClass
                ? root.classList.contains(targets.pendingClass)
                : state === 'pending' || state === 'loading';
            const shell = nodes(targets.shell);
            const content = nodes(targets.content);
            const shellVisible = shell.some((element) => opacity(element) > 0.001);
            const contentVisible = content.some((element) => opacity(element) > 0.001);
            if (pending) {
                probe.pendingFrames++;
                if (shellVisible || contentVisible) probe.earlyFrames++;
            } else {
                probe.failed ||= state === 'failed' || state === 'error';
                if (shellVisible && probe.shellAt === null) probe.shellAt = now;
                if (contentVisible && probe.contentAt === null) probe.contentAt = now;
                for (const element of [...shell, ...content]) {
                    for (let node = element; node; node = node.parentElement) {
                        for (const animation of node.getAnimations()) {
                            const frames = animation.effect?.getKeyframes() ?? [];
                            if (Number(frames[0]?.opacity) !== 0 || Number(frames.at(-1)?.opacity) !== 1) continue;
                            if (animation.startTime === null) continue;
                            const duration = animation.effect.getTiming().duration;
                            const start =
                                animation.startTime +
                                node.ownerDocument.defaultView.performance.timeOrigin -
                                performance.timeOrigin;
                            if (!probe.animations.some((item) => item.start === start && item.duration === duration))
                                probe.animations.push({ start, duration });
                        }
                    }
                }
            }
        }
        if (now - started < 20000 && (probe.contentAt === null || now - probe.contentAt < 750))
            requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
}

export function assessFirstLoad(probe, reducedMotion) {
    if (!probe || probe.shellAt === null || probe.contentAt === null)
        return { ok: false, detail: 'Shell/content readiness was not observed.' };
    const difference = Math.abs(probe.shellAt - probe.contentAt);
    if (probe.earlyFrames)
        return { ok: false, detail: `Shell/content appeared during ${probe.earlyFrames} pending frames.` };
    if (difference > 34) return { ok: false, detail: `Shell/content arrival differed by ${difference.toFixed(1)}ms.` };
    if (reducedMotion || probe.failed) {
        if (probe.animations.length) return { ok: false, detail: 'Reduced-motion/error entry still animated.' };
    } else {
        if (!probe.animations.length || probe.animations.some((item) => item.duration !== 600))
            return {
                ok: false,
                detail: `Expected a 600ms entrance; observed ${probe.animations.map((item) => item.duration).join(', ') || 'none'}.`,
            };
        const starts = probe.animations.map((item) => item.start);
        if (Math.max(...starts) - Math.min(...starts) > 34)
            return { ok: false, detail: 'Initial shell/content animations did not start together.' };
    }
    return {
        ok: true,
        detail: `${probe.pendingFrames} hidden loading frames; ${difference.toFixed(1)}ms arrival difference; ${probe.failed ? 'error revealed' : reducedMotion ? 'reduced motion' : '600ms entrance'}.`,
    };
}
