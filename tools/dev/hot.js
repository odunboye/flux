/* Flux DOM HMR bridge, loaded before the application only by dev --hot.
   State payloads live in closures, never storage, URLs, diagnostics or requests. */
(() => {
  'use strict';
  if (globalThis.__fluxHot) return;
  let active = null;
  let mounting = null;
  let loading = false;
  let pending = null;
  let candidate = null;
  let candidateURL = null;
  let inProgress = false;
  function mount(factory) {
    mounting = factory;
    try {
      factory.start();
      if (mounting) throw new Error('Hot runtime did not attach');
    } finally { mounting = null; }
  }
  async function load(url) {
    if (candidate && candidateURL === url) return candidate;
    candidate = null; candidateURL = null;
    loading = true; pending = null;
    const script = document.createElement('script');
    script.src = url;
    script.dataset.fluxHmr = '1';
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Hot script timed out')), 15000);
        script.onload = () => { clearTimeout(timer); resolve(); };
        script.onerror = () => { clearTimeout(timer); reject(new Error('Hot script failed')); };
        document.head.append(script);
      });
      candidate = pending;
      candidateURL = url;
      return candidate;
    } finally {
      script.remove(); pending = null; loading = false;
    }
  }
  const bridge = {
    loading: () => loading || document.currentScript?.dataset.fluxHmr === '1',
    offer(factory) {
      if (loading) {
        if (pending) throw new Error('Multiple hot applications in one bundle');
        pending = factory;
      } else if (document.currentScript?.dataset.fluxHmr === '1') {
        // A timed-out/removed script may still execute later. Never let it
        // mount a runtime after its load attempt has been abandoned.
        return;
      } else if (!active) {
        mount(factory);
      } else {
        throw new Error('Unexpected hot registration');
      }
    },
    attach(runtime) {
      if (!mounting) throw new Error('Unexpected hot runtime');
      active = {...runtime, version: mounting.version};
      mounting = null;
    },
    async replace(url) {
      if (!active) return 'reload';
      if (inProgress) return 'busy';
      inProgress = true;
      try {
        // Deferral drains queued inputs using the old event maps. A click which
        // starts a write can make save return busy before any script is fetched.
        if (!active.snapshot()) return 'busy';
        let next;
        try { next = await load(url); }
        catch (_) { return 'retry'; } // keep the active runtime on transport failure
        if (!next || next.version !== active.version) return 'reload';
        let saved = active.snapshot();
        if (!saved) return 'busy';
        if (saved.length > 2 * 1024 * 1024 || saved[0] !== '1') return 'reload';
        let accepted;
        try { accepted = Number(next.prepare(saved.slice(1))) === 1; }
        finally { saved = null; }
        if (!accepted) return 'reload';
        // Preflight succeeded; no JS event can interleave this synchronous
        // disposal/mount. Quit + cancellation guards reject old callbacks.
        const old = active;
        active = null;
        old.dispose();
        mount(next);
        candidate = null; candidateURL = null;
        return 'applied';
      } catch (_) {
        // Never include an application exception: it may contain the snapshot.
        // Reload is safer than retaining a half-initialized replacement runtime.
        return 'reload';
      } finally { inProgress = false; }
    }
  };
  globalThis.__fluxHot = Object.freeze(bridge);
})();
