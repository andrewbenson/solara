import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node tab-pickers-test.mjs <Debug Solara.app> [--keep-data]

Search Tabs and the Ctrl-Tab switcher in the native shell: search opens focused, typing and Return select the
highlighted match, Down selects the next match, a row click selects its tab, and closed rows restore tabs.
Escape and outside clicks close search without switching, and Escape restores focus. The switcher waits for
its delay, shows the store's rows, and commits row presses with both delayed and immediate mouse-up.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-tab-pickers-"));
const rep = reporter(join(scratch, "tab-pickers-test.log"), { name: "tab-pickers-test" });

const PAGES = { a: "Inbox Mail", b: "Docs Editor", c: "News Today", d: "Daily Notes", e: "Recipe Box" };
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(req.url.slice(1), { title: PAGES[req.url.slice(1)] ?? "?" }));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (id) => `http://127.0.0.1:${server.address().port}/${id}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: Object.entries(PAGES).map(([id, title]) => ({ id, url: url(id), title })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const H = globalThis.expo.modules.SolaraHosted;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const ui = () => ac.sidebarRows.useSidebarUi.getState();
const active = () => ac.store.getState().windows.w1.activeTabIds.default;
const native = () => H.tabPickers("w1").then(JSON.parse);
const act = (n, a) => C.devWindow(n, a);
const key = (n, chars, code) => act(n, "keys:0:" + chars + (code === undefined ? "" : ":" + code));
const type = (n, text) => [...text].reduce((p, ch) => p.then(() => key(n, ch)).then(() => settle(40)), Promise.resolve());
const click = (n, p, gap) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(gap)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
`;
const KEYS = { down: ["", 125], enter: ["\r", 36], escape: ["\u001b", 53] };
let app = null;
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
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!ac.sidebarRows",
  });
  const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
  const press = (name) => run(`return key(${number}, ${JSON.stringify(KEYS[name][0])}, ${KEYS[name][1]});`);
  for (const id of ["b", "c", "d", "e", "a"]) {
    await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
    await sleep(250);
  }
  const openSearch = async () => {
    await run(`ac.runCommand({ command: "searchTabs", windowId: "w1" }); return true;`);
    return until("the native search panel", `return native().then((d) => d.search && d.search.typing ? d.search : null);`, 4000);
  };
  const searchClosed = () =>
    until("search closes", `return ui().searchTabs === null && native().then((d) => !d.search || null);`, 3000);
  const selected = () => run(`return native().then((d) => d.search.rows[d.search.selected]);`);
  const verifySelection = async (expected, what) => {
    const id = await run(`return active();`);
    if (expected !== `tab:${id}`) throw new Error(`selected ${id}, expected ${expected}`);
    await untilSnapshot(what, (state) => state.windows[0]?.selectedTabId === id);
    return id;
  };

  await rep.check("native-search-opens", async () => {
    const panel = await openSearch();
    if (panel.frame[1] !== 56 || panel.frame[2] !== 560 || panel.frame[3] <= 0) throw new Error(`frame ${panel.frame}`);
    if (panel.rows.filter((r) => r.startsWith("tab:")).length !== 5 || panel.selected !== 0 || panel.query !== "") throw new Error(JSON.stringify(panel));
    await press("escape");
    await searchClosed();
    return panel.frame;
  });

  await rep.check("native-search-type-enter", async () => {
    await openSearch();
    await run(`return type(${number}, "no").then(() => true);`);
    await sleep(300);
    const panel = (await run(`return native();`)).search;
    if (panel.query !== "no" || !panel.rows.length) throw new Error(JSON.stringify(panel));
    const expected = await selected();
    await press("enter");
    await searchClosed();
    return verifySelection(expected, "first search selection");
  });

  await rep.check("native-search-down-enter", async () => {
    await run(`ac.store.getState().activate("a"); return true;`);
    await sleep(200);
    await openSearch();
    await run(`return type(${number}, "no").then(() => true);`);
    await sleep(200);
    const first = await selected();
    await press("down");
    await sleep(100);
    const panel = (await run(`return native();`)).search;
    const expected = await selected();
    if (panel.selected !== 1 || expected === first) throw new Error(JSON.stringify(panel));
    await press("enter");
    await searchClosed();
    return verifySelection(expected, "second search selection");
  });

  await rep.check("native-search-row-click", async () => {
    const panel = await openSearch();
    const [x, y, w] = panel.frame;
    const expected = panel.rows[1];
    await run(`return click(${number}, [${Math.round(x + w / 2)}, ${Math.round(y + 50 + 1 + 6 + 21.5 + 36 + 18)}], 60).then(() => true);`);
    await searchClosed();
    return verifySelection(expected, "clicked search selection");
  });

  await rep.check("native-search-escape", async () => {
    const before = await run(`return active();`);
    const focused = (await run(`return native();`)).responder;
    await openSearch();
    await run(`return type(${number}, "re").then(() => true);`);
    await press("escape");
    await searchClosed();
    if ((await run(`return active();`)) !== before) throw new Error("Escape switched tabs");
    const after = (await run(`return native();`)).responder;
    if (after !== focused || after === "window") throw new Error(`focus went to ${after}, was on ${focused}`);
    return after;
  });

  await rep.check("native-search-click-away", async () => {
    const before = await run(`return active();`);
    const panel = await openSearch();
    const [x, y, w, h] = panel.frame;
    await run(`return click(${number}, [${Math.round(x + w / 2)}, ${Math.round(y + h + 120)}], 60).then(() => true);`);
    await searchClosed();
    if ((await run(`return active();`)) !== before) throw new Error("the click switched tabs");
    return true;
  });

  await rep.check("native-search-restores-closed", async () => {
    await run(`ac.store.getState().closeTab("e"); return true;`);
    await until("e closes", `return !ac.store.getState().tabs.e || null;`, 3000);
    const panel = await openSearch();
    if (!panel.rows.some((r) => r.startsWith("closed:"))) throw new Error(`no closed row in ${panel.rows}`);
    await run(`return type(${number}, "recipe").then(() => true);`);
    await sleep(200);
    const match = (await run(`return native();`)).search;
    if (!match.rows[0]?.startsWith("closed:")) throw new Error(`rows ${match.rows}`);
    await press("enter");
    await searchClosed();
    return until("Recipe Box comes back", `const s = ac.store.getState(); const t = Object.values(s.tabs).find((t) => t.url.endsWith("/e")); return t && s.windows.w1.activeTabIds.default === t.id ? t.id : null;`, 5000);
  });

  for (const [round, gap] of [80, 0, 0, 0, 0, 0, 0, 0, 0, 0].entries()) {
    await rep.check(`native-switcher-click-${round}-${gap}ms`, async () => {
      const early = await run(`ac.runCommand({ command: "tabSwitcher", windowId: "w1" }); return settle(60).then(() => !!(ui().switcher && ui().switcher.visible));`);
      if (early) throw new Error("visible before its delay");
      const s = await until("the switcher shows", `const s = ui().switcher; return s && s.visible ? s : null;`, 2000);
      const panel = await until("the native switcher", `return native().then((d) => d.switcher && d.switcher.ids.length ? d.switcher : null);`, 2000);
      const frame = panel.frame;
      if (JSON.stringify(panel.ids) !== JSON.stringify(s.ids) || panel.index !== s.index) throw new Error(`native ${JSON.stringify(panel)}, store ${JSON.stringify(s)}`);
      if (frame[2] !== 400 || frame[1] < 40 || frame[3] < s.ids.length * 40) throw new Error(`frame ${frame}`);
      const target = 2;
      const rowY = Math.round(frame[1] + frame[3] - 8 - s.ids.length * 40 + target * 40 + 20);
      await run(`return click(${number}, [${Math.round(frame[0] + frame[2] / 2)}, ${rowY}], ${gap}).then(() => true);`);
      await until("the switcher closes", `return !ui().switcher || null;`, 2000);
      await sleep(200);
      const now = await run(`return active();`);
      if (now !== s.ids[target]) throw new Error(`active ${now}, clicked ${s.ids[target]} in ${s.ids}`);
      await untilSnapshot("switcher selection", (state) => state.windows[0]?.selectedTabId === now);
      return { frame, ids: s.ids, picked: now };
    });
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
