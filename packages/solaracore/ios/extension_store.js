const g = window;
if (!g.__solaraStore) {
  const store = (g.__solaraStore = { waiting: null, queued: [] });
  const request = (id) => {
    if (!id) return;
    if (store.waiting) { const w = store.waiting; store.waiting = null; w(id); } else store.queued.push(id);
  };
  const mg = g.chrome && g.chrome.management;
  if (mg && typeof mg.uninstall === "function") {
    Object.defineProperty(mg, "uninstall", { configurable: true, writable: true, value: (id, options, callback) => {
      request(id);
      const done = typeof options === "function" ? options : callback;
      if (typeof done === "function") { setTimeout(done); return; }
      return Promise.resolve();
    } });
  }
  const relabel = () => {
    for (const el of document.querySelectorAll("button, button *")) {
      if (el.childElementCount) continue;
      const t = el.textContent;
      if (t === "Add to Chrome") el.textContent = "Add to " + "__SOLARA_PRODUCT__";
      else if (t === "Remove from Chrome") el.textContent = "Remove from " + "__SOLARA_PRODUCT__";
    }
  };
  relabel();
  new MutationObserver(relabel).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
}
const store = g.__solaraStore;
if (store.queued.length) post("result", JSON.stringify(store.queued.shift()));
else store.waiting = (id) => post("result", JSON.stringify(id));
