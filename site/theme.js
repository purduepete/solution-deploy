(() => {
  const preference = matchMedia('(prefers-color-scheme: dark)');
  const stored = localStorage.getItem('solution-deploy-theme');
  const apply = (theme) => {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="theme-color"]').content = theme === 'dark' ? '#10111a' : '#f4f5fa';
  };
  apply(stored === 'dark' || stored === 'light' ? stored : preference.matches ? 'dark' : 'light');
  preference.addEventListener('change', () => {
    if (!localStorage.getItem('solution-deploy-theme')) apply(preference.matches ? 'dark' : 'light');
  });
  document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('theme').addEventListener('click', () => {
      const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      localStorage.setItem('solution-deploy-theme', theme);
      apply(theme);
    });
  });
})();
