import { mkdtempSync, rmSync } from "node:fs";
import { sidebarSession, sidebarEdgeX, assertSidebarPosition, assertSidebarPeekCoverage } from "./sidebar-position-test.mjs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node left-edge-active-test.mjs <Debug Solara.app> [--keep-data]

The hidden sidebar peeks out from the window's left edge only while Solara is the active app. With another app in front
(the dev activity override off), the pointer at the window's left edge or just beside it peeks nothing, a peek that is out
slides away when Solara stops being active, the pointer at the edge peeks again once Solara is active, and with Solara
in the background the left-edge watcher has no system-wide pointer monitor even with the window at the screen's left
edge. The pointer is the dev pointer (devLeftEdgePointer); a hidden instance is never really active.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-left-edge-active-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "left-edge-active-test.log"), { name: "left-edge-active-test" });
const fixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [0, 80, 1280, 800], activeTabIds: { default: "a" }, sidebarOpen: false }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
}));
const HELPERS = `
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const peeking = () => "w1" in (globalThis.acLayout?.dockMotion.getState().peeks ?? {});
const pointer = (p) => ac.shell.devLeftEdgePointer("w1", p).then(() => settle(600)).then(peeking);
const active = (on) => (ac.shell.devLeftEdgeAppActive ? ac.shell.devLeftEdgeAppActive(on) : Promise.resolve(false)).then(() => settle(600)).then(peeking);
`;
let app = null;
const run = (body) => app.eval(HELPERS + body, { timeout: 8000 });
try {
  app = await launch(appArg, { data, session: fixture, ready: "return !!ac.shell.devLeftEdgePointer" });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  await assertSidebarPosition(app);
  const windowWidth = await run(`return ac.store.getState().windows.w1.frame[2];`);
  await run(`const s = ac.store.getState(); if (s.windows.w1.sidebarOpen) s.toggleSidebar("w1"); return settle(900);`);
  const initialWatch = await run(`return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse).then((shell) => globalThis.expo.modules.SolaraApp.devLeftEdgeStats(false).then((stats) => ({ dock: shell.sidebarDock, stats })));`);
  rep.log(`initial native edge watch: ${JSON.stringify(initialWatch)}`);

  await rep.check("with another app in front, the pointer at the window's left edge doesn't peek", async () => {
    await run(`return ac.shell.devLeftEdgePointer("w1", null).then(() => active(false));`);
    const out = await run(`return pointer({ x: ${sidebarEdgeX(windowWidth, 3)}, y: 300 });`);
    if (out) throw new Error("the sidebar peeked out while Solara wasn't the active app");
    return { peeking: out };
  });

  await rep.check("with another app in front, the pointer just beside the window doesn't peek", async () => {
    const out = await run(`return pointer({ x: ${sidebarEdgeX(windowWidth, -6)}, y: 300 });`);
    if (out) throw new Error("the sidebar peeked out from beside the window while Solara wasn't the active app");
    return { peeking: out };
  });

  await rep.check("once Solara is active, the pointer at the edge peeks", async () => {
    const out = await run(`return pointer({ x: ${sidebarEdgeX(windowWidth, 3)}, y: 300 }).then(() => active(true));`);
    if (!out) throw new Error("no peek with Solara active and the pointer at the edge");
    await assertSidebarPeekCoverage(app, "w1", [sidebarEdgeX(windowWidth, 30), 300]);
    return { peeking: out };
  });

  await rep.check("a peek that is out slides away when another app comes to the front", async () => {
    const out = await run(`return pointer({ x: ${sidebarEdgeX(windowWidth, 120)}, y: 300 }).then((held) => active(false).then((after) => ({ held, after })));`);
    if (!out.held || out.after) throw new Error(`peek held ${out.held}, after Solara stopped being active ${out.after}`);
    return out;
  });

  await rep.check("in the background, the watcher has no system-wide pointer monitor, even at the screen's left edge", async () => {
    const out = await run(`return ac.shell.devLeftEdgePointer("w1", null).then(() => active(false)).then(() => globalThis.expo.modules.SolaraApp.devLeftEdgeStats(true))
      .then((stats) => ({ global: stats.global, watched: stats.watched, frame: ac.store.getState().windows.w1.frame }));`);
    if (out.watched !== 1) throw new Error(`the left edge isn't watched: ${JSON.stringify(out)}`);
    if (out.global) throw new Error(`a system-wide pointer monitor runs with Solara in the background: ${JSON.stringify(out)}`);
    return out;
  });
  await rep.check("closing an initially hidden window removes its edge watch while another window stays open", async () => {
    const before = await run(`return globalThis.expo.modules.SolaraApp.devLeftEdgeStats(false);`);
    if (before.watched !== 1) throw new Error(`the initial hidden window has no registered watch: ${JSON.stringify(before)}`);
    const other = await run(`const id = ac.store.getState().createWindow({ frame: [160, 120, 1000, 700] }); return settle(500).then(() => id);`);
    await run(`ac.store.getState().closeWindow("w1"); return true;`);
    const deadline = Date.now() + 5000;
    let last;
    while (deadline - Date.now() >= 1000) {
      if (!app.alive) throw new Error("the owned instance exited during edge-watch teardown");
      const state = await app.snapshot({}, { timeout: 1000 });
      last = await app.eval(`return globalThis.expo.modules.SolaraApp.devLeftEdgeStats(false).then((stats) => ({ stats, closed: !ac.store.getState().windows.w1, live: !!ac.store.getState().windows[${JSON.stringify(other)}] }));`, { timeout: 1000 });
      if (state.consistent && !state.windows.some((window) => window.id === "w1") && state.windows.some((window) => window.id === other) && last.closed && last.live && last.stats.watched === 0 && !last.stats.global) return last;
      await sleep(100);
    }
    throw new Error(`the closed window retained an edge watch: ${JSON.stringify(last)}`);
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.eval(HELPERS + `return active(null).then(() => ac.shell.devLeftEdgePointer("w1", null));`, { timeout: 4000 }).catch(() => {});
  await app?.quit().catch(() => {});
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
