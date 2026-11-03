export function escapeHtml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

export function fixturePage(name, { title = name.toUpperCase(), bodyStyle = "", bodyPrefix = "" } = {}) {
  return `<!doctype html><title>${escapeHtml(title)}</title><link rel="icon" href="data:,"><body${bodyStyle ? ` style="${escapeHtml(bodyStyle)}"` : ""}>${bodyPrefix}${escapeHtml(name)}</body>`;
}

export function developerPage(url) {
  return `<!doctype html><title>dev</title><body style="margin:0;background:#3a6ea5;color:white">${escapeHtml(url)}</body>`;
}

export function loadingPageHtml(name) {
  return `<!doctype html><title>${escapeHtml(name)}</title><p>${escapeHtml(name)}-findme</p>`;
}

export function placementPage(name) {
  return `<!doctype html><title>${escapeHtml(name.toUpperCase())}</title><link rel="icon" href="data:,"><body style="margin:0;height:4000px;font:16px sans-serif;caret-color:transparent;background:#fff">
<p style="position:absolute;left:300px;top:300px;margin:0">some <span id="mid">selectable</span> words</p></body>`;
}

export function poolPage(path, slow) {
  return `<!doctype html><title>${escapeHtml(path.toUpperCase())}</title><link rel="icon" href="/icon.png"><body style="height:2000px;font:16px sans-serif">
<p>a needle and another needle</p>${slow}</body>`;
}

export function historyPage(url) {
  return `<!doctype html><title>${escapeHtml(url)}</title><h1>${escapeHtml(url)}</h1>`;
}

export function searchPage(url) {
  return `<!doctype html><title>RESULTS</title><link rel="icon" href="data:,"><body>${escapeHtml(url)}</body>`;
}

export function modalPage(url) {
  return `<!doctype html><title>${escapeHtml(url)}</title><link rel="icon" href="data:,"><body><button>Inside the page</button></body>`;
}

export function rekeyPage(page) {
  return `<!doctype html><title>Rekey ${escapeHtml(page)}</title><h1>${escapeHtml(page)}</h1><form><input name="username" autocomplete="username"><input type="password" autocomplete="current-password"></form>`;
}

export function shortcutPage(name) {
  return `<!doctype html><title>${escapeHtml(name)}</title><body style="font:20px system-ui"><h1>${escapeHtml(name)}</h1><input id=f value="hello field" style="position:fixed;left:20px;top:120px;width:300px;height:30px">`;
}
