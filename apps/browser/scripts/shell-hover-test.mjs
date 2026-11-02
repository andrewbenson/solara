import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, screenLocked, screenLockedPending, session, sleep } from "../../../scripts/lib/instance.mjs";

let nativePollDeadline = null;
const evaluate = (body, options = {}) => {
  if (nativePollDeadline !== null && nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms left");
  return app.eval(body, { ...options, ...(nativePollDeadline === null ? {} : { timeout: 1000 }) });
};
const acceptSnapshot = async (deadline, accept, ...args) => {
  const previous = nativePollDeadline;
  nativePollDeadline = previous === null ? deadline : Math.min(previous, deadline);
  try {
    return await accept(...args);
  } finally {
    nativePollDeadline = previous;
  }
};

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node shell-hover-test.mjs <Debug Solara.app> [--keep-data]

Hover goes to what's on top in a native window shell (SOLARA_NATIVE_SHELL=1): the native sidebar's rows hover under the pointer; under a native view mounted in the shell's overlay slot
they don't; a row under a still pointer leaves when the native view arrives and enters again when it goes, and the same
when the native view is hidden and shown without leaving the overlay; with the native sidebar, a native view over the
peeking sidebar takes its hover too; finding the layer under
the pointer stays under 40 µs. With the RN main root on top (SOLARA_SHELL_MAIN_TOP=1) the exact lookup walks the RN
tree, so it stays under 120 µs and the shell runs it at most once a display frame: a 120 Hz pointer stream costs at most
one lookup per frame and 3% of a core on a 60 Hz display (the 120 Hz display estimate is only reported), and with or
without it the hover layer changes within a frame of the move. While the screen is locked the shell's display link
doesn't resolve the pointer, so the native rows' hover checks and the within-a-frame check are pending.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-shell-hover-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "shell-hover-test.log"), { name: "shell-hover-test" });
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }, { id: "c", url: "about:blank", title: "C" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});
const HELPERS = `
const S = globalThis.expo.modules.SolaraWindowShell;
const C = globalThis.expo.modules.SolaraCEF;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const at = (x, y) => ac.shell.devSetPointer("w1", { x, y }).then(() => win()).then((n) => C.devWindow(n, "mouse:moved:" + x + "," + y)).then(() => settle(250));
const H = globalThis.expo.modules.SolaraHosted;
const hover = () => (H?.sidebarShell ? H.sidebarShell("w1").then((d) => JSON.parse(d)?.hover ?? null) : Promise.resolve(null)).then((value) => { globalThis.__shellHoverValue = { value }; return value; });
`;
const ROWS = [90, 130, 170, 210];
const COVER = [0, 0, 320, 800];
let app = null;
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: app exited`);
    if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
    last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    if (Date.now() < end && !last.error && last.consistent && await acceptSnapshot(end, accept, last) && Date.now() < end) return last;
    await sleep(50);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const same = (a, b) => {
  try { assert.deepEqual(a, b); return true; } catch { return false; }
};
const run = async (body) => {
  const result = await evaluate(`${HELPERS}
    globalThis.__shellHoverValue = null;
    return Promise.resolve().then(() => { ${body} }).then((value) => ({ value, hover: globalThis.__shellHoverValue }));`, { timeout: 30000 });
  if (result.hover) await untilSnapshot("native sidebar hovered id", (snapshot) =>
    (snapshot.windows[0]?.sidebarShell?.hover ?? null) === result.hover.value);
  return result.value;
};
const entersAt = (y) => run(`return at(700, 400).then(() => at(120, ${y})).then(hover).then((k) => (k ? 1 : 0));`);
const cover = (rect, hidden) => `S.devCover("w1", ${JSON.stringify(rect)}, ${JSON.stringify(hidden)}).then(() => settle(250))`;

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell.devCover",
  });
  await sleep(2000);
  const column = await run(`return H?.sidebarShell ? H.sidebarShell("w1").then((d) => d !== "null") : false;`);
  assert.ok(column, "the native sidebar column is mounted");
  await untilSnapshot("native sidebar availability", async (snapshot) =>
    (snapshot.windows[0]?.sidebarShell != null) === await run(`return H?.sidebarShell ? H.sidebarShell("w1").then((d) => d !== "null") : false;`) && snapshot.windows[0]?.sidebarShell != null);
  const chromeWindowNumber = await run(`return win();`);
  await untilSnapshot("Chrome window number", async (snapshot) =>
    snapshot.windows[0]?.chromeWindowNumber === await run(`return win();`) && snapshot.windows[0]?.chromeWindowNumber === chromeWindowNumber);

  const locked = screenLocked();
  const hoverCheck = (name, fn) => locked ? rep.record(name, { skip: screenLockedPending }) : rep.check(name, fn);

  await hoverCheck("rows-hover", async () => {
    const enters = [];
    for (const y of ROWS) enters.push(await entersAt(y));
    if (enters.some((n) => n === 0)) throw new Error(`a row didn't hover: ${enters}`);
    return { enters };
  });

  await hoverCheck("covered-rows-dont-hover", async () => {
    if (!(await run(`return S.devCover("w1", ${JSON.stringify(COVER)}, null);`))) throw new Error("no shell host for w1");
    try {
      const enters = [];
      for (const y of ROWS) enters.push(await entersAt(y));
      if (enters.some((n) => n !== 0)) throw new Error(`rows under the native view hovered: ${enters}`);
      return enters;
    } finally {
      await run(`return S.devCover("w1", null, null);`);
    }
  });

  await hoverCheck("still-pointer-follows-the-cover", async () => {
    await run(`return at(700, 400);`);
    const parked = await run(`return at(120, 130).then(hover);`);
    const out = { parked, coverOn: await run(`return ${cover(COVER, null)}.then(hover);`), coverOff: await run(`return ${cover(null, null)}.then(hover);`) };
    if (!parked || out.coverOn !== null || out.coverOff !== parked) throw new Error(`hover didn't follow the cover: ${JSON.stringify(out)}`);
    return out;
  });

  await hoverCheck("a-hidden-cover-gives-hover-back", async () => {
    await run(`return at(700, 400);`);
    const parked = await run(`return at(120, 130).then(hover);`);
    const out = { parked, shown: await run(`return ${cover(COVER, null)}.then(hover);`), hidden: await run(`return ${cover(null, true)}.then(hover);`), again: await run(`return ${cover(null, false)}.then(hover);`) };
    await run(`return S.devCover("w1", null, null);`);
    if (!parked || out.shown !== null || out.hidden !== parked || out.again !== null) throw new Error(`hover didn't follow the cover's isHidden: ${JSON.stringify(out)}`);
    return out;
  });

  const PEEK = "a-cover-over-the-peeking-sidebar-takes-its-hover";
  await hoverCheck(PEEK, async () => {
    await run(`if (ac.store.getState().windows.w1.sidebarOpen) ac.store.getState().toggleSidebar("w1"); return settle(900);`);
    try {
      await run(`return ac.shell.devLeftEdgePointer("w1", { x: -4, y: 300 }).then(() => settle(500));`);
      const peeking = await run(`return ac.shell.devLeftEdgePointer("w1", { x: 120, y: 300 }).then(() => settle(500)).then(() => "w1" in globalThis.acLayout.dockMotion.getState().peeks);`);
      await untilSnapshot("peeking sidebar", (snapshot) => snapshot.windows[0]?.shellHover?.sidebarDockLive === peeking);
      const out = { peeking, parked: await run(`return at(120, 130).then(hover);`), covered: await run(`return ${cover(COVER, null)}.then(hover);`) };
      if (!peeking || !out.parked || out.covered !== null) throw new Error(`hover under the cover while peeking: ${JSON.stringify(out)}`);
      return out;
    } finally {
      await run(`return S.devCover("w1", null, null).then(() => ac.shell.devLeftEdgePointer("w1", null)).then(() => { if (!ac.store.getState().windows.w1.sidebarOpen) ac.store.getState().toggleSidebar("w1"); return settle(900); });`);
    }
  });

  await rep.check("layer-lookup-cost", async () => {
    const costs = [];
    for (const [x, y] of [[120, 130], [700, 400]]) {
      const cost = await run(`return S.devHitCost("w1", ${x}, ${y});`);
      await untilSnapshot("layer lookup timings and slot", (snapshot) => same(snapshot.windows[0]?.shellHover?.hitCost, cost));
      costs.push(cost);
    }
    const micros = costs.map((c) => Number(c.micros));
    const mainTop = process.env.SOLARA_SHELL_MAIN_TOP !== "0";
    if (micros.some((m) => !(m < (mainTop ? 120 : 40)))) throw new Error(`layer lookup ${micros} µs`);
    if (!mainTop) return micros;
    const points = Array.from({ length: 240 }, (_, i) => (i % 2 ? [700 + (i % 7), 400] : [120, 130 + (i % 5)]));
    const stream = await run(`return S.devPointerStream("w1", ${JSON.stringify(points)}, 120);`);
    await untilSnapshot("pointer stream counters and timings", (snapshot) => same(snapshot.windows[0]?.shellHover?.pointerStream, stream));
    const frames = stream.seconds / stream.frame;
    if (!(stream.lookups <= frames + 1) || !(stream.coreShare <= 0.03)) throw new Error(`pointer stream ${JSON.stringify(stream)} over ${frames.toFixed(0)} frames`);
    return { perCall: micros, stream, frames, coreShareAt120Hz: stream.coreShare * 120 * stream.frame };
  });

  await hoverCheck("hover-within-a-frame", async () => {
    const moves = [];
    await run(`return S.devPointerLatency("w1", -1, -1);`);
    for (const [x, y] of [[120, 130], [-1, -1], [700, 400], [-1, -1], [120, 130], [-1, -1]]) {
      const moved = await run(`return S.devPointerLatency("w1", ${x}, ${y});`);
      await untilSnapshot("hover latency and slot", (snapshot) => same(snapshot.windows[0]?.shellHover?.pointerLatency, moved));
      moves.push([x, y, moved]);
      if (!moved.changed || !(moved.ms <= moved.frameMs + 1)) throw new Error(`hover took ${JSON.stringify(moves)}`);
      await sleep(50);
    }
    return moves;
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const ran = rep.results.filter((r) => !r.skipped);
const failed = ran.filter((r) => !r.ok);
const pending = rep.results.length - ran.length;
console.log(`${ran.length - failed.length}/${ran.length} passed${pending ? `, ${pending} pending` : ""}${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
