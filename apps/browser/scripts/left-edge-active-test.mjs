import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launch, reporter, session } from "../../../scripts/lib/instance.mjs";

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
const fixture = session({
  windows: [{ id: "w1", frame: [0, 80, 1280, 800], activeTabIds: { default: "a" }, sidebarOpen: false }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});
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
  await run(`const s = ac.store.getState(); if (s.windows.w1.sidebarOpen) s.toggleSidebar("w1"); return settle(900);`);

  await rep.check("with another app in front, the pointer at the window's left edge doesn't peek", async () => {
    await run(`return ac.shell.devLeftEdgePointer("w1", null).then(() => active(false));`);
    const out = await run(`return pointer({ x: 3, y: 300 });`);
    if (out) throw new Error("the sidebar peeked out while Solara wasn't the active app");
    return { peeking: out };
  });

  await rep.check("with another app in front, the pointer just beside the window doesn't peek", async () => {
    const out = await run(`return pointer({ x: -6, y: 300 });`);
    if (out) throw new Error("the sidebar peeked out from beside the window while Solara wasn't the active app");
    return { peeking: out };
  });

  await rep.check("once Solara is active, the pointer at the edge peeks", async () => {
    const out = await run(`return pointer({ x: 3, y: 300 }).then(() => active(true));`);
    if (!out) throw new Error("no peek with Solara active and the pointer at the edge");
    return { peeking: out };
  });

  await rep.check("a peek that is out slides away when another app comes to the front", async () => {
    const out = await run(`return pointer({ x: 120, y: 300 }).then((held) => active(false).then((after) => ({ held, after })));`);
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
