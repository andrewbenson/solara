import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { placementPage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node pane-roots-placement-test.mjs <Debug Solara.app> [--keep-data]

The page overlays land in the same place whether the main root draws them or the per-tab pane roots do. Two hidden
instances under the native shell (SOLARA_NATIVE_SHELL=1 SOLARA_NATIVE_PAGES_POOL=1), SOLARA_SHELL_PANES=0 and then =1,
each in turn: a two-pane split with the find bar, a link's status and the CLI pill up on the left pane; the same
after the split is resized; one pane with the toolbar hidden while scrolling, scrolled down and then up (as the page reports it), where the status
bubble's offset follows the toolbar's slide frame by frame as far with pane roots as without; and the dock peek (RN's, or the native dock's shown from the window's left edge when the native sidebar column is on) over a closed sidebar with the address bar in the sidebar, sampled
every frame while it slides in, where Site Controls must be drawn exactly once on every frame (beside the peek once
the card has measured, in the pane until then). The find bar and CLI pill frames match within half a point, and
the window snapshots (2x) of each state match pixel for pixel. In a split the find bar's box and the bottom row of the
left pane (status bubble, CLI pill) are left out of the pixel match: without pane roots the shell draws the main root's
overlays under the native split pane, dimmed, which pane roots fix; their frames still have to match.

Both legs pin the page pool off (SOLARA_TAB_POOL=0), so they compare RN's pages; a leg the pool still serves fails.
A third instance, pane roots on and the pool on, takes the split and resized-split snapshots with the pool's page
views, and pooled-same-split(-resized) require them to match the pane-roots leg pixel for pixel: both panes' pages
placed and painted without a relayout. On a build whose SolaraTabPool doesn't serve pages they are pending (SKIP).`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pane-roots-placement-"));
const rep = reporter(join(scratch, "pane-roots-placement-test.log"), { name: "pane-roots-placement-test" });

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= channels ? data[y * stride + x - channels] : 0;
      const b = y ? data[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? data[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      data[y * stride + x] = (v + pred) & 255;
    }
  }
  return { width, height, channels, data };
}

function pixelDiff(pathA, pathB, skips = []) {
  const A = readPng(pathA), B = readPng(pathB);
  if (A.width !== B.width || A.height !== B.height) return { size: [A.width, A.height, B.width, B.height] };
  let max = 0, over = 0, x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1;
  for (let y = 0; y < A.height; y++)
    for (let x = 0; x < A.width; x++) {
      if (skips.some((r) => x >= r[0] * 2 && x < (r[0] + r[2]) * 2 && y >= r[1] * 2 && y < (r[1] + r[3]) * 2)) continue;
      const i = (y * A.width + x) * A.channels, j = (y * B.width + x) * B.channels;
      let d = 0;
      for (let k = 0; k < 3; k++) d = Math.max(d, Math.abs(A.data[i + k] - B.data[j + k]));
      max = Math.max(max, d);
      if (d > 8) {
        over++;
        x0 = Math.min(x0, x), y0 = Math.min(y0, y), x1 = Math.max(x1, x), y1 = Math.max(y1, y);
      }
    }
  return { max, over, box: over ? [x0 / 2, y0 / 2, (x1 - x0 + 1) / 2, (y1 - y0 + 1) / 2] : null };
}

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(placementPage(req.url.slice(1)));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/pa`, title: "PA" }, { id: "b", url: `${base}/pb`, title: "PB" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const first = (name) => { const f = acPerf.findFibers(name, 50).find((f) => !!f.child); return f ? measure(f) : Promise.resolve(null); };
const patchA = (p) => acLayout.pages.setState((s) => ({ pages: { ...s.pages, a: { ...(s.pages.a || {}), ...p } } }));
const openControls = () => acPerf.findFibers("SiteControls", 50).filter((f) => f.memoizedProps && f.memoizedProps.open).length;
const shot = (p) => ac.shell.devSnapshotWindow("w1", p);
const pillFrame = () => globalThis.expo.modules.SolaraMedia.probe("media.cliPill", "w1").then(JSON.parse).then((rows) => rows.find((row) => row.opacity > 0.99)?.frame ?? null);
const statusShift = () => {
  const f = acPerf.findFibers("PageOverlays", 50).find((f) => f.memoizedProps && f.memoizedProps.tabId === "a" && !f.memoizedProps.peek);
  const t = f && f.memoizedProps.statusStyle && f.memoizedProps.statusStyle.transform && f.memoizedProps.statusStyle.transform[0].translateY;
  return t === undefined || t === null ? null : typeof t === "number" ? t : t.__getValue();
};
`;

const STATES = ["split", "split-resized", "auto-hide"];
const LEGS = [
  { key: "0", panes: "0", pool: "0" },
  { key: "1", panes: "1", pool: "0" },
  { key: "pool", panes: "1", pool: "1" },
];
const got = { 0: {}, 1: {}, pool: {} };
let poolServing = false;
let app = null;
const run = (body, timeout = 30000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(120);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const untilSnapshot = async (what, accept, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  do {
    last = await app.snapshot({ windowId: "w1" });
    assert.equal(last.schema, 1);
    if (last.consistent && accept(last)) return last;
    await sleep(80);
  } while (Date.now() < end);
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);

try {
  for (const { key: panes, panes: shellPanes, pool } of LEGS) {
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${panes}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_TAB_POOL: pool, SOLARA_SHELL_PANES: shellPanes },
      ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acLayout && !!globalThis.acCli",
    });
    const g = got[panes];
    const serving = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.();`);
    const initialSnapshot = await untilSnapshot("page pool capability", (s) => typeof s.poolAvailable === "boolean");
    assert.equal(initialSnapshot.poolAvailable, serving, "native/JS page pool availability");
    if (pool === "1") poolServing = serving;
    else if (serving) throw new Error(`leg ${panes}: SolaraTabPool serves pages with SOLARA_TAB_POOL=0, so this leg can't test RN's pages`);
    const snap = async (state) => {
      const path = join(scratch, `${panes}-${state}.png`);
      if (!(await run(`return shot(${JSON.stringify(path)});`))) throw new Error(`no snapshot for ${state}`);
      const native = await app.probe("view.capture", { windowId: "w1" });
      assert.match(native.artifact, /^\.solara-probe-window-[0-9a-f-]{36}\.png$/);
      const nativePath = join(app.data, native.artifact);
      const image = readPng(nativePath);
      assert.equal(image.width, native.width);
      assert.equal(image.height, native.height);
      const snapshot = await untilSnapshot("capture geometry", (s) => !!s.windows[0]?.contentFrame);
      assert.equal(native.scale, snapshot.coordinateSpace.displayScale);
      assert.ok(Math.abs(image.width / native.scale - snapshot.windows[0].contentFrame.width) <= 0.5);
      assert.ok(Math.abs(image.height / native.scale - snapshot.windows[0].contentFrame.height) <= 0.5);
      const pixels = pixelDiff(path, nativePath);
      assert.ok(pixels.max <= 8, `native/JS capture ${state}: ${JSON.stringify(pixels)}`);
      g[state] = { ...g[state], shot: path, nativeShot: nativePath };
    };
    await until("pages", `return S().tabs.a.title === "PA" && S().tabs.b.title === "PB" || null;`, 20000);

    await rep.check(`${panes}-split-overlays`, async () => {
      await run(`S().createSplit(["a", "b"]); S().activate("a"); S().setFind("a", { open: true, query: "selectable" }); patchA({ status: "https://example.com/a-link" }); acCli.indicator.setState({ shown: true }); return true;`);
      await sleep(1200);
      g.split = { find: await until("find bar", `return first("FindBarPanel");`), pill: await until("native CLI pill", `return pillFrame();`) };
      await snap("split");
      const id = await run(`return Object.keys(S().splits)[0];`);
      await run(`S().updateSplit(${JSON.stringify(id)}, { sizes: [0.35, 0.65] }); return true;`);
      await sleep(1000);
      g["split-resized"] = { find: await run(`return first("FindBarPanel");`), pill: await until("native CLI pill", `return pillFrame();`) };
      await snap("split-resized");
      await run(`for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("a"); S().setFind("a", { open: false, query: "" }); acCli.indicator.setState({ shown: false }); return true;`);
      await sleep(800);
      return { split: g.split, resized: g["split-resized"] };
    });

    if (pool === "1") {
      await app.quit().catch(() => {});
      app = null;
      continue;
    }

    await rep.check(`${panes}-auto-hide`, async () => {
      await run(`S().updateSettings({ hideToolbarWhileScrolling: true }); return true;`);
      await sleep(800);
      await run(`ac.toolbarAutoHide.noteScroll("a", { state: "down" }); return true;`);
      await sleep(1200);
      await run(`patchA({ status: "https://example.com/a-link" }); return true;`);
      await sleep(600);
      g["auto-hide"] = {};
      await snap("auto-hide");
      const shifts = await run(`const out = []; ac.toolbarAutoHide.noteScroll("a", { state: "up" }); const sample = (n) => n ? frame().then(() => { out.push(statusShift()); return sample(n - 1); }) : Promise.resolve(out); return sample(40);`);
      g["auto-hide"].shifts = shifts;
      await run(`patchA({ status: null }); S().updateSettings({ hideToolbarWhileScrolling: false }); return true;`);
      await sleep(800);
      return true;
    });

    await rep.check(`${panes}-peek-draws-site-controls-once-every-frame`, async () => {
      await run(`S().updateSettings({ addressBar: "sidebar" }); if (S().windows.w1.sidebarOpen) S().toggleSidebar("w1"); return true;`);
      await sleep(1200);
      await run(`acLayout.pages.setState((s) => ({ popover: { ...s.popover, a: "siteControls" } })); return true;`);
      await until("site controls open", `return openControls() >= 1 || null;`);
      const counts = await run(`
        const out = [];
        const rnPeek = acLayout.peek.w1;
        const edge = ac.shell.devLeftEdgePointer;
        if (!rnPeek && !edge) throw new Error("no dock peek for w1");
        const show = () => (rnPeek ? Promise.resolve(rnPeek.show()) : edge("w1", { x: 2, y: 300 }));
        const hide = () => (rnPeek ? Promise.resolve(rnPeek.hide()) : edge("w1", null));
        const beside = () => acPerf.findFibers("BesidePeekPopovers", 10).length;
        const sample = (n) => n ? frame().then(() => { out.push([openControls(), beside()]); return sample(n - 1); }) : Promise.resolve(out);
        return show().then(() => sample(rnPeek ? 30 : 90)).then((o) => hide().then(() => o));`);
      await run(`acLayout.pages.setState((s) => ({ popover: { ...s.popover, a: null } })); return true;`);
      const bad = counts.filter(([n]) => n !== 1);
      if (bad.length) throw new Error(`Site Controls drawn ${JSON.stringify(counts.map(([n]) => n))} times per frame`);
      const besideFrames = counts.filter(([, b]) => b > 0).length;
      if (!besideFrames) throw new Error("the peek never moved Site Controls beside it");
      return { frames: counts.length, besideFrames };
    });

    await app.quit().catch(() => {});
    app = null;
  }

  await rep.check("status-bubble-rides-the-toolbar", async () => {
    const [off, on] = [got[0]["auto-hide"]?.shifts, got[1]["auto-hide"]?.shifts];
    if (!off || !on) throw new Error("no samples");
    const moved = (xs) => xs.filter((x) => typeof x === "number" && Math.abs(x) > 0.5).length;
    const extent = (xs) => Math.max(0, ...xs.filter((x) => typeof x === "number").map(Math.abs));
    if (!moved(off)) throw new Error(`the toolbar never moved the status bubble without pane roots: ${JSON.stringify(off)}`);
    if (!moved(on) || Math.abs(extent(on) - extent(off)) > 1) throw new Error(`status shift off ${JSON.stringify(off)}, on ${JSON.stringify(on)}`);
    return { off: extent(off), on: extent(on), frames: [moved(off), moved(on)] };
  });

  for (const state of STATES) {
    await rep.check(`same-${state}`, async () => {
      const [off, on] = [got[0][state], got[1][state]];
      if (!off?.shot || !on?.shot) throw new Error(`missing ${state} snapshots`);
      for (const key of ["find", "pill"]) if (off[key] !== undefined && !(off[key] === on[key] || near(off[key], on[key]))) throw new Error(`${key}: off ${off[key]}, on ${on[key]}`);
      const bottomRow = (pill) => [0, pill[1] - 4, pill[0] + pill[2] + 8, pill[3] + 8];
      const d = pixelDiff(off.shot, on.shot, state.startsWith("split") ? [on.find, bottomRow(on.pill)] : []);
      if (d.max > 8) throw new Error(`snapshots differ: ${JSON.stringify(d)}`);
      return { find: on.find, pill: on.pill, pixels: d };
    });
  }
  for (const state of ["split", "split-resized"]) {
    const name = `pooled-same-${state}`;
    if (!poolServing) {
      rep.record(name, { skip: "pending: SolaraTabPool doesn't serve pages in this build, so the pool leg drew RN's" });
      continue;
    }
    await rep.check(name, async () => {
      const [rn, pooled] = [got[1][state], got.pool[state]];
      if (!rn?.shot || !pooled?.shot) throw new Error(`missing ${state} snapshots`);
      for (const key of ["find", "pill"]) if (!(rn[key] === pooled[key] || near(rn[key], pooled[key]))) throw new Error(`${key}: RN pages ${rn[key]}, pooled ${pooled[key]}`);
      const d = pixelDiff(rn.shot, pooled.shot, []);
      if (d.max > 8) throw new Error(`snapshots differ: ${JSON.stringify(d)}. Known engine red, not placement: a restored, never-shown pooled page can keep Chrome's background layer transparent (ac_contents_background.mm doesn't refresh it when the ahead-blank ends), and layer.render draws only that layer; the fix is queued in owner-away-queue.md (port-strip, engine fix A). Check with devWindow "layers:x,y" which layer differs`);
      return { pixels: d };
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
