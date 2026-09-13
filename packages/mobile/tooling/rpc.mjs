// Browser/WebView RPC transport, not a native HTTP plugin. No redirects/retries.
export function validApiOrigin(value) {
  if (typeof value !== 'string' || !value) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.origin === value && !url.username && !url.password &&
      url.pathname === '/' && !url.search && !url.hash;
  } catch { return false; }
}

export function createRpcTransport(origin, fetchImpl = globalThis.fetch) {
  if (!validApiOrigin(origin)) throw new Error('A canonical HTTPS API origin is required');
  return Object.freeze({
    request(method, url, headersJSON, body, timeoutMs, maxBytes, done) {
      const controller = new AbortController();
      let settled = false, timer;
      const finish = (status, text) => {
        if (settled) return;
        settled = true; clearTimeout(timer); done(status, text);
      };
      const cancel = () => { settled = true; clearTimeout(timer); controller.abort(); };
      Promise.resolve().then(async () => {
        if (settled) return;
        const target = new URL(url);
        if (method !== 'POST' || target.origin !== origin || !target.pathname.startsWith('/rpc/v1/') ||
            target.username || target.password || target.search || target.hash ||
            !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000 ||
            !Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > 10485760)
          throw new Error('Invalid mobile RPC request');
        const headers = new Headers(JSON.parse(headersJSON));
        for (const key of headers.keys()) if (!['authorization', 'content-type'].includes(key))
          throw new Error('Unsupported RPC header');
        if (headers.get('content-type') !== 'application/json') throw new Error('JSON RPC is required');
        timer = setTimeout(() => { finish(-2, 'Request timed out'); controller.abort(); }, timeoutMs);
        const response = await fetchImpl(target.href, {method, headers, body, credentials:'omit',
          redirect:'error', cache:'no-store', mode:'cors', signal:controller.signal});
        if (settled) return;
        if (Number(response.headers.get('content-length')) > maxBytes) {
          finish(-3, 'Response exceeds limit'); controller.abort(); return;
        }
        const reader = response.body?.getReader();
        let size = 0, text = '';
        const decoder = new TextDecoder('utf-8', {fatal:true});
        if (reader) try {
          while (!settled) {
            const chunk = await reader.read();
            if (chunk.done) break;
            size += chunk.value.byteLength;
            if (size > maxBytes) {
              finish(-3, 'Response exceeds limit'); controller.abort(); await reader.cancel(); return;
            }
            text += decoder.decode(chunk.value, {stream:true});
          }
          text += decoder.decode();
        } finally { reader.releaseLock(); }
        finish(response.status, text);
      }).catch(() => finish(-1, 'Mobile RPC unavailable; no request has been retried'));
      return Object.freeze({cancel});
    },
  });
}
