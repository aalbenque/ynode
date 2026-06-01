(() => {
  const box    = document.getElementById('response-box');
  const inp    = document.getElementById('inp-path');
  const sel    = document.getElementById('sel-method');
  const btnSend  = document.getElementById('btn-send');
  const btnClear = document.getElementById('btn-clear');

  function colorStatus(code) {
    if (code >= 200 && code < 300) return '#a6e3a1';
    if (code >= 300 && code < 400) return '#89dceb';
    if (code >= 400 && code < 500) return '#fab387';
    return '#f38ba8';
  }

  async function fireRequest() {
    const method = sel.value;
    const path   = inp.value.trim() || '/';
    box.textContent = `${method} ${path}  …`;

    const t0 = performance.now();
    try {
      const res = await fetch(path, { method, redirect: 'manual' });
      const ms  = (performance.now() - t0).toFixed(0);

      let headerLines = '';
      res.headers.forEach((v, k) => { headerLines += `  ${k}: ${v}\n`; });

      let body = '';
      if (method !== 'HEAD') {
        const ct = res.headers.get('content-type') || '';
        if (ct.startsWith('text') || ct.includes('json') || ct.includes('xml')) {
          body = await res.text();
          if (body.length > 800) body = body.slice(0, 800) + '\n… (truncated)';
        } else {
          body = `[binary: ${res.headers.get('content-length') ?? '?'} bytes]`;
        }
      }

      const statusColor = colorStatus(res.status);
      box.innerHTML =
        `<span style="color:${statusColor};font-weight:600">HTTP ${res.status} ${res.statusText || ''}</span>  ` +
        `<span style="color:#6c7086">${ms}ms</span>\n` +
        `<span style="color:#89b4fa">${headerLines}</span>` +
        (body ? `\n<span style="color:#cdd6f4">${escHtml(body)}</span>` : '');
    } catch (err) {
      box.innerHTML = `<span style="color:#f38ba8">Fetch error: ${escHtml(String(err))}</span>`;
    }
  }

  function escHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  btnSend.addEventListener('click', fireRequest);
  inp.addEventListener('keydown', e => { if (e.key === 'Enter') fireRequest(); });
  btnClear.addEventListener('click', () => { box.textContent = '— hit Send to fire a request —'; });

  document.querySelectorAll('[data-path]').forEach(btn => {
    btn.addEventListener('click', () => {
      inp.value = btn.dataset.path;
      fireRequest();
    });
  });
})();
