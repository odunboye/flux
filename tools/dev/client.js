/* Injected by Flux --watch only. No application state or credentials are stored. */
(() => {
  'use strict';
  const script = new URL(document.currentScript.src);
  let session = script.searchParams.get('s');
  let reload = Number(script.searchParams.get('r'));
  let css = Number(script.searchParams.get('c'));
  let ui = Number(script.searchParams.get('u') || 0);
  let stopped = false;
  let overlay;
  function report(message, error = false) {
    if (!overlay) {
      overlay = document.createElement('aside');
      overlay.id = 'flux-dev-status';
      overlay.setAttribute('aria-live', 'polite');
      const title = document.createElement('strong');
      title.textContent = 'Flux development';
      const output = document.createElement('pre');
      overlay.append(title, output);
      document.body.append(overlay);
    }
    overlay.hidden = !message;
    overlay.classList.toggle('flux-dev-error', error);
    // Compiler messages may contain source code or HTML: never use innerHTML.
    overlay.querySelector('pre').textContent = message;
  }
  async function refreshCSS(revision) {
    const links = [...document.querySelectorAll('link[rel="stylesheet"]')]
      .filter(link => new URL(link.href).pathname === '/app.css');
    if (!links.length) throw new Error('No app.css stylesheet to refresh');
    await Promise.all(links.map(link => new Promise((resolve, reject) => {
      const replacement = link.cloneNode();
      const url = new URL(link.href);
      url.searchParams.set('flux_reload', String(revision));
      replacement.href = url.href;
      const timer = setTimeout(() => {
        replacement.remove(); reject(new Error('CSS refresh timed out'));
      }, 10000);
      replacement.onload = () => { clearTimeout(timer); link.remove(); resolve(); };
      replacement.onerror = () => {
        clearTimeout(timer); replacement.remove(); reject(new Error('CSS refresh failed'));
      };
      link.after(replacement);
    })));
  }
  async function poll() {
    if (stopped) return;
    try {
      const response = await fetch('/__flux_dev/status', {
        cache: 'no-store', credentials: 'omit', signal: AbortSignal.timeout(5000)
      });
      if (!response.ok) throw new Error('Development connection unavailable');
      const next = await response.json();
      if (next.session !== session || next.reload !== reload) {
        stopped = true;
        location.reload(); // intentionally clears in-memory auth; never replay RPCs
        return;
      }
      if (next.css !== css) {
        await refreshCSS(next.css);
        css = next.css;
      }
      let hotMessage = '';
      if (next.ui !== undefined && next.ui !== ui) {
        const url = '/app.js?flux_hmr=' + next.ui + '&flux_reload=' + reload + '&flux_session=' + session;
        const result = await globalThis.__fluxHot?.replace(url);
        if (result === 'applied') {
          ui = next.ui;
        } else if (result === 'busy') {
          hotMessage = 'UI update ready. Waiting for the application to become idle…';
        } else if (result === 'retry') {
          hotMessage = 'Hot update unavailable. Previous UI retained; retrying…';
        } else {
          stopped = true;
          location.reload(); // incompatible/unsupported state: never transplant raw objects
          return;
        }
      }
      report(next.error || hotMessage || (next.building ? 'Building… Previous successful build is still running.' : ''), !!next.error);
    } catch (_) {
      report('Development connection interrupted. Reconnecting… No application requests are retried.');
    }
    if (!stopped) setTimeout(poll, 500);
  }
  window.addEventListener('pagehide', () => { stopped = true; });
  window.addEventListener('pageshow', event => {
    if (event.persisted) { stopped = false; poll(); }
  });
  poll();
})();
