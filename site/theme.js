(() => {
    const media = matchMedia('(prefers-color-scheme: dark)');
    let preference = 'midnight';
    try {
        const stored = localStorage.getItem('solution-deploy-theme');
        if (stored === 'dark') preference = 'midnight';
        else if (['system', 'light', 'midnight'].includes(stored)) preference = stored;
    } catch {}
    const apply = () => {
        const theme = preference === 'system' ? (media.matches ? 'midnight' : 'light') : preference;
        const root = document.documentElement;
        root.dataset.theme = theme;
        root.classList.toggle('light', theme === 'light');
        root.classList.toggle('dark', theme !== 'light');
        root.classList.toggle('theme-midnight', theme === 'midnight');
        root.style.colorScheme = theme === 'light' ? 'light' : 'dark';
        root.style.backgroundColor = theme === 'light' ? '#ffffff' : '#0f172a';
        document.querySelector('meta[name="theme-color"]').content = theme === 'light' ? '#ffffff' : '#0f172a';
    };
    apply();
    media.addEventListener('change', () => {
        if (preference === 'system') apply();
    });
    document.addEventListener('DOMContentLoaded', () => {
        const control = document.getElementById('theme');
        const value = document.getElementById('theme-value');
        const menu = document.getElementById('theme-menu');
        const picker = document.getElementById('theme-picker');
        const options = [...menu.querySelectorAll('[data-theme-preference]')];
        const selectedIndex = () => options.findIndex((option) => option.dataset.themePreference === preference);
        const sync = () => {
            value.textContent = options[selectedIndex()].querySelector('span').textContent;
            control.setAttribute('aria-label', `Theme: ${value.textContent}`);
            picker.style.setProperty('--theme-index', selectedIndex());
            options.forEach((option) => {
                const selected = option.dataset.themePreference === preference;
                option.setAttribute('aria-pressed', String(selected));
                option.tabIndex = selected ? 0 : -1;
            });
        };
        const close = (returnFocus = false) => {
            menu.hidden = true;
            control.setAttribute('aria-expanded', 'false');
            if (returnFocus) control.focus();
        };
        const open = (index = selectedIndex()) => {
            menu.hidden = false;
            control.setAttribute('aria-expanded', 'true');
            options[index].focus();
        };
        sync();
        control.addEventListener('click', () => {
            if (menu.hidden) open();
            else close(true);
        });
        control.addEventListener('keydown', (event) => {
            if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
                event.preventDefault();
                open(event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 : selectedIndex());
            }
        });
        options.forEach((option, index) => {
            option.addEventListener('click', () => {
                preference = option.dataset.themePreference;
                try {
                    localStorage.setItem('solution-deploy-theme', preference);
                } catch {}
                apply();
                sync();
                close(true);
            });
            option.addEventListener('keydown', (event) => {
                let next;
                if (['ArrowDown', 'ArrowRight'].includes(event.key)) next = (index + 1) % options.length;
                if (['ArrowUp', 'ArrowLeft'].includes(event.key)) next = (index + options.length - 1) % options.length;
                if (event.key === 'Home') next = 0;
                if (event.key === 'End') next = options.length - 1;
                if (next !== undefined) {
                    event.preventDefault();
                    options[next].focus();
                } else if (event.key === 'Escape') {
                    event.preventDefault();
                    close(true);
                } else if (event.key === 'Tab') {
                    // Restore the trigger before the browser advances to the next tab stop.
                    close(true);
                }
            });
        });
        document.addEventListener('pointerdown', (event) => {
            if (!control.contains(event.target) && !menu.contains(event.target)) close();
        });
        document.addEventListener('focusin', (event) => {
            if (!control.contains(event.target) && !menu.contains(event.target)) close();
        });
    });
})();
