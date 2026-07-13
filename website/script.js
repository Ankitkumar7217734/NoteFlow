// Footer year
document.getElementById('year').textContent = new Date().getFullYear();

const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

// ===== Theme toggle (mirrors the app's Paper & Ink light/dark switch) =====
const themeToggle = document.getElementById('themeToggle');
const themeMeta = document.querySelectorAll('meta[name="theme-color"]');
function applyTheme(theme, persist) {
  document.documentElement.dataset.theme = theme;
  if (themeToggle) {
    themeToggle.setAttribute('aria-label', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
  }
  themeMeta.forEach(m => m.setAttribute('content', theme === 'dark' ? '#151412' : '#F0F0EA'));
  if (persist) {
    try { localStorage.setItem('noteflow-theme', theme); } catch (e) { }
  }
}
applyTheme(document.documentElement.dataset.theme || 'light', false);
themeToggle?.addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  applyTheme(next, true);
});
// Follow system changes unless the user picked a theme explicitly
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => {
  let stored = null;
  try { stored = localStorage.getItem('noteflow-theme'); } catch (err) { }
  if (!stored) applyTheme(e.matches ? 'dark' : 'light', false);
});

// Smooth scrolling for in-page anchors (instant when reduced motion is on)
document.querySelectorAll('a[href^="#"]').forEach(link => {
  link.addEventListener('click', e => {
    const id = link.getAttribute('href');
    if (id.length > 1) {
      const target = document.querySelector(id);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({
          behavior: prefersReducedMotion.matches ? 'auto' : 'smooth',
          block: 'start'
        });
      }
    }
  });
});

// Listen for the actual Option+D combo and flash the hero hotkey bubble
document.addEventListener('keydown', e => {
  if (e.altKey && (e.key === 'd' || e.key === 'D' || e.code === 'KeyD')) {
    const pop = document.querySelector('.hotkey-pop');
    if (pop && !prefersReducedMotion.matches) {
      pop.style.transition = 'transform 0.2s ease, box-shadow 0.2s ease';
      pop.style.transform = 'scale(1.18) rotate(-3deg)';
      pop.style.boxShadow = '0 20px 50px rgba(227,111,58,0.45)';
      setTimeout(() => {
        pop.style.transform = '';
        pop.style.boxShadow = '';
      }, 350);
    }
  }
});

// Hamburger toggles the mock sidebar
const sidebar = document.getElementById('appSidebar');
const hamburger = document.getElementById('hamburgerBtn');
const toggleCTA = document.getElementById('toggleSidebarCTA');
function toggleMockSidebar() {
  if (!sidebar) return;
  sidebar.classList.toggle('collapsed');
  const label = hamburger?.querySelector('.sb-label');
  if (label) label.textContent = sidebar.classList.contains('collapsed') ? 'Show Notes' : 'Collapse Notes';
}
hamburger?.addEventListener('click', toggleMockSidebar);
toggleCTA?.addEventListener('click', toggleMockSidebar);

// Auto-demo: collapse + expand once when the mock first scrolls into view
if (!prefersReducedMotion.matches) {
  const mockObserver = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting && sidebar) {
        setTimeout(() => sidebar.classList.add('collapsed'), 800);
        setTimeout(() => sidebar.classList.remove('collapsed'), 2200);
        mockObserver.unobserve(entry.target);
      }
    });
  }, { threshold: 0.4 });
  const mock = document.getElementById('appMock');
  if (mock) mockObserver.observe(mock);
}

// Reveal-on-scroll for feature cards, bento cards & shortcuts
if (!prefersReducedMotion.matches) {
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.style.opacity = '1';
        entry.target.style.transform = 'translateY(0)';
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.15 });

  document.querySelectorAll('.feature-card, .bento-card, .shortcut').forEach((el, i) => {
    el.style.opacity = '0';
    el.style.transform = 'translateY(16px)';
    el.style.transition = `opacity 0.5s ease ${(i % 6) * 60}ms, transform 0.5s ease ${(i % 6) * 60}ms`;
    observer.observe(el);
  });
}
