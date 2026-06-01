(() => {
  const out = document.getElementById('fetch-out');

  function statusColor(c) {
    if (c >= 200 && c < 300) return '#a6e3a1';
    if (c >= 300 && c < 400) return '#89dceb';
    if (c >= 400 && c < 500) return '#fab387';
    return '#f38ba8';
  }

  function escHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  async function doFetch(path, method) {
    out.textContent = `${method} ${path}  …`;
    const t0 = performance.now();
    try {
      const res = await fetch(path, { method, redirect: 'manual' });
      const ms  = (performance.now() - t0).toFixed(0);
      let hdrs = '';
      res.headers.forEach((v, k) => { hdrs += `  <span style="color:#89b4fa">${k}</span>: ${escHtml(v)}\n`; });
      let body = '';
      const ct = res.headers.get('content-type') || '';
      if (method !== 'HEAD' && (ct.startsWith('text') || ct.includes('json'))) {
        const txt = await res.text();
        body = '\n' + escHtml(txt.length > 600 ? txt.slice(0,600) + '\n…(truncated)' : txt);
      }
      const col = statusColor(res.status);
      out.innerHTML =
        `<span style="color:${col};font-weight:600">HTTP ${res.status}</span>  ` +
        `<span style="color:#6c7086">${ms}ms</span>\n${hdrs}${body}`;
    } catch(e) {
      out.innerHTML = `<span style="color:#f38ba8">Error: ${escHtml(String(e))}</span>`;
    }
  }

  document.querySelectorAll('[data-fetch]').forEach(btn => {
    btn.addEventListener('click', () => doFetch(btn.dataset.fetch, btn.dataset.method));
  });

  document.getElementById('btn-raw').addEventListener('click', () => {
    const body = document.getElementById('raw-body').value;
    out.textContent = 'POST /index.php (text/plain)  …';
    const t0 = performance.now();
    fetch('/index.php', {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: body
    }).then(async r => {
      const ms  = (performance.now() - t0).toFixed(0);
      const col = statusColor(r.status);
      const txt = await r.text();
      const match = txt.match(/class="term"[^>]*>([\s\S]*?)<\/div>/);
      if (match) {
        out.innerHTML = `<span style="color:${col};font-weight:600">HTTP ${r.status}</span>  <span style="color:#6c7086">${ms}ms</span>\n` + match[1].trim();
      } else {
        out.innerHTML = `<span style="color:${col};font-weight:600">HTTP ${r.status}</span>  <span style="color:#6c7086">${ms}ms</span>\n<span style="color:#a6e3a1">body: ${escHtml(body.slice(0,200))}</span>`;
      }
    }).catch(e => { out.innerHTML = `<span style="color:#f38ba8">${escHtml(String(e))}</span>`; });
  });

  document.getElementById('btn-json').addEventListener('click', () => {
    const raw = document.getElementById('json-body').value;
    out.textContent = 'POST /index.php (application/json)  …';
    const t0 = performance.now();
    fetch('/index.php', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: raw
    }).then(async r => {
      const ms  = (performance.now() - t0).toFixed(0);
      const col = statusColor(r.status);
      const txt = await r.text();
      const match = txt.match(/class="term"[^>]*>([\s\S]*?)<\/div>/);
      if (match) {
        out.innerHTML = `<span style="color:${col};font-weight:600">HTTP ${r.status}</span>  <span style="color:#6c7086">${ms}ms</span>\n` + match[1].trim();
      } else {
        out.textContent = `HTTP ${r.status}  ${ms}ms`;
      }
    }).catch(e => { out.innerHTML = `<span style="color:#f38ba8">${escHtml(String(e))}</span>`; });
  });
})();
