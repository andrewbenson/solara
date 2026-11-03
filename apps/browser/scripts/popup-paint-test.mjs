import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node popup-paint-test.mjs <Debug Solara.app> [--keep-data]

A page's window.open(url, name, "popup,…") opens a popup window that shows the page: under the origin strip, the
popup window's own pixels (captured in-process, popupPixels) are the page's background colour, not the window
background. Checked for a popup that stays on its first page and for one that navigates cross-site to a page with
Cross-Origin-Opener-Policy: same-origin, as Google's and Slack's sign-in pages do. The page also has to be visible
and drawing (visibilityState, requestAnimationFrame).`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-popup-paint-"));
const rep = reporter(join(scratch, "popup-paint-test.log"), { name: "popup-paint-test" });

const PAGE_COLOR = "2f7de8";
const PAGE = `<!doctype html><title>popup page</title><body style="margin:0;background:#${PAGE_COLOR}">popup page`;
const server = createServer((req, res) => {
  if (req.url.startsWith("/cross")) {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>cross</title><script>location.replace("http://localhost:${server.address().port}/coop")</script>`);
  }
  if (req.url.startsWith("/coop")) {
    res.writeHead(200, { "content-type": "text/html", "cross-origin-opener-policy": "same-origin" });
    return res.end(PAGE);
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(req.url.startsWith("/popup") ? PAGE : "<!doctype html><title>opener</title><body>opener");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${origin}/opener`, title: "opener" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

async function popupDraws(name, env, open = "/popup", lands = "/popup") {
  const data = join(scratch, `data-${name}`);
  const app = await launch(appArg, { data, session: fixture, env, ready: "return !!ac.store" });
  rep.log(`${name}: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  const cef = (expr) => app.eval(`return globalThis.expo.modules.SolaraCEF.${expr};`, { timeout: 10000 });
  const pageEval = async (urlPart, expression, options = {}) => {
    const page = await app.page(urlPart);
    try {
      return await page.eval(expression, { timeout: 5000, ...options });
    } finally {
      page.close();
    }
  };
  const until = async (what, accept, ms = 10000) => {
    const end = Date.now() + ms;
    let last;
    while (Date.now() < end) {
      last = await accept().catch((e) => ({ error: String(e.message ?? e) }));
      if (last && !last.error && last.ok) return last;
      await sleep(250);
    }
    throw new Error(`${what}: ${JSON.stringify(last)}`);
  };
  try {
    await until("the opener page loads", async () => ({ ok: (await pageEval("/opener", "document.readyState")) === "complete" }));
    const before = (await cef("engineInfo()")).popupWindows;
    await pageEval("/opener", `(window.__popup = window.open(${JSON.stringify(`${origin}${open}`)}, "signin", "popup,width=500,height=600")), true`, { userGesture: true });
    const popup = await until("a popup window opens", async () => {
      const info = await cef("engineInfo()");
      return { ok: info.popupWindows > before, window: info.popupOrigins.at(-1)?.window };
    });
    await until("the popup page loads", async () => ({ ok: (await pageEval(lands, "document.readyState")) === "complete" }), 15000);
    await sleep(1000);
    const page = await pageEval(lands, `new Promise((done) => {
      let frames = 0;
      const start = performance.now();
      const tick = () => { frames++; if (performance.now() - start < 550) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
      setTimeout(() => done({ visibility: document.visibilityState, frames }), 600);
    })`);
    const native = await cef(`devWindow(${popup.window}, "popupPage")`).then((s) => { try { const j = JSON.parse(s); return { pageInHost: j.pageInHost, pageInWindow: j.pageInWindow, hidden: j.page?.hiddenOrAncestor }; } catch { return s; } });
    const pixels = await cef(`devWindow(${popup.window}, "popupPixels")`).then((s) => { try { const j = JSON.parse(s); return { uniform: j.uniform, page: j.page, grid: j.grid, error: j.error }; } catch { return s; } });
    return { ...page, native, pixels };
  } finally {
    await app.quit().catch(() => {});
  }
}

const distance = (hex) => {
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) - parseInt(PAGE_COLOR.slice(i, i + 2), 16));
  return Math.hypot(r, g, b);
};
const pageColored = (out) => Array.isArray(out.pixels?.grid) && out.pixels.grid.filter((cell) => distance(cell) < 60).length >= out.pixels.grid.length * 0.9;
const drawing = (out) => out.visibility === "visible" && out.frames >= 10 && pageColored(out);
try {
  await rep.check("a popup window shows its page under the origin strip", async () => {
    const out = await popupDraws("same-site", {});
    if (!drawing(out)) throw new Error(`the popup window isn't showing the page: ${JSON.stringify(out)}`);
    return { visibility: out.visibility, frames: out.frames, uniform: out.pixels.uniform, cell: out.pixels.grid[20] };
  });
  await rep.check("a popup that navigates cross-site to a COOP page shows it", async () => {
    const out = await popupDraws("coop", {}, "/cross", "/coop");
    if (!drawing(out)) throw new Error(`the popup window isn't showing the page: ${JSON.stringify(out)}`);
    return { visibility: out.visibility, frames: out.frames, uniform: out.pixels.uniform, cell: out.pixels.grid[20] };
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
