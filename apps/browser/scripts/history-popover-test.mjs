import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node history-popover-test.mjs <Debug Solara.app> [--keep-data]

The back button's history popover on a tab that went ONE, TWO, THREE on local pages, under RN's shell (RN hosting
the native panel) and then the native one (SOLARA_NATIVE_SHELL=1: HistoryPanelView's PopoverView in the pane overlay
container on top of the shell's card, framed to the page area RN measures). The native card sits where the hosted
one is told to (300 wide, 8 from the page's top, the left RN works out from the back button's anchor), lists TWO and
ONE and fades in; a click on ONE through the window goes back two entries and closes it; reopened, a click on the
page outside the card closes it without navigating.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-history-popover-"));
const rep = reporter(join(scratch, "history-popover-test.log"), { name: "history-popover-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(req.url.slice(1)));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const menu = () => globalThis.acSwipe.history.menu.getState().menu;
const title = () => ac.store.getState().tabs.a.title;
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const native = () => M && M.describePaneOverlays ? M.describePaneOverlays("w1").then(JSON.parse) : Promise.resolve(null);
`;
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
const nativeFrame = (frame) => frame && [frame.x, frame.y, frame.width, frame.height];
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot().catch((e) => ({ error: e.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const seen = {};

try {
  for (const nativeShell of [false, true]) {
    const tag = nativeShell ? "native" : "rn";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { SOLARA_NATIVE_SHELL: nativeShell ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acSwipe?.history",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    await until("page ONE", `return title() === "ONE" || null;`, 15000);
    for (const page of ["two", "three"]) {
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(url(page))}, { userInitiated: true }); return true;`);
      await until(`page ${page}`, `return title() === ${JSON.stringify(page.toUpperCase())} || null;`, 15000);
    }
    await sleep(500);
    const openMenu = () => run(`return globalThis.acSwipe.history.open("a", -1).then(() => !!menu());`);

    await rep.check(`${tag}-opens`, async () => {
      if (!(await openMenu())) throw new Error("no back history");
      const area = await until("the popover's area", `const [f] = fibers("HistoryPopover"); return f ? measure(f) : null;`);
      if (!nativeShell) {
        const hosted = await until("the hosted panel", `const f = acPerf.findFibers("NativePanelView", 50).find((p) => p.memoizedProps.kind === "history"); return f ? JSON.parse(f.memoizedProps.state) : null;`);
        seen.rn = { area, popover: hosted.popover, titles: hosted.items.map((i) => i.title) };
        return seen.rn;
      }
      const d = await until("the native history popover", `return native().then((d) => d && d.tabs.a && d.tabs.a.history && d.tabs.a.history.opacity === 1 ? d : null);`, 3000);
      if (!d.top || !d.inCard) throw new Error(`the overlay container is not the card's top child: ${JSON.stringify(d)}`);
      const h = d.tabs.a.history;
      const rn = seen.rn;
      if (!near(area, rn.area) || !near(h.frame, rn.area)) throw new Error(`page area ${h.frame} (RN measures ${area}), RN's shell ${rn.area}`);
      const want = [rn.area[0] + rn.popover.left, rn.area[1] + rn.popover.top, rn.popover.width];
      if (!near(h.card.slice(0, 3), want) || !(h.card[3] > 0)) throw new Error(`card ${h.card}, the hosted panel is placed at ${want}`);
      for (const t of rn.titles) if (!h.controls[t]) throw new Error(`no row ${t} in ${Object.keys(h.controls)}`);
      const snapshot = await untilSnapshot("the native history", (state) => state.windows.some((w) => w.id === "w1" && w.overlays.some((o) => o.kind === "history" && o.tabId === "a" && o.opacity === 1)));
      const overlay = snapshot.windows.find((w) => w.id === "w1")?.overlays.find((o) => o.kind === "history" && o.tabId === "a");
      if (!overlay.visible || !near(nativeFrame(overlay.frame), h.card) || !near(nativeFrame(overlay.area), h.frame) ||
        rn.titles.some((title) => !overlay.controls.some((c) => c.id === title && near(nativeFrame(c.frame), h.controls[title]))))
        throw new Error(`native history ${JSON.stringify(overlay)} vs ${JSON.stringify(h)}`);
      if (snapshot.tabs.find((t) => t.id === "a")?.title !== "THREE") throw new Error(`native tab ${JSON.stringify(snapshot.tabs)}`);
      if ((await run(`return acPerf.findFibers("NativePanelView", 50).filter((p) => p.memoizedProps.kind === "history").length;`)) > 0) throw new Error("RN still hosts the history panel");
      seen.native = h;
      return { card: h.card, rows: rn.titles };
    });

    if (nativeShell) {
      await rep.check("native-row-click-navigates", async () => {
        await run(`return click(${number}, ${JSON.stringify(centre(seen.native.controls.ONE))}).then(() => true);`);
        await until("back to ONE", `return title() === "ONE" || null;`, 5000);
        await until("the popover closes", `return !menu() || null;`, 2000);
        await until("the native popover goes", `return native().then((d) => !d || !d.inCard || null);`, 2000);
        const snapshot = await untilSnapshot("native history landing", (state) => state.tabs.some((t) => t.id === "a" && t.title === "ONE" && t.url === url("one")) &&
          !state.windows.some((w) => w.overlays.some((o) => o.kind === "history" && o.tabId === "a" && o.visible)));
        if (snapshot.windows.find((w) => w.id === "w1")?.selectedTabId !== "a") throw new Error(`native active tab ${JSON.stringify(snapshot.windows)}`);
        return true;
      });
      await rep.check("native-click-away", async () => {
        await run(`ac.store.getState().navigate("a", ${JSON.stringify(url("four"))}, { userInitiated: true }); return true;`);
        await until("page FOUR", `return title() === "FOUR" || null;`, 15000);
        await sleep(300);
        if (!(await openMenu())) throw new Error("no back history");
        const d = await until("the native popover again", `return native().then((d) => d && d.tabs.a && d.tabs.a.history && d.tabs.a.history.opacity === 1 ? d : null);`, 3000);
        const reopened = await untilSnapshot("native history reopened", (state) => state.windows.some((w) => w.overlays.some((o) => o.kind === "history" && o.tabId === "a" && o.opacity === 1)));
        if (reopened.tabs.find((t) => t.id === "a")?.title !== "FOUR") throw new Error(`native tab ${JSON.stringify(reopened.tabs)}`);
        const [x, y, w, h] = d.tabs.a.history.frame;
        await run(`return click(${number}, [${Math.round(x + w * 0.75)}, ${Math.round(y + h * 0.75)}]).then(() => true);`);
        await until("the popover dismisses", `return !menu() || null;`, 3000);
        await sleep(400);
        if ((await run(`return title();`)) !== "FOUR") throw new Error("click-away navigated");
        await untilSnapshot("native history dismissed", (state) => state.tabs.some((t) => t.id === "a" && t.title === "FOUR" && t.url === url("four")) &&
          !state.windows.some((w) => w.overlays.some((o) => o.kind === "history" && o.tabId === "a" && o.visible)));
        return true;
      });
    }
    await app.quit();
    app = null;
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
