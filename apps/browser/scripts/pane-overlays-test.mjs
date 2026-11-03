import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node pane-overlays-test.mjs <Debug Solara.app> [--keep-data]

PaneOverlays, the per-pane overlay slots over the shell's card (SOLARA_NATIVE_SHELL=1, SOLARA_NATIVE_PAGES_POOL=1).
A two-pane split gives each pane a visible slot over its page area, below its pane toolbar, matching
SplitPanesView's page frame. A fullscreen page in the split covers the other pane in SplitPanesView, which stays shown
underneath so its page keeps running, and hides its slot, while the fullscreen pane's slot fills the card; leaving
fullscreen uncovers both. Separating the split leaves one slot for the active tab. Fullscreen is set through the page
state, not the Fullscreen API, so the hidden instance never takes a Space.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-pane-overlays-"));
const rep = reporter(join(scratch, "pane-overlays-test.log"), { name: "pane-overlays-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(req.url.slice(1)));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const shell = () => globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);
const split = () => shell().then((d) => (d && d.split) || {});
const setFullscreen = (id, on) => acLayout.pages.setState((s) => ({ pages: { ...s.pages, [id]: { ...s.pages[id], fullscreen: on } } }));
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
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const splitFrom = (state) => state.windows.find((window) => window.id === "w1")?.split;
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const shown = (s, id) => s.overlays && s.overlays[id] && !s.overlays[id].hidden;
const hidden = (s, id) => !s.overlays || !s.overlays[id] || s.overlays[id].hidden;

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acLayout && !!globalThis.expo.modules.SolaraWindowShell",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);
  await run(`S().createSplit(["a", "b"]); S().activate("a"); return true;`);

  await rep.check("split-slots-over-page-areas", async () => {
    const s = await until("two shown slots", `return split().then((s) => (s.overlays && s.overlays.a && s.overlays.b && !s.overlays.a.hidden && !s.overlays.b.hidden && s.leaves && s.leaves.a && s.leaves.b) ? s : null);`);
    for (const id of ["a", "b"]) if (!near(s.overlays[id].window, s.leaves[id].window)) throw new Error(`${id}: slot ${s.overlays[id].window}, page ${s.leaves[id].window}`);
    const native = splitFrom(await untilSnapshot("two native slots", (state) => ["a", "b"].every((id) => splitFrom(state)?.overlays?.[id] && splitFrom(state)?.leaves?.[id])));
    for (const id of ["a", "b"]) {
      if (native.overlays[id].hidden || !near(native.overlays[id].window, s.overlays[id].window) || !near(native.leaves[id].window, s.leaves[id].window))
        throw new Error(`${id}: native slot ${JSON.stringify(native.overlays[id])}, JS ${JSON.stringify(s.overlays[id])}`);
    }
    return { a: s.overlays.a.window, b: s.overlays.b.window };
  });

  let full;
  await rep.check("fullscreen-hides-the-other-slot", async () => {
    await run(`setFullscreen("b", true); return true;`);
    full = await until("b fullscreen", `return split().then((s) => (s.leaves && s.leaves.a && s.leaves.a.covered && !s.leaves.a.hidden && !s.leaves.b.covered && !s.leaves.b.hidden) ? s : null);`);
    if (!hidden(full, "a")) throw new Error(`a's slot shows while its pane is hidden: ${JSON.stringify(full.overlays)}`);
    if (!shown(full, "b")) throw new Error(`b's slot is hidden: ${JSON.stringify(full.overlays)}`);
    const card = await run(`return shell().then((d) => d.card);`);
    const [, , cw, ch] = card;
    const [, , bw, bh] = full.overlays.b.window;
    if (Math.abs(bw - cw) > 0.5 || Math.abs(bh - ch) > 0.5) throw new Error(`fullscreen slot ${full.overlays.b.window}, card ${card}`);
    const native = splitFrom(await untilSnapshot("native fullscreen slot", (state) => splitFrom(state)?.overlays?.a?.hidden && !splitFrom(state)?.overlays?.b?.hidden));
    if (!native.leaves.a.covered || native.leaves.a.hidden || native.leaves.b.covered || native.leaves.b.hidden ||
      !near(native.overlays.b.window, full.overlays.b.window)) throw new Error(`native fullscreen ${JSON.stringify(native)}`);
    return { a: full.overlays.a, b: full.overlays.b.window };
  });

  await rep.check("leaving-fullscreen-shows-both", async () => {
    await run(`setFullscreen("b", false); return true;`);
    const s = await until("both shown", `return split().then((s) => (s.leaves && !s.leaves.a.hidden && !s.leaves.b.hidden && !s.leaves.a.covered && !s.leaves.b.covered) ? s : null);`);
    for (const id of ["a", "b"]) if (!shown(s, id)) throw new Error(`${id}'s slot is hidden: ${JSON.stringify(s.overlays)}`);
    for (const id of ["a", "b"]) if (!near(s.overlays[id].window, s.leaves[id].window)) throw new Error(`${id}: slot ${s.overlays[id].window}, page ${s.leaves[id].window}`);
    const native = splitFrom(await untilSnapshot("native split restored", (state) => ["a", "b"].every((id) => splitFrom(state)?.overlays?.[id] && !splitFrom(state).overlays[id].hidden)));
    for (const id of ["a", "b"]) if (!near(native.overlays[id].window, s.overlays[id].window) || !near(native.leaves[id].window, s.leaves[id].window))
      throw new Error(`${id}: native slot ${JSON.stringify(native.overlays[id])}, JS ${JSON.stringify(s.overlays[id])}`);
    return true;
  });

  await rep.check("separated-leaves-one-slot", async () => {
    await run(`for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("a"); return true;`);
    const s = await until("one slot", `return split().then((s) => (s.overlays && s.overlays.a && !s.overlays.a.hidden && (!s.overlays.b || s.overlays.b.hidden)) ? s : null);`);
    const native = splitFrom(await untilSnapshot("one native slot", (state) => splitFrom(state)?.overlays?.a && !splitFrom(state).overlays.a.hidden && !splitFrom(state).overlays.b));
    if (!near(native.overlays.a.window, s.overlays.a.window)) throw new Error(`native slot ${JSON.stringify(native.overlays.a)}, JS ${JSON.stringify(s.overlays.a)}`);
    return Object.keys(s.overlays);
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
