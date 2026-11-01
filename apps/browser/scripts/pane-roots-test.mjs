import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node pane-roots-test.mjs <Debug Solara.app> [--keep-data]

Per-tab RN pane roots in the PaneOverlays .rn slots (SOLARA_NATIVE_SHELL=1, SOLARA_NATIVE_PAGES_POOL=1,
SOLARA_SHELL_PANES=1). The active tab gets one root, shown once its content appears and sized to its slot; switching tabs shows the new
tab's root and retires the old one, which ends after the 1 s grace; a split gives each pane a root; a fullscreen pane
retires the other pane's root and leaving fullscreen brings one back; closing a tab ends its root at once, without the
grace. A tab whose pane root can't be made (forced here through devRefusePaneRoot) keeps its overlays in the main root,
and moves them to a pane root once one can be made. A tab moved to a new window with its find bar
open and the toolbar hidden while scrolling has exactly one find bar, from its new pane root, even with the old
window's pane root torn down 2 s late (devLatePaneTeardown), and its status bubble follows the toolbar's slide there.
A retiring root is told it's hidden, so its tab never counts as drawn by it. The JS side counts mounted pane roots, so an ended root is unmounted, not just removed from its slot; the find
bar renders under the pane root and not under the main root's ContentCard.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-pane-roots-"));
const rep = reporter(join(scratch, "pane-roots-test.log"), { name: "pane-roots-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url.slice(1).toUpperCase()}</title><link rel="icon" href="data:,"><body>${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }, { id: "c", url: url("three"), title: "THREE" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const roots = () => globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse).then((d) => ({ native: (d && d.paneRoots) || {}, mounted: globalThis.acPaneRoots ? globalThis.acPaneRoots.count : -1 }));
const setFullscreen = (id, on) => acLayout.pages.setState((s) => ({ pages: { ...s.pages, [id]: { ...s.pages[id], fullscreen: on } } }));
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
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
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error && !last.waiting) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const shownOnly = (ids) => `return roots().then((r) => {
  const want = ${JSON.stringify(ids)};
  const keys = Object.keys(r.native).sort();
  const ok = keys.join() === want.slice().sort().join() && want.every((id) => !r.native[id].hidden && r.native[id].inSlot && !r.native[id].retiring && r.native[id].content.join() === r.native[id].size.join()) && r.mounted === want.length;
  return ok ? r : { waiting: true, r };
});`;

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acLayout && !!globalThis.expo.modules.SolaraWindowShell",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);

  await rep.check("one-root-for-the-active-tab", async () => until("a's root", shownOnly(["a"]), 15000));

  await rep.check("the-pane-root-draws-the-page-overlays", async () => {
    await run(`S().setFind("a", { open: true, query: "one" }); return true;`);
    try {
      return await until("find bar in the pane root", `
        const owners = (f) => { const out = []; for (let c = f.return; c; c = c.return) { const n = acPerf.nameOf(c.type); if (n === "PaneRoot" || n === "ContentCard") out.push(n); } return out; };
        const bars = acPerf.findFibers("FindBarPanel", 20).map(owners);
        const seen = ["PaneRoot", "PaneContent", "PageOverlays", "FindBar"].map((n) => [n, acPerf.findFibers(n, 20).length]);
        return bars.length === 1 && bars[0][0] === "PaneRoot" && !bars[0].includes("ContentCard") ? bars : roots().then((r) => ({ waiting: true, bars, seen, roots: r }));`);
    } finally {
      await run(`S().setFind("a", { open: false, query: "" }); return true;`);
    }
  });

  await rep.check("switching-retires-the-old-root-after-the-grace", async () => {
    await run(`S().activate("b"); return true;`);
    const mid = await until("b shown, a retiring", `return roots().then((r) => (r.native.b && !r.native.b.hidden && r.native.a && r.native.a.retiring && r.native.a.hidden) ? r : { waiting: true, r });`);
    const retiringShown = await until("a's pane told it's hidden", `const f = acPerf.findFibers("PaneContent", 20).find((f) => f.memoizedProps.tabId === "a"); return f ? (f.memoizedProps.shown === false ? "hidden" : { waiting: true }) : null;`, 900);
    const after = await until("only b", shownOnly(["b"]), 4000);
    const native = await untilSnapshot("b selected in native store", (state) => state.windows.some((w) => w.id === "w1" && w.selectedTabId === "b"));
    if (native.windows[0].selectedTabId !== "b") throw new Error(`native selected tab ${native.windows[0].selectedTabId}`);
    return { mid, retiringShown, after };
  });

  await rep.check("a-split-gives-each-pane-a-root", async () => {
    await run(`S().createSplit(["a", "b"]); S().activate("a"); return true;`);
    const roots = await until("a and b", shownOnly(["a", "b"]));
    const native = await untilSnapshot("native split slots", (state) => ["a", "b"].every((id) => state.windows[0]?.split?.overlays?.[id] && !state.windows[0].split.overlays[id].hidden));
    for (const id of ["a", "b"]) {
      const frame = native.windows[0].split.overlays[id].window;
      if (Math.abs(frame[2] - roots.native[id].size[0]) > 0.5 || Math.abs(frame[3] - roots.native[id].size[1]) > 0.5) throw new Error(`${id}: native slot ${frame}, pane root ${roots.native[id].size}`);
    }
    return roots;
  });

  await rep.check("fullscreen-retires-the-other-panes-root", async () => {
    await run(`setFullscreen("b", true); return true;`);
    const mid = await until("a retiring", `return roots().then((r) => (r.native.a && r.native.a.retiring && r.native.a.hidden && r.native.b && !r.native.b.hidden) ? r : { waiting: true, r });`);
    const after = await until("only b", shownOnly(["b"]), 4000);
    return { mid, after };
  });

  await rep.check("leaving-fullscreen-brings-it-back", async () => {
    await run(`setFullscreen("b", false); return true;`);
    return until("a and b again", shownOnly(["a", "b"]));
  });

  await rep.check("closing-a-tab-ends-its-root-at-once", async () => {
    const t0 = Date.now();
    await run(`S().closeTab("b"); return true;`);
    const r = await until("b ended", `return roots().then((r) => (!r.native.b && r.mounted === Object.keys(r.native).length) ? r : { waiting: true, r });`, 900);
    await untilSnapshot("b removed from native store", (state) => !state.tabs.some((tab) => tab.id === "b") && !state.windows[0]?.tabIds.includes("b"));
    return { ms: Date.now() - t0, r };
  });

  await rep.check("a-tab-without-a-pane-root-keeps-its-overlays", async () => {
    const owner = (tabId, want) => `
      const owners = (f) => { const out = []; for (let c = f.return; c; c = c.return) { const n = acPerf.nameOf(c.type); if (n === "PaneRoot" || n === "ContentCard") out.push(n); } return out; };
      const bars = acPerf.findFibers("FindBarPanel", 20).filter((f) => f.memoizedProps.tabId === ${JSON.stringify(tabId)}).map(owners);
      return bars.length === 1 && bars[0][0] === ${JSON.stringify(want)} ? bars[0][0] : { waiting: true, bars };`;
    await run(`return globalThis.expo.modules.SolaraWindowShell.devRefusePaneRoot("c", true);`);
    try {
      await run(`S().activate("c"); S().setFind("c", { open: true, query: "three" }); return true;`);
      const refused = await until("c's find bar from the main root", owner("c", "ContentCard"));
      const native = await run(`return roots().then((r) => r.native);`);
      if (native.c) throw new Error(`refused root: drawn by ${refused}, native ${JSON.stringify(native)}`);
      await run(`return globalThis.expo.modules.SolaraWindowShell.devRefusePaneRoot("c", false);`);
      await run(`S().activate("a"); return true;`);
      await sleep(200);
      await run(`S().activate("c"); return true;`);
      const allowed = await until("c's find bar from its pane root", owner("c", "PaneRoot"));
      return { refused, allowed };
    } finally {
      await run(`S().setFind("c", { open: false, query: "" }); return globalThis.expo.modules.SolaraWindowShell.devRefusePaneRoot("c", false);`);
    }
  });

  await rep.check("a-tab-moved-to-another-window-keeps-one-find-bar-and-its-status-slide", async () => {
    const bars = `return acPerf.findFibers("FindBarPanel", 20).filter((f) => f.memoizedProps.tabId === "c").map((f) => { for (let c = f.return; c; c = c.return) { const n = acPerf.nameOf(c.type); if (n === "PaneRoot" || n === "ContentCard") return n; } return "?"; });`;
    await run(`S().updateSettings({ hideToolbarWhileScrolling: true }); S().activate("c"); S().setFind("c", { open: true, query: "three" }); return true;`);
    await until("c's find bar", `${bars.replace("return ", "const b = ")} return b.length === 1 ? b : null;`);
    await run(`return globalThis.expo.modules.SolaraWindowShell.devLatePaneTeardown(2);`);
    let to;
    const counts = [];
    try {
      to = await run(`return S().moveTabsToWindow(["c"], null) ?? null;`);
      if (!to) throw new Error("no new window");
      for (const at = Date.now(); Date.now() - at < 3200; await sleep(150)) counts.push(await run(bars));
    } finally {
      await run(`return globalThis.expo.modules.SolaraWindowShell.devLatePaneTeardown(0);`);
    }
    const settled = counts.slice(-6);
    if (settled.some((b) => b.length !== 1 || b[0] !== "PaneRoot")) throw new Error(`c's find bars after the move, old teardown last: ${JSON.stringify(counts)}`);
    if (counts.some((b) => b.length > 1)) throw new Error(`a duplicate find bar after the move: ${JSON.stringify(counts)}`);
    await run(`S().setFind("c", { open: false, query: "" }); return true;`);
    await until("c's pane root in the new window", `
      const f = acPerf.findFibers("PaneContent", 20).find((f) => f.memoizedProps.tabId === "c" && f.memoizedProps.windowId === ${JSON.stringify(to)});
      return f || null ? true : null;`, 15000);
    await sleep(800);
    await run(`acLayout.pages.setState((s) => ({ pages: { ...s.pages, c: { ...(s.pages.c || {}), status: "https://example.com/c" } } })); ac.toolbarAutoHide.noteScroll("c", { state: "down" }); return true;`);
    await sleep(1200);
    const shifts = await run(`
      const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
      const shift = () => {
        const f = acPerf.findFibers("PageOverlays", 50).find((f) => f.memoizedProps.tabId === "c" && !f.memoizedProps.peek);
        let inPane = false;
        for (let c = f && f.return; c; c = c.return) if (acPerf.nameOf(c.type) === "PaneRoot") inPane = true;
        const t = f && f.memoizedProps.statusStyle && f.memoizedProps.statusStyle.transform && f.memoizedProps.statusStyle.transform[0].translateY;
        return !inPane ? "not-in-pane" : t === undefined || t === null ? null : typeof t === "number" ? t : t.__getValue();
      };
      const out = [];
      ac.toolbarAutoHide.noteScroll("c", { state: "up" });
      const sample = (n) => n ? frame().then(() => { out.push(shift()); return sample(n - 1); }) : Promise.resolve(out);
      return sample(40);`);
    await run(`S().updateSettings({ hideToolbarWhileScrolling: false }); return true;`);
    const moved = shifts.filter((x) => typeof x === "number" && Math.abs(x) > 0.5);
    if (!moved.length) throw new Error(`the status bubble didn't slide in the new window: ${JSON.stringify(shifts)}`);
    return { window: to, frames: moved.length, extent: Math.max(...moved.map(Math.abs)), bars: counts.map((b) => b.length).join("") };
  });
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
