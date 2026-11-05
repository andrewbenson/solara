import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { searchPage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node selection-popover-test.mjs <Debug Solara.app> [--keep-data]

The selection search bar over a local page whose custom search engine is a local URL, drawn by RN and then natively
(SOLARA_NATIVE_SHELL=1: SelectionBarView in the tab's pane overlay container on top of the shell's card). A word selected in the page, as a mouse selection reports it, brings the bar up 6 above it
(and below a word near the top), centred on it and kept 8 inside the page; the bar and its Search button sit on the same window frames in both
within half a point, RN draws no bar with the switch on, the native bar fades in, and a click on Search through the
window searches the custom engine for the word and takes the bar down. A third run pools the page: RN mounts no
SelectionPopover and the bar comes from the pool's page messages, on the same frames, and searches the same way.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-selection-popover-"));
const rep = reporter(join(scratch, "selection-popover-test.log"), { name: "selection-popover-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  if (req.url.startsWith("/search")) return res.end(searchPage(req.url));
  res.end(`<!doctype html><title>WORDS</title><link rel="icon" href="data:,"><body style="margin:0;font:16px sans-serif">
<p style="position:absolute;left:10px;top:4px;margin:0"><span id="top">topmost</span></p>
<p style="position:absolute;left:300px;top:300px;margin:0">some <span id="mid">selectable</span> words</p></body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const fixtureWith = (settings) => session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/words`, title: "WORDS" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, customSearchUrl: `${base}/search?q=%s`, searchEngine: "custom", ...settings },
});
const fixture = fixtureWith({ showSelectionSearch: true });

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const native = () => M && M.describePaneOverlays ? M.describePaneOverlays("w1").then(JSON.parse) : Promise.resolve(null);
const rnBar = () => acPerf.findFibers("Bar", 500).find((f) => f.memoizedProps && f.memoizedProps.selection && f.memoizedProps.area);
const rn = () => { const bar = rnBar(); const button = fibers("SearchButton")[0]; return bar && button ? Promise.all([measure(bar), measure(button)]) : Promise.resolve(null); };
const rnSettled = () => rn().then((a) => a && settle(200).then(rn).then((b) => JSON.stringify(a) === JSON.stringify(b) ? b : null));
`;
let app = null;
let page = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const nativeFrame = (frame) => frame && [frame.x, frame.y, frame.width, frame.height];
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    if (!app?.alive) throw new Error(`${what}: the owned app exited`);
    if (deadline - Date.now() < 1000) break;
    last = await app.snapshot({}, { timeout: 1000 });
    if (Date.now() < deadline && last.consistent && await accept(last) && Date.now() < deadline) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const select = (id) => page.eval(`(() => {
  const opts = { bubbles: true, button: 0 };
  document.dispatchEvent(new MouseEvent("mousedown", opts));
  const range = document.createRange();
  range.selectNodeContents(document.getElementById(${JSON.stringify(id)}));
  getSelection().removeAllRanges();
  getSelection().addRange(range);
  document.dispatchEvent(new MouseEvent("mouseup", opts));
  const r = range.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height];
})()`);
const got = {};

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data-default"), fresh: true, session: fixtureWith({}), onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_SHELL_PANES: "0" },
    ready: "return !!ac.store.getState().windows.w1",
  });
  await until("the page", `return ac.store.getState().tabs.a?.title === "WORDS" || null;`, 15000);
  page = await app.page("/words");
  await rep.check("default-off", async () => {
    if (await run(`return ac.store.getState().settings.showSelectionSearch;`) !== false) throw new Error("showSelectionSearch is not off by default");
    await select("mid");
    await sleep(1500);
    const shown = await run(`return native().then((d) => !!(d && d.tabs.a && d.tabs.a.selection) || fibers("SearchButton").length > 0 || !!rnBar());`);
    if (shown) throw new Error("the Search bubble showed with the setting at its default");
    return { shown };
  });
  page.close();
  page = null;
  await app.quit();
  app = null;

  for (const tag of ["rn", "native", "prompts"]) {
    const nativeShell = tag !== "rn";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: tag === "prompts"
        ? { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" }
        : { SOLARA_NATIVE_SHELL: nativeShell ? "1" : "0", SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_SHELL_PANES: "0" },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    await until("the page", `return ac.store.getState().tabs.a?.title === "WORDS" || null;`, 15000);
    page = await app.page("/words");

    for (const [id, above] of [["mid", true], ["top", false]]) {
      await rep.check(`${tag}-${id}`, async () => {
        const word = await select(id);
        const read = `return (${nativeShell ? `native().then((d) => { const s = d && d.tabs.a && d.tabs.a.selection; return s && s.bar && s.opacity === 1 ? [s.bar, s.button, s.area, s.above] : null; })` : "rnSettled()"});`;
        let f = await until(`the bar over #${id}`, read, 3000);
        if (nativeShell) {
          await untilSnapshot("the native selection", async (state) => {
            f = await run(read);
            if (!f) return false;
            const tab = state.tabs.find((t) => t.id === "a");
            const overlay = state.windows.find((w) => w.id === "w1")?.overlays.find((o) => o.tabId === "a");
            return tab?.url === `${base}/words` && tab.title === "WORDS" && overlay &&
              near(nativeFrame(overlay.frame), f[0]) && near(nativeFrame(overlay.controls[0]?.frame), f[1]) &&
              near(nativeFrame(overlay.area), f[2]) && overlay.opacity === 1 && overlay.above === above && f[3] === above;
          });
          if (await run(`return fibers("SearchButton").length > 0 || !!rnBar();`)) throw new Error("RN still draws the bar");
          const [bar] = f;
          const area = f[2];
          const wordTop = area[1] + word[1];
          const wantY = above ? wordTop - 6 - 32 : area[1] + word[1] + word[3] + 6;
          const wantX = area[0] + Math.max(8, Math.min(word[0] + word[2] / 2 - bar[2] / 2, area[2] - bar[2] - 8));
          if (Math.abs(bar[1] - wantY) > 0.5 || Math.abs(bar[0] - wantX) > 0.5) throw new Error(`bar ${bar} for word ${word} in ${area}`);
        }
        const [bar, button] = f;
        got[`${tag}-${id}`] = [bar, button];
        await page.eval(`getSelection().removeAllRanges(); document.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0 })); document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, button: 0 })); true`);
        await sleep(300);
        return { bar, button };
      });
    }

    if (nativeShell) {
      await rep.check(`${tag}-search-click`, async () => {
        await select("mid");
        const f = await until("the bar again", `return native().then((d) => { const s = d && d.tabs.a && d.tabs.a.selection; return s && s.button && s.opacity === 1 ? s.button : null; });`, 3000);
        await run(`return click(${number}, ${JSON.stringify(centre(f))}).then(() => true);`);
        const readSearch = `return Object.values(ac.store.getState().tabs).map((t) => t.url).find((u) => u.includes("/search?q=selectable")) || null;`;
        let searched = await until("the search", readSearch, 5000);
        await until("the bar goes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.selection || null);`, 3000);
        const snapshot = await untilSnapshot("native search landing", async (state) => {
          searched = await run(readSearch);
          return !!searched && state.tabs.some((t) => t.url === searched && t.url.includes("/search?q=selectable") && t.title === "RESULTS") &&
            !state.windows.some((w) => w.overlays.some((o) => o.tabId === "a" && o.visible));
        }, 5000);
        if (!snapshot.tabs.some((t) => t.title === "RESULTS")) throw new Error("native search title missing");
        return { searched };
      });
    }
    page.close();
    page = null;
    await app.quit();
    app = null;
  }
  for (const tag of ["native", "prompts"]) {
    await rep.check(`${tag}-matches-rn`, async () => {
      for (const id of ["mid", "top"]) {
        const [nb, nbtn] = got[`${tag}-${id}`];
        const [rb, rbtn] = got[`rn-${id}`];
        if (!near(nb, rb) || !near(nbtn, rbtn)) throw new Error(`#${id}: ${tag} ${nb} / ${nbtn}, RN ${rb} / ${rbtn}`);
      }
      return got;
    });
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  page?.close();
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
