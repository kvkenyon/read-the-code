type ThemePreference = 'light' | 'dark' | 'system';

const media = window.matchMedia('(prefers-color-scheme: dark)');

function applyTheme(): void {
  const saved = localStorage.getItem('read-the-code:theme');
  const preference: ThemePreference = saved === 'light' || saved === 'dark' ? saved : 'system';
  document.documentElement.dataset.themePreference = preference;
  document.documentElement.dataset.theme =
    preference === 'system' ? (media.matches ? 'dark' : 'light') : preference;
  document
    .querySelector('meta[name="color-scheme"]')
    ?.setAttribute('content', document.documentElement.dataset.theme ?? 'light dark');
}

applyTheme();
media.addEventListener('change', applyTheme);
window.addEventListener('read-the-code-theme', applyTheme);
