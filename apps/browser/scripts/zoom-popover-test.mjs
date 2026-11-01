import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node zoom-popover-test.mjs <Debug Solara.app> [--keep-data]

The zoom popover over a local page, under RN's shell and then the native one (SOLARA_NATIVE_SHELL=1, where the
ZoomPanelView's PopoverView sits in the pane overlay container on top of the shell's card, framed to the page area
RN measures). Both open it with the page's popover state; the native card sits where RN's Popover puts it (236 wide,
8 from the page's right and top, the 48 pt bar plus its 0.5 border), fades in over PopoverMetrics.open, Zoom In
clicked through the window zooms the tab and keeps it open, and a click on the page outside the card dismisses it
without changing the zoom or the active tab.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-zoom-popover-"));
const rep = reporter(join(scratch, "zoom-popover-test.log"), { name: "zoom-popover-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>A</title><link rel="icon" href="data:,"><body>a</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://127.0.0.1:${server.address().port}/a`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: pageUrl, title: "A" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const popover = () => ac.pageState.getState().popover.a ?? null;
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
const areas = {};

try {
  for (const nativeShell of [false, true]) {
    const tag = nativeShell ? "native" : "rn";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { SOLARA_NATIVE_SHELL: nativeShell ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    await until("page A", `return ac.store.getState().tabs.a?.title === "A" || null;`, 15000);

    await rep.check(`${tag}-opens`, async () => {
      await run(`ac.pageState.setState((s) => ({ popover: { ...s.popover, a: "zoom" } })); return true;`);
      areas[tag] = await until("the popover's area", `const [f] = fibers("ZoomPopover"); return f ? measure(f) : null;`);
      if (!nativeShell) return { area: areas[tag] };
      const zoom = await until("the native zoom popover", `return native().then((d) => d && d.tabs.a && d.tabs.a.zoom && d.tabs.a.zoom.opacity === 1 ? d : null);`, 3000);
      if (!zoom.top || !zoom.inCard) throw new Error(`the overlay container is not the card's top child: ${JSON.stringify(zoom)}`);
      const z = zoom.tabs.a.zoom;
      const [x, y, w] = areas.native;
      const want = [x + w - 8 - 236, y + 8, 236, 49];
      if (!near(z.frame, areas.native)) throw new Error(`the popover's page area ${z.frame}, RN measures ${areas.native}`);
      if (!near(z.card, want)) throw new Error(`card ${z.card}, RN's Popover puts it at ${want}`);
      const snapshot = await untilSnapshot("the native zoom", (state) => state.windows.some((w) => w.id === "w1" && w.overlays.some((o) => o.kind === "zoom" && o.tabId === "a" && o.opacity === 1)));
      const overlay = snapshot.windows.find((w) => w.id === "w1")?.overlays.find((o) => o.kind === "zoom" && o.tabId === "a");
      if (!overlay.visible || !near(nativeFrame(overlay.frame), z.card) || !near(nativeFrame(overlay.area), z.frame) ||
        !overlay.controls.some((c) => c.id === "Zoom In (⌘+)" && near(nativeFrame(c.frame), z.controls[c.id])))
        throw new Error(`native zoom ${JSON.stringify(overlay)} vs ${JSON.stringify(z)}`);
      const hosted = await run(`return acPerf.findFibers("NativePanelView", 50).length;`);
      if (hosted) throw new Error("RN still hosts a NativePanelView for the zoom popover");
      return { card: z.card };
    });

    if (nativeShell) {
      await rep.check("native-zoom-in-keeps-it-open", async () => {
        const z = (await run(`return native();`)).tabs.a.zoom;
        await run(`return click(${number}, ${JSON.stringify(centre(z.controls["Zoom In (⌘+)"]))}).then(() => true);`);
        const zoom = await until("the tab zooms in", `const z = ac.store.getState().tabs.a.zoom; return z > 1 ? z : null;`, 3000);
        if ((await run(`return popover();`)) !== "zoom") throw new Error("Zoom In closed the popover");
        const snapshot = await untilSnapshot("native tab zoom", (state) => state.tabs.some((t) => t.id === "a" && t.zoom > 1) && state.windows.some((w) => w.overlays.some((o) => o.kind === "zoom" && o.tabId === "a" && o.visible)));
        if (snapshot.tabs.find((t) => t.id === "a")?.zoom !== zoom) throw new Error(`native zoom disagrees with JS: ${JSON.stringify(snapshot.tabs)}`);
        await until("the label follows", `return native().then((d) => d.tabs.a && d.tabs.a.zoom ? true : null);`, 2000);
        return { zoom };
      });

      await rep.check("native-click-away", async () => {
        const before = await run(`return ac.store.getState().tabs.a.zoom;`);
        const [x, y, w, h] = areas.native;
        await run(`return click(${number}, [${Math.round(x + w / 3)}, ${Math.round(y + h / 2)}]).then(() => true);`);
        await until("the popover dismisses", `return popover() === null || null;`, 3000);
        await until("the native popover goes", `return native().then((d) => !d || !d.inCard || null);`, 3000);
        const after = await run(`return { zoom: ac.store.getState().tabs.a.zoom, active: ac.store.getState().windows.w1.activeTabIds.default };`);
        if (after.zoom !== before || after.active !== "a") throw new Error(`click-away changed ${JSON.stringify(after)} (zoom was ${before})`);
        const snapshot = await untilSnapshot("native zoom dismissed", (state) => !state.windows.some((w) => w.overlays.some((o) => o.kind === "zoom" && o.tabId === "a" && o.visible)));
        if (snapshot.tabs.find((t) => t.id === "a")?.zoom !== after.zoom || snapshot.windows.find((w) => w.id === "w1")?.selectedTabId !== after.active)
          throw new Error(`native click-away state ${JSON.stringify(snapshot)}`);
        return after;
      });
    }
    await app.quit();
    app = null;
  }
  await rep.check("same-page-area", async () => {
    if (!near(areas.rn, areas.native)) throw new Error(`RN's area ${areas.rn}, the native shell's ${areas.native}`);
    return areas.rn;
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
