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
    control.value = preference;
    control.addEventListener('change', () => {
      preference = control.value;
      try { localStorage.setItem('solution-deploy-theme', preference); } catch {}
      apply();
    });
  });
})();
