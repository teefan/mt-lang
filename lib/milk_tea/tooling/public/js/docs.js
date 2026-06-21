(function() {
  'use strict';

  var sidebar = document.getElementById('sidebar');
  var overlay = document.getElementById('overlay');
  var menuBtn = document.getElementById('menu-btn');
  var themeToggle = document.getElementById('theme-toggle');
  var themeToggleMbl = document.getElementById('theme-toggle-mbl');
  var progress = document.getElementById('progress');

  // ── Mobile sidebar toggle ──────────────────────────────────
  if (menuBtn) {
    menuBtn.addEventListener('click', function() {
      sidebar.classList.toggle('open');
      overlay.classList.toggle('visible');
    });
  }
  if (overlay) {
    overlay.addEventListener('click', function() {
      sidebar.classList.remove('open');
      overlay.classList.remove('visible');
    });
  }

  // ── Theme ──────────────────────────────────────────────────
  function setTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('mt-docs-theme', theme); } catch(e) {}
  }
  function toggleTheme() {
    var cur = document.documentElement.getAttribute('data-theme');
    setTheme(cur === 'dark' ? 'light' : 'dark');
  }
  function loadTheme() {
    var saved;
    try { saved = localStorage.getItem('mt-docs-theme'); } catch(e) {}
    if (saved === 'dark' || saved === 'light') {
      setTheme(saved);
    }
  }
  if (themeToggle) themeToggle.addEventListener('click', toggleTheme);
  if (themeToggleMbl) themeToggleMbl.addEventListener('click', toggleTheme);
  loadTheme();

  // ── Scroll progress ────────────────────────────────────────
  if (progress) {
    window.addEventListener('scroll', function() {
      var scrollTop = window.scrollY || document.documentElement.scrollTop;
      var docHeight = document.documentElement.scrollHeight - window.innerHeight;
      progress.style.width = docHeight > 0 ? ((scrollTop / docHeight) * 100) + '%' : '0%';
    }, { passive: true });
  }

  // ── Copy code buttons ──────────────────────────────────────
  window.copyCode = function(btn) {
    var pre = btn.parentElement.querySelector('pre');
    if (!pre) return;
    var code = pre.textContent || '';
    navigator.clipboard.writeText(code).then(function() {
      btn.textContent = 'Copied!';
      btn.classList.add('copied');
      setTimeout(function() {
        btn.textContent = 'Copy';
        btn.classList.remove('copied');
      }, 2000);
    }).catch(function() {
      btn.textContent = 'Error';
      setTimeout(function() { btn.textContent = 'Copy'; }, 2000);
    });
  };
})();
