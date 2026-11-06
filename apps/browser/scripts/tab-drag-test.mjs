import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { deflateSync, inflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

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
  console.error("usage: node tab-drag-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--keep-data]");
  process.exit(2);
}
const appPath = resolve(appArg);
const port = args.find((a) => a.startsWith("--port="))?.slice(7);
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-tab-drag-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "tab-drag-test.log"), { name: "tab-drag-test" });

const tab = (id, windowId, pinned = false) => ({ id, windowId, pinned, lastActiveAt: id === "t1" ? 2 : 1 });
const fixture = () => session({
  profiles: [{ id: "default", name: "Personal", color: "plum" }],
  settings: { tabLayout: "top" },
  windows: [
    { id: "w1", tabIds: ["p1", "p2", "t1", "t2", "t3", "t4"], activeTabIds: { default: "t1" }, frame: [80, 80, 1280, 800], createdAt: 1 },
    { id: "w2", tabIds: ["l1"], activeTabIds: { default: "l1" }, frame: [200, 120, 1100, 700], createdAt: 2 },
    { id: "w3", tabIds: ["g1", "g2", "x1"], activeTabIds: { default: "x1" }, frame: [140, 100, 1200, 760], createdAt: 3 },
    { id: "w5", tabIds: ["a1", "a2"], activeTabIds: { default: "a2" }, frame: [100, 60, 560, 420], createdAt: 5 },
    { id: "w6", tabIds: ["b1", "b2", "b3"], activeTabIds: { default: "b1" }, frame: [700, 60, 560, 420], createdAt: 6 },
  ],
  tabs: [tab("p1", "w1", true), tab("p2", "w1", true), tab("t1", "w1"), tab("t2", "w1"), tab("t3", "w1"), tab("t4", "w1"), tab("l1", "w2"),
    tab("g1", "w3"), tab("g2", "w3"), tab("x1", "w3"), tab("a1", "w5"), tab("a2", "w5"), tab("b1", "w6"), tab("b2", "w6"), tab("b3", "w6")],
  groups: [{ id: "grp", windowId: "w3", profileId: "default", name: "Group", icon: null, color: null, collapsed: false, pinned: false, tabIds: ["g1", "g2"], createdAt: 1 }],
});

let app = null;

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const st = () => ac.store.getState();
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const act = (id, a) => win(id).then((n) => C.devWindow(n, a));
const items = (id) => win(id).then((n) => { const xs = []; for (let x = 70; x < st().windows[id].frame[2] - 100; x += 1) xs.push(x);
  return Promise.all(xs.map((x) => C.devWindow(n, "hit:" + x + ",21"))).then((hits) => { const runs = []; let cur = null;
    hits.forEach((h, i) => { const on = /ContextMenuArea|ImageView|Symbol|FadeLabel|Strip(TabChip|PinnedCell|GroupHeader|FolderChip|SplitChip)/.test(h); if (on && !cur) cur = [xs[i], xs[i]]; else if (on) cur[1] = xs[i]; else if (cur) { runs.push(cur); cur = null; } });
    if (cur) runs.push(cur); return runs; }); });
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const loose = (id) => st().windows[id].tabIds.filter((t) => !st().tabs[t].pinned);
const tabItems = (id) => items(id).then((xs) => xs.slice(st().windows[id].tabIds.length - loose(id).length));
`;
const DRAG_FIELDS = ["focusedWindowId", "windowDragCount", "groups", "splits", "dragPreview", "tabDrag", "fileDropSequence", "haptics"].map((key) => "root." + key).concat(
  ...["profileId", "tabIds", "activeTabIds", "savedFrame", "screenFrame", "sidebarOpen"].map((key) => "windows." + key),
  ...["windowId", "pinned", "tileFolderId"].map((key) => "tabs." + key));
const nativeSnapshot = (args = {}) => {
  if (nativePollDeadline !== null && nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms left");
  return app.snapshot({ tabDrag: true, fields: DRAG_FIELDS, ...args }, { timeout: 1000 });
};
const untilSnapshot = async (what, accept, ms = 5000, args = {}) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: app exited`);
    if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
    last = await nativeSnapshot(args);
    if (Date.now() < end && last.consistent && await acceptSnapshot(end, accept, last) && Date.now() < end) return last;
    await sleep(40);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const nativeWindow = (s, id) => s.windows.find((w) => w.id === id);
const normalizeURL = (raw) => {
  try {
    const u = new URL(raw);
    if (!["http:", "https:", "about:", "chrome:", "file:", "solara:", "solara:"].includes(u.protocol)) return u.protocol;
    if (u.protocol === "file:") {
      let path;
      try { path = realpathSync(fileURLToPath(u)); } catch { return null; }
      const root = realpathSync(data);
      if (path !== root && !path.startsWith(root + "/")) return null;
    }
    u.username = "";
    u.password = "";
    return u.href.slice(0, 2048);
  } catch { return null; }
};
const nativeProjection = (s) => ({
  focused: s.focusedWindowId,
  windows: s.windows.map((w) => ({ id: w.id, profileId: w.profileId, tabIds: w.tabIds, activeTabIds: w.activeTabIds, frame: w.savedFrame, sidebarOpen: w.sidebarOpen })).sort((a, b) => a.id.localeCompare(b.id)),
  tabs: s.tabs.map((t) => ({ id: t.id, windowId: t.windowId, pinned: t.pinned, tileFolderId: t.tileFolderId })).sort((a, b) => a.id.localeCompare(b.id)),
  groups: s.groups,
  splits: s.splits,
});
const mirrorStore = async () => {
  const read = () => evaluate(`${HELPERS}
    const s = st();
    return { focused: s.ui.focusedWindowId ?? null,
      windows: Object.values(s.windows).map((w) => ({ id: w.id, profileId: w.profileId, tabIds: w.tabIds, activeTabIds: w.activeTabIds, frame: w.frame ?? null, sidebarOpen: w.sidebarOpen })).sort((a, b) => a.id.localeCompare(b.id)),
      tabs: Object.values(s.tabs).map((t) => ({ id: t.id, windowId: t.windowId, pinned: !!t.pinned, tileFolderId: t.tileFolder?.id ?? null, url: t.url })).sort((a, b) => a.id.localeCompare(b.id)),
      groups: Object.values(s.groups).map((g) => ({ id: g.id, windowId: g.windowId, tabIds: g.tabIds, pinned: !!g.pinned })).sort((a, b) => a.id.localeCompare(b.id)),
      splits: Object.values(s.splits).map((v) => ({ id: v.id, windowId: v.windowId, tabIds: v.tabIds })).sort((a, b) => a.id.localeCompare(b.id)) };
  `);
  let state;
  const native = await untilSnapshot("native drag workspace mirrors JS", async (s) => {
    state = await read();
    state.tabs = state.tabs.map(({ url, ...tab }) => tab);
    return isDeepStrictEqual(nativeProjection(s), state);
  });
  assert.deepEqual(nativeProjection(native), state);
  let urls;
  const nativeURLs = await untilSnapshot("native drag tab URLs mirror JS", async (s) => {
    const current = await read();
    urls = current.tabs.map((t) => ({ id: t.id, url: normalizeURL(t.url) }));
    return isDeepStrictEqual(s.tabs.map(({ id, url }) => ({ id, url })).sort((a, b) => a.id.localeCompare(b.id)), urls);
  }, 5000, { fields: ["tabs.url"] });
  assert.deepEqual(nativeURLs.tabs.map(({ id, url }) => ({ id, url })).sort((a, b) => a.id.localeCompare(b.id)), urls);
  return native;
};
const run = async (body) => {
  const observesPreview = body.includes("devDragPreviewState");
  const observesWindow = body.includes("windowDrags") && body.includes("const frame =");
  const observesDrops = body.includes("FD.drag");
  const initial = observesWindow || observesDrops || observesPreview ? await nativeSnapshot() : null;
  const snapshots = [];
  const samples = [];
  let settled = false, value, error;
  const evaluation = evaluate(`${HELPERS}\n${body}`).then((result) => { value = result; settled = true; }, (failure) => { error = failure; settled = true; });
  const end = Date.now() + 60000;
  while ((observesPreview || observesWindow) && !settled && Date.now() < end) {
    if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
    const sample = await nativeSnapshot();
    if (sample.consistent) { samples.push(sample.dragPreview); snapshots.push(sample); }
    await sleep(40);
  }
  await evaluation;
  if (error) throw error;
  const dropped = observesPreview ? await nativeSnapshot({ fields: ["root.dragPreview"] }) : null;
  const native = await mirrorStore();
  snapshots.push(native);
  if (observesWindow) {
    const matchFrame = (sample, text) => {
      const frame = text.match(/[-\d.]+/g).map(Number);
      return sample.windows.some((w) => w.screenFrame?.every((v, i) => Math.abs(v - frame[i]) <= 0.5));
    };
    for (const key of ["before", "zoomed", "back", "after"]) if (typeof value?.[key] === "string") {
      assert.ok(snapshots.some((sample) => matchFrame(sample, value[key])), `native ${key} physical window frame`);
    }
    if (typeof value?.drags === "number") assert.ok(snapshots.some((sample) => sample.windowDragCount - initial.windowDragCount === value.drags && matchFrame(sample, value.before)), "native titlebar/sidebar window drag count beside JS");
  }
  if (observesDrops) {
    const sequence = initial.fileDropSequence;
    const drops = await nativeSnapshot({ fileDropAfter: sequence, fields: ["root.fileDropResults"] });
    const records = drops.fileDropResults.map((record) => record.result);
    if (Array.isArray(value?.log)) assert.deepEqual(records.slice(0, value.log.length), value.log, "native file-drop result log beside JS");
    if (typeof value?.r === "string") assert.ok(records.includes(value.r), `native file-drop result ${value.r}`);
  }
  if (observesPreview) {
    samples.push(native.dragPreview);
    const observed = [];
    const collect = (item) => {
      if (!item || typeof item !== "object") return;
      if (typeof item.shape === "string") observed.push(item);
      else for (const child of Object.values(item)) collect(child);
    };
    collect(value);
    if (Array.isArray(value) && Array.isArray(value.at(-1)?.shapes)) {
      const before = await evaluate(`return globalThis.expo.modules.SolaraShell.devDragPreviewState();`);
      const current = await nativeSnapshot({ fields: ["root.dragPreview"] });
      const after = await evaluate(`return globalThis.expo.modules.SolaraShell.devDragPreviewState();`);
      assert.ok(current.consistent, "native preview comparison snapshot is consistent");
      assert.ok(current.dragPreview.visible === before.visible || current.dragPreview.visible === after.visible,
        `native final preview visibility beside bracketed JS: ${JSON.stringify({ before: before.visible, native: current.dragPreview.visible, after: after.visible, watchFinal: value.at(-1).visible })}`);
      assert.deepEqual(native.dragPreview.shapes.slice(0, value.at(-1).shapes.length), value.at(-1).shapes, "native ordered preview shape history beside JS");
    }
    for (const item of observed) {
      assert.ok(native.dragPreview.shapes.includes(item.shape) || item.shape === "hidden", `native preview shape ${item.shape}`);
      if (item.shape === "card" && item.frame?.[2] === 209 && item.frame[3] === 110) {
        assert.ok(samples.some((p) => p.shape === "card" && Math.abs(p.frame[2] - item.frame[2]) <= 0.5 && Math.abs(p.frame[3] - item.frame[3]) <= 0.5), "native card dimensions beside JS");
        if (!Array.isArray(value)) assert.ok(samples.some((p) => p.shape === "card" && Math.abs(p.frame[2] - item.frame[2]) <= 0.5 && Math.abs(p.frame[3] - item.frame[3]) <= 0.5 && p.page === item.page && p.placeholder === item.placeholder), "native card page and placeholder beside JS");
      }
    }
    if (observed.length) {
      const source = initial.windows.find((w) => w.id === "w1")?.savedFrame;
      if (source && observed.some((p) => p.shape === "card" && p.frame?.[1] + p.frame?.[3] / 2 > source[1] + source[3])) {
        assert.ok(samples.some((p) => p.shape === "card" && p.frame?.[1] + p.frame?.[3] / 2 > source[1] + source[3]), "native card centre leaves the source window beside JS");
      }
      if (source && observed.some((p) => p.visible && p.frame?.[2] === source[2] && p.frame?.[3] === source[3])) {
        const start = snapshots.find((s) => s.consistent && s.dragPreview.sequence > initial.dragPreview.sequence && s.tabDrag.sourceWindow === "w1" && s.tabDrag.tabIds.length > 0);
        assert.ok(start, "native active drag session sequence observed after begin");
        assert.ok(dropped.consistent, "native growth completion snapshot is consistent");
        const growth = dropped.dragPreview.growth;
        assert.ok(growth, "native preview records growth completion");
        assert.equal(dropped.dragPreview.sequence, start.dragPreview.sequence, "native post-drop session matches the observed drag");
        assert.equal(growth.sequence, start.dragPreview.sequence, "native growth completion belongs to this drag");
        assert.equal(growth.visible, true, "native preview is visible at growth completion");
        for (const [size, target, expected] of [[growth.width, growth.targetWidth, source[2]], [growth.height, growth.targetHeight, source[3]]]) {
          assert.ok(Number.isFinite(size) && Number.isFinite(target) && Math.abs(size - target) <= 0.5 && Math.abs(target - expected) <= 0.5, "native preview grows to the new window dimensions beside JS");
        }
      }
      assert.ok(samples.every((p) => !p.key && !p.activeApp && (p.shape === "hidden" || p.ignoresMouse)), "native drag picture never takes focus or mouse input");
    }
  }
  return value;
};
const order = async (w) => {
  let ids;
  const native = await untilSnapshot("native tab order", async (s) => {
    ids = await run(`return st().windows.${w}.tabIds;`);
    return isDeepStrictEqual(nativeWindow(s, w)?.tabIds, ids);
  });
  assert.deepEqual(nativeWindow(native, w).tabIds, ids);
  return ids;
};
const tabsOf = async (w) => {
  let ids;
  const native = await untilSnapshot("native loose tab order", async (s) => {
    ids = await run(`return loose("${w}");`);
    return isDeepStrictEqual(nativeWindow(s, w)?.tabIds.filter((id) => !s.tabs.find((t) => t.id === id)?.pinned), ids);
  });
  assert.deepEqual(nativeWindow(native, w).tabIds.filter((id) => !native.tabs.find((t) => t.id === id).pinned), ids);
  return ids;
};
const drag = async (w, points) => {
  const before = await nativeSnapshot();
  const count = await run(`return act("${w}", "windowDrags").then(() => act("${w}", "drag:${points.map((p) => p.join(",")).join(";")}")).then(() => settle(${points.length * 12 * 16 + 700})).then(() => act("${w}", "windowDrags")).then((t) => Number(t.split("\\n")[0]));`);
  const after = await nativeSnapshot();
  assert.equal(after.windowDragCount - before.windowDragCount, count, "native window drag count beside JS");
  return count;
};

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      assert.equal(buf[at + 16], 8, "8-bit");
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
function contrast(png, windowWidth, [x0, y0, x1, y1]) {
  const scale = Math.round(png.width / windowWidth);
  const values = [];
  for (let y = y0 * scale; y < y1 * scale; y++)
    for (let x = x0 * scale; x < x1 * scale; x++) {
      const i = (y * png.width + x) * png.channels;
      values.push(0.2126 * png.data[i] + 0.7152 * png.data[i + 1] + 0.0722 * png.data[i + 2]);
    }
  const mean = values.reduce((a, v) => a + v, 0) / values.length;
  return Math.sqrt(values.reduce((a, v) => a + (v - mean) ** 2, 0) / values.length);
}

const check = (name, fn) => rep.check(name, fn);

try {
  app = await launch(appPath, { data, port, session: fixture() });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  const initialNative = await untilSnapshot("native drag workspace", (s) => s.windows.length === 5);
  for (const field of ["windows.sidebarDrag", "windows.savedFrame", "windows.screenFrame", "tabs.tileFolderId", "groups", "splits", "dragPreview", "tabDrag", "fileDragURLs", "fileDropResults", "windows.dragPoints", "haptics"]) assert.ok(initialNative.capabilities.available.includes(field), field);
  await sleep(1500);
  if (!(await run(`return !!globalThis.acTabDrag;`))) throw new Error("tab-drag-test runs on Debug builds only: acTabDrag and the ac.shell hooks are __DEV__-only");
  await run(`return act("w1", "windowDrags");`);

  const strip = await run(`return items("w1");`);
  assert.equal(strip.length, 6, `strip items ${JSON.stringify(strip)}`);
  const mid = (i) => Math.round((strip[i][0] + strip[i][1]) / 2);

  const PREVIEW = `const preview = () => globalThis.expo.modules.SolaraShell.devDragPreviewState();`;
  const watch = (w, path, ms) => run(`${PREVIEW}
    const seen = [];
    const iv = setInterval(() => preview().then((p) => seen.push(p)), 30);
    return act("${w}", "drag:${path}").then(() => settle(${ms})).then(() => { clearInterval(iv); return seen; });`);

  await check("a tab dragged along the strip reorders and doesn't move the window", async () => {
    const frame = await run(`return st().windows.w1.frame;`);
    const drags = await drag("w1", [[mid(2), 21], [mid(3), 21], [mid(4) + 75, 21]]);
    assert.equal(drags, 0, "window drags");
    assert.deepEqual(await order("w1"), ["p1", "p2", "t2", "t3", "t1", "t4"]);
    assert.deepEqual(await run(`return Object.values(st().groups).filter((g) => g.windowId === "w1").length;`), 0, "let go past the neighbour's far quarter: a reorder, no group");
    assert.deepEqual(await run(`return st().windows.w1.frame;`), frame);
  });

  await check("Escape cancels a lifted strip drag without reordering, detaching or splitting, and the app stays responsive", async () => {
    const before = await order("w1");
    const windows = await run(`return Object.keys(st().windows).sort();`);
    const splits = await run(`return st().splits;`);
    const groups = await run(`return st().groups;`);
    const now = await run(`return items("w1");`);
    const sx = Math.round((now[2][0] + now[2][1]) / 2);
    const result = await run(`${PREVIEW}
      const result = {};
      const drag = () => { const d = globalThis.acTabDrag.getState(); return { ids: d.tabIds, lifted: !!d.lifted }; };
      const post = (a, ms) => act("w1", a).then(() => settle(ms));
      return post("mouse:moved:${sx},21", 60)
        .then(() => post("mouse:down:${sx},21", 100))
        .then(() => post("mouse:dragged:${sx + 6},21", 60))
        .then(() => post("mouse:dragged:${sx + 14},21", 60))
        .then(() => post("mouse:dragged:${sx + 14},120", 60))
        .then(() => post("mouse:dragged:640,400", 300))
        .then(() => preview().then((p) => { result.held = { ...drag(), order: st().windows.w1.tabIds, visible: p.visible }; }))
        .then(() => act("w1", "sendKey:" + String.fromCharCode(27) + ":53"))
        .then((sent) => { result.posted = sent === "sent"; return settle(300); })
        .then(() => preview().then((p) => { result.cancelled = { ids: drag().ids, visible: p.visible }; }))
        .then(() => post("mouse:dragged:640,420", 60))
        .then(() => post("mouse:dragged:${sx + 200},21", 60))
        .then(() => post("mouse:up:${sx + 200},21", 1200))
        .then(() => preview().then((p) => { result.finished = { ids: drag().ids, visible: p.visible }; return result; }));`);
    assert.deepEqual(result.held, { ids: [before[2]], lifted: true, order: before, visible: true }, "Escape is pressed during the live lifted drag");
    assert.equal(result.posted, true, "Escape entered the app event queue");
    assert.deepEqual(result.cancelled, { ids: [], visible: false }, "Escape immediately ends the session and cancels the preview");
    assert.deepEqual(result.finished, { ids: [], visible: false }, "remaining drag events and mouse-up cannot drop the tab");
    assert.deepEqual(await order("w1"), before, "the tab returns to its original index");
    assert.deepEqual(await run(`return Object.keys(st().windows).sort();`), windows, "no new window");
    assert.deepEqual(await run(`return st().splits;`), splits, "no split");
    assert.deepEqual(await run(`return st().groups;`), groups, "no grouping or reorder drop");
    const t0 = Date.now();
    const capture = await app.probe("view.capture", { windowId: "w1" }, { timeout: 2000 });
    assert.equal(capture.consistent, true, "a capture right after the cancelled drag is consistent");
    rep.log(`escape capture ready in ${Date.now() - t0} ms`);
  });

  await check("a tab dragged along the strip changes nothing until the drop: then one store update and one Chrome strip command", async () => {
    const now = await run(`return items("w1");`);
    const before = await order("w1");
    const at = (i) => Math.round((now[i][0] + now[i][1]) / 2);
    const live = before.slice(2, 4);
    try {
      assert.equal(await run(`${JSON.stringify(live)}.forEach((id, i) => st().navigate(id, "data:text/html,<h1>" + i));
        const ready = () => C.tabStrips().then((snapshot) => snapshot.strips.some((s) => ${JSON.stringify(live)}.every((id) => s.tabs.some((t) => t.key === id))));
        const wait = (n) => ready().then((ok) => ok || !n ? ok : settle(100).then(() => wait(n - 1)));
        return wait(100);`), true, "both tabs have live Chrome strips");
      const path = [[at(2), 21], [at(2) + 20, 21], [at(3), 21], [at(3) + 75, 21]];
      const seen = await run(`
        const cef = globalThis.expo.modules.SolaraCEF;
        const adapter = globalThis.expo.modules.SolaraStoreAdapter;
        const native = adapter.status().scope === "everything";
        const send = cef.tabStripCommand;
        const t0 = performance.now();
        const log = { commands: [], windows: [], drag: [], picture: [] };
        const probe = () => native ? adapter.devStripCommandProbe().then(JSON.parse) : Promise.resolve({ sent: log.commands.length, held: 0 });
        cef.tabStripCommand = (...a) => { log.commands.push(performance.now() - t0); return send.apply(cef, a); };
        const unsubscribe = ac.store.subscribe((s, p) => { if (s.windows !== p.windows) log.windows.push(performance.now() - t0); });
        const begin = ac.shell.dragPreview.begin;
        ac.shell.dragPreview.begin = (...a) => { log.picture.push(performance.now() - t0); return begin(...a); };
        const stop = globalThis.acTabDrag.subscribe((d, was) => { if (!d.tabIds.length !== !was.tabIds.length) log.drag.push([d.tabIds.length > 0, performance.now() - t0]); });
        let initial;
        return Promise.resolve().then(probe).then((n) => {
          initial = n;
          return act("w1", "drag:${path.map((p) => p.join(",")).join(";")}").then(() => settle(${path.length * 12 * 16 + 1200}));
        }).then(probe).then((n) => {
          log.sentCommands = n.sent - initial.sent;
          log.sentWhileHeld = n.held - initial.held;
          log.native = native;
          return log;
        }).finally(() => { stop(); unsubscribe(); cef.tabStripCommand = send; ac.shell.dragPreview.begin = begin; });`);
      const start = seen.drag.find(([on]) => on)?.[1];
      const drop = seen.drag.find(([on]) => !on)?.[1];
      assert.ok(start !== undefined && drop !== undefined, JSON.stringify(seen.drag));
      assert.equal(seen.sentWhileHeld, 0, "no native strip command before the actual drop");
      if (!seen.native) assert.deepEqual(seen.commands.filter((t) => t < drop), [], "no JS strip command before drop");
      assert.deepEqual(seen.windows.filter((t) => t < drop), [], "no store update before drop");
      assert.equal(seen.windows.length, 1, `one store update on drop: ${JSON.stringify(seen.windows)}`);
      assert.equal(seen.sentCommands, 1, `one strip command on drop: ${seen.sentCommands}`);
      assert.deepEqual(seen.picture, [], "no drag picture for a reorder");
      assert.notDeepEqual(await order("w1"), before, "it moved");
    } finally {
      await run(`const id = ${JSON.stringify(before[2])}; const ids = ${JSON.stringify(before)}.filter((t) => !st().tabs[t].pinned); st().moveTab(id, ids.indexOf(id)); return settle(300);`);
    }
    assert.deepEqual(await order("w1"), before);
  });

  await check("a tab dragged over its right neighbour draws on top of it, its card opaque in dark", async () => {
    const now = await run(`return items("w1");`);
    const before = await order("w1");
    const [a, b] = [now[2], now[3]];
    const x0 = Math.round((a[0] + a[1]) / 2);
    const x1 = x0 + Math.round((a[1] - a[0]) * 0.4);
    await run(`ac.shell.setAppearance("dark"); st().activate(${JSON.stringify(before[2])}); return settle(800).then(() => st().settings);`);
    const end = a[1] + (x1 - x0);
    const icon = [end - 24, 12, end - 6, 30];
    const shots = [join(data, "z-alone.png"), join(data, "z-over.png")];
    await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shots[0])});`);
    const nativeAlone = await app.probe("view.capture", { windowId: "w1" });
    const jsOver = evaluate(`${HELPERS}\nreturn act("w1", "drag:${x0},21;${x0 + 10},21;${x1},21;${x1},21;${x1},21;${x1},21")
      .then(() => settle(150 + 12 * 16 * 2 + 200)).then(() => ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shots[1])}));`);
    const [nativeOver] = await Promise.all([
      sleep(150 + 12 * 16 * 2 + 200).then(() => app.probe("view.capture", { windowId: "w1" })).then((capture) => {
        assert.ok(capture.consistent, "native held capture session is consistent");
        assert.equal(capture.tabDrag.sourceWindow, "w1", "tab drag is held by w1 at capture time");
        assert.deepEqual(capture.tabDrag.tabIds, [before[2]], "the dragged tab is held at capture time");
        return capture;
      }),
      jsOver,
    ]);
    await sleep(1500);
    await mirrorStore();
    const windowWidth = await run(`return st().windows.w1.frame[2];`);
    const [alone, over] = shots.map((path) => contrast(readPng(path), windowWidth, icon));
    assert.ok(alone > 12, `the box holds the icon: ${alone}`);
    assert.ok(over < 3, `the neighbour's icon shows through the dragged tab: contrast alone ${alone.toFixed(1)}, held over ${over.toFixed(1)}`);
    const nativeContrast = [nativeAlone, nativeOver].map((capture) => contrast(readPng(join(data, capture.artifact)), windowWidth, icon));
    assert.ok(nativeContrast[0] > 12, `native icon contrast ${nativeContrast[0]}`);
    assert.ok(nativeContrast[1] < 3, `native held icon contrast ${nativeContrast[1]}`);
    rep.log(`the neighbour's icon: contrast ${alone.toFixed(1)} alone, ${over.toFixed(1)} under the dragged tab`);
    assert.deepEqual(await order("w1"), before, "it went back");
  });

  await check("a lone tab dragged doesn't move its window", async () => {
    const lone = await run(`return items("w2");`);
    const before = await order("w2");
    assert.equal(before.at(-1), "l1", "the profile's pinned tiles, then its one tab");
    const x = Math.round((lone.at(-1)[0] + lone.at(-1)[1]) / 2);
    const drags = await drag("w2", [[x, 21], [x + 60, 24], [x + 140, 26]]);
    assert.equal(drags, 0, "window drags");
    assert.deepEqual(await order("w2"), before);
  });

  await check("a pinned tile trades places with the other pinned tile", async () => {
    const drags = await drag("w1", [[mid(0), 21], [mid(1), 21], [mid(1) + 24, 21]]);
    assert.equal(drags, 0, "window drags");
    assert.deepEqual((await order("w1")).slice(0, 2), ["p2", "p1"]);
  });

  await check("the empty strip still moves the window", async () => {
    const drags = await drag("w1", [[strip[5][1] + 120, 21], [strip[5][1] + 200, 21]]);
    assert.equal(drags, 1, "window drags");
  });

  await check("the empty strip moves the window over its whole height, and a double-click on it zooms", async () => {
    const x = strip[5][1] + 150;
    const result = await run(`
      return win("w1").then((n) => {
        const frame = () => C.chromeWindows().then((ws) => ws.find((w) => w.window === n).frame);
        const click = (y, count) => C.devWindow(n, "mouse:down:${x}," + y + "," + count).then(() => settle(30)).then(() => C.devWindow(n, "mouse:up:${x}," + y + "," + count)).then(() => settle(60));
        const out = {};
        return C.devWindow(n, "windowDrags")
          .then(() => click(4, 1)).then(() => click(38, 1)).then(() => settle(300))
          .then(() => C.devWindow(n, "windowDrags")).then((d) => { out.drags = Number(d.split("\\n")[0]); return frame(); })
          .then((f) => { out.before = f; return click(38, 1).then(() => click(38, 2)); }).then(() => settle(900)).then(frame)
          .then((f) => { out.zoomed = f; return click(38, 1).then(() => click(38, 2)); }).then(() => settle(900)).then(frame)
          .then((f) => { out.back = f; return out; });
      });`);
    assert.equal(result.drags, 2, "a press at the strip's top and one near its bottom each drag the window");
    let action = null;
    try { action = execFileSync("defaults", ["read", "-g", "AppleActionOnDoubleClick"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch {}
    if (action === "None" || action === "Minimize") return;
    assert.notEqual(result.zoomed, result.before, "a double-click zooms (the title-bar action)");
    assert.equal(result.back, result.before, "a second double-click puts it back");
  });

  await check("a group's member trades places inside the group, and a tab moves past the whole group", async () => {
    const items = await run(`return tabItems("w3");`);
    assert.equal(items.length, 4, JSON.stringify(items));
    const at = (i) => Math.round((items[i][0] + items[i][1]) / 2);
    assert.equal(await drag("w3", [[at(2), 21], [at(1), 21], [at(1) - 40, 21]]), 0, "window drags");
    assert.deepEqual(await run(`return [loose("w3"), st().groups.grp.tabIds];`), [["g2", "g1", "x1"], ["g2", "g1"]]);
    await drag("w3", [[items[3][0] + 10, 21], [at(1), 21], [items[0][0] + 10, 21]]);
    assert.deepEqual(await run(`return [loose("w3"), st().groups.grp.tabIds];`), [["x1", "g2", "g1"], ["g2", "g1"]]);
  });

  await check("a group dragged by its chip moves along the strip as one", async () => {
    const items = await run(`return tabItems("w3");`);
    const at = (i) => Math.round((items[i][0] + items[i][1]) / 2);
    assert.equal(await drag("w3", [[Math.round(items[1][0] + 15), 21], [at(0), 21], [items[0][0] - 20, 21]]), 0, "window drags");
    assert.deepEqual(await run(`return [loose("w3"), st().groups.grp.tabIds];`), [["g2", "g1", "x1"], ["g2", "g1"]]);
  });

  await check("a tab dragged onto another window's tabs: the strip makes room at the pointer, and it lands there", async () => {
    try {
      await run(`st().setFocusedWindow("w5"); st().setFocusedWindow("w6"); return 1;`);
      const from = await run(`return tabItems("w5");`);
      const into = await run(`return tabItems("w6");`);
      const dx = 600;
      const a1 = Math.round((from[0][0] + from[0][1]) / 2);
      const between = dx + Math.round((into[0][1] + into[1][1]) / 2);
      const seen = await run(`${PREVIEW}
        const seen = [];
        const iv = setInterval(() => preview().then((p) => { const d = globalThis.acTabDrag.getState(); seen.push({ shape: p.shape, insert: d.insert, over: d.overWindow }); }), 30);
        return act("w5", "drag:${a1},21;${a1},-20;${dx - 30},-20;${between - 3},21;${between - 1},22;${between},21").then(() => settle(1400)).then(() => { clearInterval(iv); return seen; });`);
      const overW6 = seen.filter((s) => s.over === "w6");
      assert.ok(seen.some((s) => s.over === "w6" && s.insert?.windowId === "w6" && s.insert.beforeId === "b2"), JSON.stringify({ overW6: overW6.slice(-4), samples: seen.length, w6: await tabsOf("w6") }));
      assert.ok(seen.some((s) => s.insert && s.shape === "pill"), "the pill over the strip");
      assert.deepEqual(await tabsOf("w6"), ["b1", "a1", "b2", "b3"]);
      assert.deepEqual(await tabsOf("w5"), ["a2"]);
    } finally {
      await run(`st().closeWindow("w5"); st().closeWindow("w6"); return settle(900);`);
    }
  });

  await check("a background tab's card shows its own page: its last picture, else its icon and title", async () => {
    const cardOf = async (id) => {
      const now = await run(`return items("w1");`);
      const i = (await order("w1")).indexOf(id);
      const x = Math.round((now[i][0] + now[i][1]) / 2);
      return run(`${PREVIEW}
        const out = {};
        act("w1", "drag:${x},21;${x},220;640,560;640,600;640,640;${x},100;${x},21");
        setTimeout(() => preview().then((p) => (out.p = p)), 760);
        return settle(2200).then(() => out.p);`);
    };
    const before = await order("w1");
    const never = await cardOf("t4");
    assert.equal(never?.shape, "card", JSON.stringify(never));
    assert.ok(never.page && never.placeholder, `placeholder ${JSON.stringify(never)}`);
    await run(`st().activate("t2"); st().navigate("t2", "data:text/html,<body style='background:%2366aaff'><h1>t2</h1>"); return settle(3200).then(() => { st().activate("t1"); return settle(600); });`);
    const shown = await cardOf("t2");
    assert.ok(shown?.page && !shown.placeholder, `its picture ${JSON.stringify(shown)}`);
    assert.deepEqual(await order("w1"), before);
  });

  await check("a tab pulled onto the page's right target splits with the page", async () => {
    const width = await run(`return st().windows.w1.frame[2];`);
    const now = await run(`return items("w1");`);
    const ids = await order("w1");
    const x = Math.round((now[3][0] + now[3][1]) / 2);
    assert.equal(ids[3], "t3");
    const state = await run(`
      const seen = [];
      const iv = setInterval(() => { const d = globalThis.acTabDrag.getState(); seen.push({ lifted: d.lifted, onPage: d.onPage, target: d.target }); }, 60);
      return act("w1", "drag:${x},21;${x},120;${width - 260},380;${width - 255},390;${width - 250},400;${width - 250},402").then(() => settle(1700)).then(() => { clearInterval(iv); return seen; });`);
    assert.ok(state.some((s) => s.lifted && s.onPage), "lifted onto the page");
    assert.ok(state.some((s) => s.target?.side === "right"), `right target ${JSON.stringify(state.slice(-6))}`);
    const splits = await run(`return Object.values(st().splits).map((v) => v.tabIds);`);
    assert.equal(splits.length, 1);
    assert.equal(splits[0].at(-1), "t3", `split ${JSON.stringify(splits)}`);
  });

  await check("a tab let go over the page away from a target opens in a window of its own, as in Dia", async () => {
    const now = await run(`return items("w1");`);
    const id = (await order("w1")).at(-1);
    const windows = await run(`return Object.keys(st().windows).length;`);
    const width = await run(`return st().windows.w1.frame[2];`);
    const x = Math.round((now.at(-1)[0] + now.at(-1)[1]) / 2);
    const splits = await run(`return Object.values(st().splits).map((v) => v.tabIds);`);
    const seen = await watch("w1", `${x},21;${x},200;${Math.round(width / 4)},560;${Math.round(width / 4)},740`, 1400);
    const shapes = seen.at(-1).shapes;
    assert.deepEqual(shapes.slice(0, 2), ["pill", "card"], `pill, then card: ${shapes}`);
    assert.ok(seen.every((p) => !p.key && !p.activeApp && (p.shape === "hidden" || p.ignoresMouse)), "never key or active, takes no mouse");
    assert.ok(seen.some((p) => p.shape === "card" && p.frame[2] === 209 && p.frame[3] === 110), "a 209 × 110 card");
    assert.equal(seen.at(-1).visible, false, "gone after the drop");
    const after = await run(`return Object.keys(st().windows).map(loose);`);
    assert.equal(after.length, windows + 1, JSON.stringify(after));
    assert.ok(after.some((ids) => ids.length === 1 && ids[0] === id), JSON.stringify(after));
    assert.deepEqual(await run(`return Object.values(st().splits).map((v) => v.tabIds);`), splits);
  });

  await check("a tab dragged out of the window shows its picture there and tears off into a new one", async () => {
    const now = await run(`return items("w1");`);
    const x = Math.round((now[2][0] + now[2][1]) / 2);
    const id = (await order("w1"))[2];
    const windows = await run(`return Object.keys(st().windows).length;`);
    const frame = await run(`return st().windows.w1.frame;`);
    const seen = await watch("w1", `${x},21;${x},-40;${x + 80},-90`, 1200);
    const outside = seen.filter((p) => p.shape === "card");
    assert.ok(outside.length, "a card outside the window");
    assert.ok(outside.some((p) => p.frame[1] + p.frame[3] / 2 > frame[1] + frame[3]), JSON.stringify(outside.at(-1)));
    assert.ok(seen.some((p) => p.visible && p.frame[2] === frame[2] && p.frame[3] === frame[3]), "grew to the new window");
    const after = await run(`return Object.keys(st().windows).map(loose);`);
    assert.equal(after.length, windows + 1, JSON.stringify(after));
    assert.ok(after.some((ids) => ids.length === 1 && ids[0] === id), JSON.stringify(after));
  });

  await check("a split moves along the strip as one, and a pane pulled out of the window leaves it", async () => {
    await run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); st().newTab("w1"); return settle(800);`);
    const ids = await order("w1");
    const fresh = ids.at(-1);
    assert.deepEqual(ids.slice(0, 4), ["p2", "p1", "t1", "t3"]);
    const now = await run(`return items("w1");`);
    const split = now[2], last = now[3];
    const y = 21;
    await drag("w1", [[Math.round(split[0] + 30), y], [Math.round(last[0]), y], [Math.round(last[1]) + 20, y]]);
    assert.deepEqual(await order("w1"), ["p2", "p1", fresh, "t1", "t3"]);
    const moved = await run(`return items("w1");`);
    const pane = Math.round(moved[3][0] + (moved[3][1] - moved[3][0]) * 0.75);
    await drag("w1", [[pane, y], [pane, -40], [pane + 40, -90]]);
    const state = await run(`return { windows: Object.keys(st().windows).map(loose), splits: Object.values(st().splits).map((v) => v.tabIds) };`);
    assert.ok(state.windows.some((w) => w.length === 1 && w[0] === "t3"), JSON.stringify(state));
    assert.ok(!state.splits.some((v) => v.includes("t3")), JSON.stringify(state));
  });

  await check("a tab dragged into the pinned tabs is pinned, and dragged back out is unpinned", async () => {
    const ids = await order("w1");
    const fresh = ids[2];
    let now = await run(`return items("w1");`);
    const x = Math.round((now[2][0] + now[2][1]) / 2);
    assert.equal(await drag("w1", [[x, 21], [now[1][0], 21], [now[0][0] + 6, 21]]), 0, "window drags");
    assert.deepEqual(await run(`return [st().windows.w1.tabIds, st().tabs["${fresh}"].pinned];`), [[fresh, "p2", "p1", "t1"], true]);
    now = await run(`return items("w1");`);
    const cell = Math.round((now[0][0] + now[0][1]) / 2);
    await drag("w1", [[cell, 21], [now[3][0], 21], [now[3][1] - 20, 21]]);
    assert.deepEqual(await run(`return [st().windows.w1.tabIds, st().tabs["${fresh}"].pinned];`), [["p2", "p1", "t1", fresh], false]);
  });

  await check("a tab let go just past the last pinned tile is pinned after it", async () => {
    const ids = await order("w1");
    const now = await run(`return items("w1");`);
    const x = Math.round((now[2][0] + now[2][1]) / 2);
    const past = now[1][1] + 17;
    assert.equal(await drag("w1", [[x, 21], [x - 20, 21], [past, 21]]), 0, "window drags");
    assert.deepEqual(await run(`return [st().windows.w1.tabIds, st().tabs["${ids[2]}"].pinned];`), [ids, true]);
    await run(`st().placeTabs(["${ids[2]}"], { pinned: false, beforeId: ${JSON.stringify(ids[3] ?? null)} }); return settle(500);`);
    assert.deepEqual(await order("w1"), ids);
  });

  await check("sidebar: a row dragged into another window's sidebar moves there", async () => {
    const [wa, wb, id] = await run(`st().updateSettings({ tabLayout: "sidebar" });
      const page = (n) => "data:text/html,<title>" + n + "</title>" + n;
      const wa = st().createWindow({ frame: [100, 60, 560, 420], url: page("xa1") });
      const wb = st().createWindow({ frame: [700, 60, 560, 420], url: page("xb1") });
      const id = st().newTab(wb, { url: page("xb2"), background: true });
      st().newTab(wb, { url: page("xb3"), background: true });
      return settle(2000).then(() => [wa, wb, id]);`);
    try {
      const rows = await run(`const c = globalThis.sidebarDrags?.[${JSON.stringify(wb)}];
        return Promise.all([...c.items.values()].filter((i) => i.kind === "row" && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], x, y, w, h })))));`);
      const row = rows.find((r) => r.id === id);
      assert.ok(row && row.w > 0, `a row for ${id}: ${JSON.stringify(rows)}`);
      const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
      const tx = 90 - 600;
      const seen = await run(`const seen = [];
        const iv = setInterval(() => seen.push(globalThis.acTabDrag.getState().overWindow ?? null), 40);
        return act(${JSON.stringify(wb)}, "drag:${sx},${sy};${sx + 10},${sy + 6};-60,${sy};${tx},${sy};${tx + 2},${sy + 2};${tx},${sy}").then(() => settle(1600)).then(() => { clearInterval(iv); return seen; });`);
      assert.ok(seen.includes(wa), `over the other window during the drag: ${JSON.stringify([...new Set(seen)])}`);
      const after = await run(`return [st().windows[${JSON.stringify(wa)}]?.tabIds ?? [], st().windows[${JSON.stringify(wb)}]?.tabIds ?? []];`);
      assert.ok(after[0].includes(id), `${id} moved: ${JSON.stringify(after)}`);
      assert.ok(!after[1].includes(id), `${id} left its window: ${JSON.stringify(after)}`);
      const shown = await run(`return [...globalThis.sidebarDrags[${JSON.stringify(wb)}].items.values()].filter((i) => i.kind === "row").map((i) => i.tabIds[0]);`);
      assert.ok(!shown.includes(id), `its old sidebar dropped the row: ${JSON.stringify(shown)}`);
    } finally {
      await run(`st().closeWindow(${JSON.stringify(wa)}); st().closeWindow(${JSON.stringify(wb)}); return settle(900);`);
    }
  });

  const twoWindows = (a, b) => run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id);
      st().updateSettings({ tabLayout: "sidebar" });
      const page = (n) => "data:text/html,<title>" + n + "</title>" + n;
      const wa = st().createWindow({ frame: ${JSON.stringify(a)}, url: page("ya1") });
      const wb = st().createWindow({ frame: ${JSON.stringify(b)}, url: page("yb1") });
      const ia = st().newTab(wa, { url: page("ya2"), background: true });
      const ib = st().newTab(wb, { url: page("yb2"), background: true });
      st().newTab(wb, { url: page("yb3"), background: true });
      return settle(2000).then(() => [wa, wb, ia, ib]);`);
  const nativeProbe = async (w) => {
    let value;
    const native = await untilSnapshot("native sidebar drag state", async (s) => {
      value = await run(`return globalThis.expo.modules.SolaraSidebarDrag?.startProbe(${JSON.stringify(w)}).then((t) => JSON.parse(t)) ?? null;`);
      const current = nativeWindow(s, w)?.sidebarDrag;
      return value === null ? current === null : current && ["active", "external", "gapKey", "pitch", "escaping", "landed", "folderPanel", "lastDrop"].every((key) => isDeepStrictEqual(current[key], value[key]));
    }, 5000, { windowId: w, fields: ["windows.sidebarDrag"] });
    const current = nativeWindow(native, w).sidebarDrag;
    if (value) {
      for (const key of ["active", "external", "gapKey", "pitch", "escaping", "landed", "folderPanel", "lastDrop"]) assert.deepEqual(current[key], value[key], key);
      for (const item of value.items) {
        const found = current.items.find((i) => i.key === item.key);
        assert.ok(found, item.key);
        for (const key of ["tabIds", "kind", "section", "parentGroup", "groupId", "folderId"]) assert.deepEqual(found[key], item[key], `${item.key}.${key}`);
        for (const key of ["x", "y", "w", "h"]) assert.ok(Math.abs(found[key] - item[key]) <= 0.5, `${item.key}.${key}`);
      }
    }
    return value;
  };
  const rowIn = (w, id) => nativeProbe(w).then((p) => p.items.filter((i) => i.kind === "row").map((i) => ({ id: i.tabIds[0], x: i.x, y: i.y, w: i.w, h: i.h })).find((r) => r.id === id));
  const live = async () => {
    let value;
    const native = await untilSnapshot("native drag ownership and focus", async (s) => {
      value = await run(`const s = st(); return { focused: s.ui.focusedWindowId, windows: Object.keys(s.windows), tabs: Object.fromEntries(Object.entries(s.tabs).map(([id, t]) => [id, t.windowId])), dragging: globalThis.acTabDrag.getState().tabIds.length };`);
      return s.focusedWindowId === value.focused && s.tabDrag.tabIds.length === value.dragging;
    });
    assert.equal(native.focusedWindowId, value.focused);
    assert.deepEqual(native.windows.map((w) => w.id).sort(), value.windows.slice().sort());
    assert.deepEqual(Object.fromEntries(native.tabs.map((t) => [t.id, t.windowId])), value.tabs);
    assert.equal(native.tabDrag.tabIds.length, value.dragging);
    return value;
  };
  const closeAll = () => run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); return settle(900);`);

  await check("sidebar: a row let go over another window that covers its own lands in the window on top", async () => {
    const [wa, wb, ia] = await twoWindows([100, 60, 560, 420], [400, 100, 560, 420]);
    try {
      const row = await rowIn(wa, ia);
      assert.ok(row && row.w > 0, `a row for ${ia}`);
      const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
      await run(`return act(${JSON.stringify(wa)}, "drag:${sx},${sy};${sx + 10},${sy + 6};400,200;450,200;452,202;450,200").then(() => settle(1600));`);
      const after = await live();
      assert.equal(after.tabs[ia], wb, `${ia} moved into the covering window: ${JSON.stringify(after.tabs)}`);
    } finally {
      await closeAll();
    }
  });

  await check("sidebar: a drag over a window that closes before the drop leaves the tab in a live window, and focus on one", async () => {
    const [wa, wb, , ib] = await twoWindows([100, 60, 560, 420], [700, 60, 560, 420]);
    try {
      const row = await rowIn(wb, ib);
      assert.ok(row && row.w > 0, `a row for ${ib}`);
      const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
      const tx = 90 - 600;
      await run(`setTimeout(() => st().closeWindow(${JSON.stringify(wa)}), 900);
        return act(${JSON.stringify(wb)}, "drag:${sx},${sy};${sx + 10},${sy + 6};-60,${sy};${tx},${sy};${tx + 2},${sy + 2};${tx},${sy};${tx + 1},${sy}").then(() => settle(1800));`);
      const after = await live();
      assert.ok(!after.windows.includes(wa), "the target closed");
      assert.ok(after.windows.includes(after.tabs[ib]), `${ib} is in a live window: ${JSON.stringify(after)}`);
      assert.ok(after.windows.includes(after.focused), `focus is on a live window: ${JSON.stringify(after)}`);
      assert.equal(after.dragging, 0, "no drag left");
    } finally {
      await closeAll();
    }
  });

  await check("sidebar: a drag whose own window closes mid-drag ends, and nothing stays captured", async () => {
    const [, wb, , ib] = await twoWindows([100, 60, 560, 420], [700, 60, 560, 420]);
    try {
      const row = await rowIn(wb, ib);
      assert.ok(row && row.w > 0, `a row for ${ib}`);
      const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
      await run(`setTimeout(() => st().closeWindow(${JSON.stringify(wb)}), 500);
        act(${JSON.stringify(wb)}, "drag:${sx},${sy};${sx + 10},${sy + 6};${sx + 10},${sy + 60};${sx + 10},${sy + 120};${sx + 10},${sy + 180}").catch(() => {});
        return settle(2200);`);
      const after = await live();
      assert.ok(!after.windows.includes(wb), "the source closed");
      assert.equal(after.dragging, 0, "no drag left");
      let preview;
      const nativePreview = await untilSnapshot("native drag picture gone", async (s) => {
        preview = await run(`return globalThis.expo.modules.SolaraShell.devDragPreviewState();`);
        assert.equal(preview.visible, false, "no drag picture left");
        return s.dragPreview.visible === preview.visible;
      });
      assert.equal(nativePreview.dragPreview.visible, preview.visible);
      assert.equal((await nativeProbe("w1"))?.escaping, false, "Esc is no longer captured");
    } finally {
      await closeAll();
    }
  });

  await check("sidebar: a drag pulled back from the page and let go at once in the sidebar opens no window", async () => {
    await run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); st().updateSettings({ tabLayout: "sidebar" }); return settle(1200);`);
    const rows = await run(`return Promise.all([...globalThis.sidebarDrags.w1.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], ids: i.tabIds, x, y, w, h })))));`);
    const row = rows.filter((r) => r.ids.length === 1).sort((a, b) => a.y - b.y).at(-1);
    assert.ok(row, JSON.stringify(rows));
    const before = await live();
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
    const page = Math.round(row.x + row.w + 200), back = Math.round(row.x + row.w - 10);
    const seen = await run(`const seen = []; const iv = setInterval(() => { const d = globalThis.acTabDrag.getState(); seen.push([Math.round(d.x), Math.round(d.y), d.outside, d.overWindow, d.onPage].join()); }, 20);
      return act("w1", "drag:${sx},${sy};${sx + 10},${sy + 6};${page},400;${page + 2},404;${page},406;${back},${sy}").then(() => settle(1600)).then(() => { clearInterval(iv); return [...new Set(seen)]; });`);
    const after = await live();
    const lastDrop = (await nativeProbe("w1"))?.lastDrop ?? null;
    await closeAll();
    assert.equal(after.windows.length, before.windows.length, `no new window: ${JSON.stringify({ row, windows: after.windows, seen, lastDrop })}`);
    assert.equal(after.tabs[row.id], "w1", `${row.id} stayed: ${JSON.stringify(after.tabs)}`);
    assert.equal(after.dragging, 0, "no drag left");
  });

  await check("sidebar: a split drop whose end reply comes late commits once, or not at all", async () => {
    await run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); st().updateSettings({ tabLayout: "sidebar" });
      for (let i = 0; i < 3; i++) st().newTab("w1", { url: "data:text/html,late" + i, background: true });
      return settle(1500);`);
    const free = await run(`const s = st(); const w = s.windows.w1; const split = new Set(Object.values(s.splits).flatMap((v) => v.tabIds));
      return w.tabIds.filter((id) => !split.has(id) && id !== w.activeTabIds[w.profileId]);`);
    const probe = await nativeProbe("w1");
    const rows = probe.items.filter((i) => i.kind === "row" && i.tabIds.length === 1 && free.includes(i.tabIds[0]));
    assert.ok(rows.length >= 3, JSON.stringify({ free, rows: rows.map((r) => r.tabIds) }));
    const dropLate = async (row, delay) => {
      const before = await live();
      const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
      const left = Math.round(row.x + row.w + 140);
      await run(`globalThis.acTabDragEndDelay = ${delay};
        return act("w1", "drag:${sx},${sy};${sx + 40},${sy + 20};${left},380;${left + 4},390;${left + 6},396;${left + 6},398").then(() => settle(${Math.max(2800, delay + 1200)})).finally(() => { globalThis.acTabDragEndDelay = 0; });`);
      const after = await live();
      const splits = await run(`return Object.values(st().splits).filter((v) => v.tabIds.includes(${JSON.stringify(row.tabIds[0])})).length;`);
      const lastDrop = (await nativeProbe("w1"))?.lastDrop ?? null;
      return { id: row.tabIds[0], before, after, splits, lastDrop };
    };
    const inTime = await dropLate(rows[0], 1200);
    assert.equal(inTime.splits, 1, `a reply in time splits once: ${JSON.stringify(inTime)}`);
    assert.equal(inTime.after.windows.length, inTime.before.windows.length, `and opens no window: ${JSON.stringify(inTime)}`);
    assert.equal(inTime.after.tabs[inTime.id], "w1");
    const late = await dropLate(rows[1], 1700);
    assert.ok(late.splits <= 1, `a late reply splits at most once: ${JSON.stringify(late)}`);
    assert.equal(late.after.windows.length, late.before.windows.length, `and opens no window: ${JSON.stringify(late)}`);
    assert.equal(late.after.tabs[late.id], "w1");
    assert.equal(late.after.dragging, 0, "no drag left");
    const timedOut = await dropLate(rows[2], 2600);
    assert.ok(timedOut.splits <= 1, `a reply after native's deadline splits at most once: ${JSON.stringify(timedOut)}`);
    assert.equal(timedOut.after.windows.length, timedOut.before.windows.length, `and opens no window: ${JSON.stringify(timedOut)}`);
    assert.equal(timedOut.after.tabs[timedOut.id], "w1");
    assert.equal(timedOut.after.dragging, 0, "no drag left");
  });

  await check("sidebar: Esc and the release in the same moment end the drag once, and the next drag still works", async () => {
    await run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); for (let i = 0; i < 3; i++) st().newTab("w1", { background: true }); return settle(1500);`);
    const rows = await run(`return Promise.all([...globalThis.sidebarDrags.w1.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], ids: i.tabIds, x, y, w, h })))));`);
    const loose = rows.filter((r) => r.ids.length === 1).sort((a, b) => a.y - b.y);
    assert.ok(loose.length >= 3, JSON.stringify(rows));
    const [a, b] = loose;
    const before = await live();
    const ax = Math.round(a.x + a.w / 2), ay = Math.round(a.y + a.h / 2);
    const to = Math.round(b.y + b.h * 0.8);
    await run(`setTimeout(() => ac.shell.devTypeKeys("key", "\\u001b", 0), ${150 + 16 * 12 * 2});
      return act("w1", "drag:${ax},${ay};${ax},${ay + 10};${ax},${to}").then(() => settle(1600));`);
    const after = await live();
    assert.equal(after.windows.length, before.windows.length, "no new window");
    assert.equal(after.dragging, 0, "no drag left");
    {
      const probe = await nativeProbe("w1");
      assert.equal(probe?.escaping, false, "Esc is no longer captured");
      assert.equal(probe?.active, false, "the sidebar isn't dragging");
    }
    const order = await run(`return st().windows.w1.tabIds;`);
    const fresh = await run(`return Promise.all([...globalThis.sidebarDrags.w1.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], ids: i.tabIds, x, y, w, h })))));`);
    const [c, d] = fresh.filter((r) => r.ids.length === 1).sort((x, y) => x.y - y.y);
    const cx = Math.round(c.x + c.w / 2), cy = Math.round(c.y + c.h / 2);
    await run(`return act("w1", "drag:${cx},${cy};${cx},${cy + 10};${cx},${Math.round(d.y + d.h * 0.8)}").then(() => settle(1600));`);
    assert.notDeepEqual(await run(`return st().windows.w1.tabIds;`), order, "the next drag reordered");
  });

  const sidebarRows = () => run(`return Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], ids: i.tabIds, x, y, w, h })))));`);
  const looseRow = () => run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id);
    for (const v of Object.values(st().splits)) st().separateSplit(v.id);
    st().newTab("w1", { url: "data:text/html,<title>xo</title>xo", background: true }); st().newTab("w1", { url: "data:text/html,<title>xp</title>xp", background: true });
    return settle(1500);`).then(sidebarRows).then((rows) => rows.filter((r) => r.ids.length === 1).sort((a, b) => a.y - b.y));

  await check("sidebar: a row dragged out of the window shows its picture there and tears off into a new one", async () => {
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1500);`);
    const rows = await looseRow();
    const row = rows.at(-1);
    assert.ok(row && row.w > 0, JSON.stringify(rows));
    const windows = await run(`return Object.keys(st().windows).length;`);
    const frame = await run(`return st().windows.w1.frame;`);
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
    const seen = await watch("w1", `${sx},${sy};${sx + 10},${sy + 6};${sx},-40;${sx + 80},-90`, 1400);
    const outside = seen.filter((p) => p.shape === "card");
    assert.ok(outside.length, "a card outside the window");
    assert.ok(outside.some((p) => p.frame[1] + p.frame[3] / 2 > frame[1] + frame[3]), JSON.stringify(outside.at(-1)));
    assert.ok(seen.some((p) => p.visible && p.frame[2] === frame[2] && p.frame[3] === frame[3]), "grew to the new window");
    assert.equal(seen.at(-1).visible, false, "gone after the drop");
    const after = await run(`return Object.keys(st().windows).map(loose);`);
    assert.equal(after.length, windows + 1, JSON.stringify(after));
    assert.ok(after.some((ids) => ids.length === 1 && ids[0] === row.id), JSON.stringify({ row, after }));
  });

  await check("sidebar: a row let go over the page away from a target opens in a window of its own", async () => {
    const rows = await looseRow();
    const row = rows.at(-1);
    assert.ok(row && row.w > 0, JSON.stringify(rows));
    const windows = await run(`return Object.keys(st().windows).length;`);
    const splits = await run(`return Object.values(st().splits).map((v) => v.tabIds);`);
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
    const px = Math.round(row.x + row.w + 160);
    const seen = await watch("w1", `${sx},${sy};${sx + 10},${sy + 6};${px},560;${px},740`, 1400);
    assert.ok(seen.some((p) => p.shape === "card" && p.frame[2] === 209 && p.frame[3] === 110), `a 209 × 110 card: ${JSON.stringify(seen.at(-1))}`);
    assert.equal(seen.at(-1).visible, false, "gone after the drop");
    const after = await run(`return Object.keys(st().windows).map(loose);`);
    assert.equal(after.length, windows + 1, JSON.stringify(after));
    assert.ok(after.some((ids) => ids.length === 1 && ids[0] === row.id), JSON.stringify({ row, after }));
    assert.deepEqual(await run(`return Object.values(st().splits).map((v) => v.tabIds);`), splits);
  });

  await check("sidebar: a row dragged onto the page's left target splits", async () => {
    await run(`for (const id of Object.keys(st().windows)) if (id !== "w1") st().closeWindow(id); st().updateSettings({ tabLayout: "sidebar" }); return settle(1500);`);
    const rows = await run(`const c = globalThis.sidebarDrag; const out = [];
      return Promise.all([...c.items.values()].filter((i) => i.kind === "row" && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], x, y, w, h })))));`);
    const row = rows.find((r) => r.id === "t2") ?? rows[0];
    assert.ok(row, "a sidebar row");
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
    const left = Math.round(row.x + row.w + 140);
    const state = await run(`
      const seen = [];
      const iv = setInterval(() => { const d = globalThis.acTabDrag.getState(); seen.push(d.target); }, 60);
      return act("w1", "drag:${sx},${sy};${sx + 40},${sy + 20};${left},380;${left + 4},390;${left + 6},396;${left + 6},398").then(() => settle(1700)).then(() => { clearInterval(iv); return seen; });`);
    assert.ok(state.some((t) => t?.side === "left"), `left target ${JSON.stringify(state.slice(-5))}`);
    const splits = await run(`return Object.values(st().splits).map((v) => v.tabIds);`);
    assert.ok(splits.some((ids) => ids[0] === row.id), JSON.stringify(splits));
  });
  await check("sidebar: nothing moves as a drag starts or ends (the pin target takes no room)", async () => {
    const rows = () => run(`return Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => (i.kind === "row" || i.kind === "group") && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r([i.key, x, y, w, h])))));`);
    await run(`const pinned = st().windows.w1.tabIds.filter((id) => st().tabs[id].pinned); if (pinned.length) st().placeTabs(pinned, { pinned: false, beforeId: null }); return settle(800);`);
    const start = (await rows()).sort((a, b) => a[2] - b[2]);
    const top = start.find(([key]) => key.startsWith("t:"));
    assert.ok(top, JSON.stringify(start));
    const [key, x, y, w, h] = top;
    const sx = Math.round(x + w / 2), sy = Math.round(y + h / 2);
    const during = await run(`act("w1", "drag:${sx},${sy};${sx},${sy + 8};${sx},${sy + 8};${sx},${sy + 8};${sx},${sy + 8}");
      return settle(150 + 12 * 16 * 2 + 150).then(() => Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => (i.kind === "row" || i.kind === "group") && i.view && i.key !== ${JSON.stringify(key)}).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r([i.key, x, y, w, h]))))))
        .then((rows) => ({ rows, ghost: !!globalThis.sidebarDrag.active, zone: !!globalThis.sidebarDrag.regions.get("tiles") }));`);
    await run(`return settle(1500);`);
    const end = await rows();
    const at = (list) => Object.fromEntries(list.map(([k, x, y]) => [k, [x, y]]));
    const [s0, s1, s2] = [at(start), at(during.rows), at(end)];
    assert.ok(during.ghost, "dragging when measured");
    assert.ok(during.zone, "the pin target showed");
    for (const k of Object.keys(s1)) {
      assert.ok(Math.abs(s1[k][1] - s0[k][1]) < 0.5 && Math.abs(s1[k][0] - s0[k][0]) < 0.5, `${k} moved during the drag: ${s0[k]} -> ${s1[k]}`);
    }
    for (const k of Object.keys(s0)) {
      assert.ok(s2[k] && Math.abs(s2[k][1] - s0[k][1]) < 0.5, `${k} moved after the drag: ${s0[k]} -> ${s2[k]}`);
    }
  });

  await check("sidebar: a row let go between two others settles into its place, where the row then is", async () => {
    await run(`st().newTab("w1"); st().newTab("w1"); st().newTab("w1"); return settle(1200);`);
    const rows = await run(`return Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], x, y, w, h })))));`);
    rows.sort((a, b) => a.y - b.y);
    assert.ok(rows.length >= 3, JSON.stringify(rows));
    const row = rows[0];
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2);
    const to = Math.round(rows[1].y + rows[1].h * 0.8);
    const out = await run(`const c = globalThis.sidebarDrag; c.landed = null;
      return act("w1", "drag:${sx},${sy};${sx},${sy + 10};${sx},${to}").then(() => settle(1500)).then(() => {
        const l = c.landed; const it = l && c.items.get(l.key);
        return new Promise((r) => (it ? it.view.measureInWindow((x, y) => r({ landed: l, row: { x, y } })) : r({ landed: l })));
      });`);
    assert.equal(out.landed?.key, `t:${row.id}`, JSON.stringify({ out, row, rows, probe: await nativeProbe("w1").then((p) => p && { active: p.active, escaping: p.escaping, landed: p.landed, n: p.items.length }), live: await live(), keys: await run(`return Object.keys(globalThis.sidebarDrags ?? {});`) }));
    assert.ok(Math.abs(out.landed.x - out.row.x) < 0.5 && Math.abs(out.landed.y - out.row.y) < 0.5, JSON.stringify(out));
  });

  await check("sidebar auto-hidden: a row dragged within the peeking sidebar reorders instead of splitting, and Esc cancels a drag", async () => {
    const PEEKING = `(!!globalThis.acLayout.peek.w1?.live || "w1" in globalThis.acLayout.dockMotion.getState().peeks)`;
    const edge = (p) => run(`return ac.shell.devLeftEdgePointer("w1", ${JSON.stringify(p)}).then(() => settle(500)).then(() => ${PEEKING});`);
    await run(`for (const v of Object.values(st().splits)) st().separateSplit(v.id); if (st().windows.w1.sidebarOpen) st().toggleSidebar("w1"); return settle(900);`);
    try {
      await edge({ x: -4, y: 300 });
      assert.equal(await edge({ x: 120, y: 300 }), true, "the sidebar peeks");
      const rows = (await run(`return Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => i.kind === "row" && !i.parentGroup && i.section === "list" && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], x, y, w, h })))));`))
        .filter((r) => r.x > 0).sort((a, b) => a.y - b.y);
      assert.ok(rows.length >= 3, JSON.stringify(rows));
      const [a, , c] = rows;
      const sx = Math.round(a.x + a.w / 2), sy = Math.round(a.y + a.h / 2), to = Math.round(c.y + c.h * 0.85);
      const before = await order("w1");
      const seen = await run(`const seen = []; const iv = setInterval(() => { const d = globalThis.acTabDrag.getState(); if (d.tabIds.length) seen.push([d.onPage, d.target]); }, 40);
        return act("w1", "drag:${sx},${sy};${sx},${sy + 10};${sx},${to};${sx},${to}").then(() => settle(1600)).then(() => { clearInterval(iv); return seen; });`);
      assert.deepEqual(await run(`return Object.values(st().splits).map((v) => v.tabIds);`), [], "no split");
      assert.ok(seen.every(([onPage, target]) => !onPage && !target), `no page target under the sidebar: ${JSON.stringify(seen.slice(-3))}`);
      const after = await order("w1");
      assert.ok(after.indexOf(a.id) > after.indexOf(c.id), `${a.id} moved below ${c.id}: ${before} -> ${after}`);
      assert.equal(await run(`return ${PEEKING};`), true, "the sidebar stayed out");
      const hold = Array.from({ length: 6 }, () => `${sx},${to}`).join(";");
      const cancelled = await run(`setTimeout(() => ac.shell.devTypeKeys("key", "\\u001b", 0), ${150 + 16 * 12 * 2 + 200});
        let ended = null; const t0 = performance.now();
        const stop = globalThis.acTabDrag.subscribe((d, was) => { if (was.tabIds.length && !d.tabIds.length && ended === null) ended = performance.now() - t0; });
        return act("w1", "drag:${sx},${sy};${sx},${sy + 10};${sx},${to};${hold}").then(() => settle(${150 + 16 * 12 * 8 + 600})).then(() => { stop(); return { ended, order: st().windows.w1.tabIds }; });`);
      assert.deepEqual(cancelled.order, after, "Esc: nothing moved");
      assert.ok(cancelled.ended !== null && cancelled.ended < 150 + 16 * 12 * 7, `Esc ended the drag before the release: ${cancelled.ended}`);
      assert.equal(await edge({ x: 800, y: 400 }), false, "it hides once the pointer leaves");
    } finally {
      await run(`return ac.shell.devLeftEdgePointer("w1", null).then(() => { if (!st().windows.w1.sidebarOpen) st().toggleSidebar("w1"); return settle(900); });`);
    }
  });

  await check("sidebar: the empty room under the rows moves the window, and a double-click there still opens a tab", async () => {
    const x = 120, height = await run(`return st().windows.w1.frame[3];`);
    const emptyRoom = /^(\S*WindowDragRegion|SolaraUI\.SidebarDocumentView)\b/;
    let y = height - 140;
    while (y < height - 60 && !emptyRoom.test(await run(`return win("w1").then((n) => C.devWindow(n, "hit:${x},${y}"));`))) y += 10;
    const nativeHit = await nativeSnapshot({ windowId: "w1", dragPoints: [{ x, y }], fields: ["windows.dragPoints"] });
    const result = await run(`
      return win("w1").then((n) => {
        const frame = () => C.chromeWindows().then((ws) => ws.find((w) => w.window === n).frame);
        const click = (count) => C.devWindow(n, "mouse:down:${x},${y}," + count).then(() => settle(30)).then(() => C.devWindow(n, "mouse:up:${x},${y}," + count)).then(() => settle(60));
        const out = { tabs: st().windows.w1.tabIds.length };
        return C.devWindow(n, "hit:${x},${y}").then((h) => { out.hit = h; return C.devWindow(n, "windowDrags"); })
          .then(() => click(1)).then(() => settle(300))
          .then(() => C.devWindow(n, "windowDrags")).then((d) => { out.drags = Number(d.split("\\n")[0]); return frame(); })
          .then((f) => { out.before = f; return click(1).then(() => click(2)); }).then(() => settle(900)).then(frame)
          .then((f) => { out.after = f; out.opened = st().windows.w1.tabIds.length - out.tabs; return out; });
      });`);
    assert.match(result.hit, emptyRoom, "the empty sidebar is the drag region's");
    assert.equal(nativeWindow(nativeHit, "w1").dragPoints[0].hit, result.hit, "native empty sidebar hit chain beside JS");
    assert.equal(result.drags, 1, "a press there drags the window");
    assert.equal(result.opened, 1, "a double-click opens a tab");
    assert.equal(result.after, result.before, "and doesn't zoom the window");
  });

  const SIDEBAR_ROWS = `return Promise.all([...globalThis.sidebarDrag.items.values()].filter((i) => i.kind === "row" && i.section === "list" && !i.parentGroup && i.view).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ id: i.tabIds[0], x, y, w, h }))))).then((l) => l.filter((i) => i.w > 0).sort((a, b) => a.y - b.y));`;
  const FOLDERS = `const c = globalThis.sidebarDrag;
    const cells = () => Promise.all([...c.items.values()].filter((i) => i.view && (i.kind === "tile" || i.section === "folder")).map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ key: i.key, section: i.section, folder: i.folderId ?? null, id: i.tabIds[0], x, y, w, h }))))).then((l) => l.filter((i) => i.w > 0).sort((a, b) => a.y - b.y || a.x - b.x));
    const folderOf = (id) => st().tabs[id]?.tileFolder?.id ?? null;`;
  const centre = (cell) => [Math.round(cell.x + cell.w / 2), Math.round(cell.y + cell.h / 2)];
  const panelRows = () => nativeProbe("w1").then((p) => p.items.filter((i) => i.section === "folder" && i.kind === "row").map((i) => ({ id: i.tabIds[0], x: i.x, y: i.y, w: i.w, h: i.h })));
  const panelOpen = () => nativeProbe("w1").then((p) => p.folderPanel != null);
  const held = (points, n) => [...points, ...Array(n).fill(points.at(-1))];
  let folderTabs = [];

  await check("sidebar: a tile held over another tile's centre makes a folder of the two there, as on iOS", async () => {
    folderTabs = await run(`const ids = ["fa", "fb", "fc"].map((n) => st().newTab("w1", { url: "data:text/html,<title>" + n + "</title>" + n, background: true })); st().pinTabs(ids, true); return settle(1000).then(() => ids);`);
    const [a, , cc] = folderTabs;
    const tiles = await run(`${FOLDERS} return cells();`);
    const from = tiles.find((t) => t.id === a);
    const onto = tiles.find((t) => t.id === cc);
    assert.ok(from && onto, JSON.stringify(tiles));
    const order = tiles.filter((t) => t.id !== a).map((t) => (t.id === cc ? "folder" : t.key));
    const passing = await run(`${FOLDERS} const seen = []; const iv = setInterval(() => seen.push(c.marks.getState().folderTarget), 40);
      return act("w1", "windowDrags").then(() => act("w1", "drag:${held([centre(from), [centre(from)[0] + 10, centre(from)[1]], [centre(onto)[0] - 14, centre(onto)[1]], centre(onto)], 5).map((p) => p.join(",")).join(";")}"))
        .then(() => settle(2400)).then(() => { clearInterval(iv); return seen; });`);
    assert.ok(passing.includes(`t:${cc}`), `the target is marked while held: ${JSON.stringify([...new Set(passing)])}`);
    const [fa, fc] = await run(`${FOLDERS} return [folderOf(${JSON.stringify(a)}), folderOf(${JSON.stringify(cc)})];`);
    assert.ok(fa && fa === fc, `one folder: ${fa} ${fc}`);
    const after = await run(`${FOLDERS} return cells();`);
    const folder = after.find((t) => t.folder === fa);
    assert.ok(folder, "a folder tile");
    assert.deepEqual(after.filter((t) => t.section === "tiles").map((t) => (t.folder ? "folder" : t.key)), order, "in the target's place");
    const row = after.filter((t) => t.section === "tiles" && Math.abs(t.y - folder.y) < 2).sort((p, q) => p.x - q.x);
    row.slice(1).forEach((t, i) => assert.equal(t.x - (row[i].x + row[i].w), 6, `6 pt gaps: ${JSON.stringify(row.map((r) => [r.x, r.w]))}`));
  });

  await check("sidebar: a tile let go on a folder joins it at once; passing over a tile's edge only reorders", async () => {
    const [a, b] = folderTabs;
    const tiles = await run(`${FOLDERS} return cells();`);
    const from = tiles.find((t) => t.id === b);
    const folder = tiles.find((t) => t.folder && t.folder === tiles.find((x) => x.folder)?.folder);
    assert.ok(from && folder, JSON.stringify(tiles));
    await drag("w1", held([centre(from), [centre(from)[0] + 10, centre(from)[1]], centre(folder)], 1));
    const ids = await run(`${FOLDERS} return [folderOf(${JSON.stringify(a)}), folderOf(${JSON.stringify(b)})];`);
    assert.ok(ids[0] && ids[0] === ids[1], `b joined: ${JSON.stringify(ids)}`);
  });

  await check("sidebar: members dragged out of the folder's panel leave it, and the last one left turns back into a tile", async () => {
    const [a, b, cc] = folderTabs;
    const folderId = await run(`${FOLDERS} return folderOf(${JSON.stringify(cc)});`);
    for (const id of [a, b]) {
      const tile = (await run(`${FOLDERS} return cells();`)).find((t) => t.folder === folderId);
      await run(`return act("w1", "click:${centre(tile).join(",")}").then(() => settle(700));`);
      const rows = await panelRows();
      const member = rows.find((r) => r.id === id);
      assert.ok(member, `the panel lists it: ${JSON.stringify(rows.map((r) => r.id))}`);
      const below = Math.max(...rows.map((r) => r.y + r.h)) + 24;
      const second = (await run(`${SIDEBAR_ROWS}`)).find((r) => r.y > below);
      assert.ok(second, "a list row below the panel");
      await drag("w1", [[member.x + 60, member.y + 17], [member.x + 60, member.y + 26], [second.x + 60, second.y + 30], [second.x + 60, second.y + 8], [second.x + 60, second.y + 3]]);
      const state = await run(`${FOLDERS} const id = ${JSON.stringify(id)}; const w = st().windows.w1.tabIds; return { folder: folderOf(id), pinned: st().tabs[id].pinned, grouped: Object.values(st().groups).some((g) => g.tabIds.includes(id)), next: w[w.indexOf(id) + 1], order: w.map((x) => [x, st().tabs[x].pinned, st().tabs[x].url.slice(0, 30)]) };`);
      const { order, ...seen } = { ...state, panel: await panelOpen() };
      assert.deepEqual(seen, { folder: null, pinned: false, grouped: false, next: second.id, panel: false }, `${id} left the folder for the list, before ${second.id}: ${JSON.stringify(order)}`);
    }
    assert.equal(await run(`${FOLDERS} return folderOf(${JSON.stringify(cc)});`), null, "a folder of one is a tile again");
    assert.ok(await run(`return st().tabs[${JSON.stringify(cc)}].pinned;`), "still pinned");
    await run(`st().pinTabs(${JSON.stringify(folderTabs)}, false); st().closeTabs(${JSON.stringify(folderTabs)}); return settle(900);`);
  });

  await check("sidebar: a folder tile dragged along the grid takes one slot: no row moves and the grid doesn't grow", async () => {
    const made = await run(`const ids = ["ga", "gb", "gc", "gd", "ge"].map((n) => st().newTab("w1", { url: "data:text/html,<title>" + n + "</title>" + n, background: true }));
      const others = st().windows.w1.tabIds.filter((id) => st().tabs[id].pinned && !ids.includes(id)); st().pinTabs(others, false);
      st().pinTabs(ids, true); st().placeTabs(ids.slice(0, 3), { pinned: true, row: false, beforeId: ids[3], tileFolder: { id: "tf-drag", name: "Drag" } });
      return settle(1000).then(() => ({ ids, others }));`);
    try {
      const tiles = (await run(`${FOLDERS} return cells();`)).filter((t) => t.section === "tiles");
      assert.equal(tiles.length, 3, JSON.stringify(tiles));
      assert.ok(tiles.every((t) => t.y === tiles[0].y), "one row");
      const folder = tiles.find((t) => t.folder === "tf-drag");
      const last = tiles.at(-1);
      const seen = await run(`${FOLDERS} const seen = []; const grid = () => new Promise((r) => c.regions.get("tiles").measureInWindow((x, y, w, h) => r(h)));
        const iv = setInterval(() => Promise.all([cells(), grid()]).then(([l, h]) => seen.push({ count: c.marks.getState().pinCount, h, ys: l.filter((t) => t.section === "tiles" && !c.marks.getState().sources.has(t.key)).map((t) => t.y) })), 30);
        return act("w1", "windowDrags").then(() => act("w1", "drag:${[centre(folder), [centre(folder)[0] + 8, centre(folder)[1]], [last.x + last.w - 4, centre(folder)[1]], [last.x + last.w - 3, centre(folder)[1]]].map((p) => p.join(",")).join(";")}"))
          .then(() => settle(1400)).then(() => { clearInterval(iv); return seen; });`);
      const during = seen.filter((x) => x.count > 0);
      assert.ok(during.length, "the drag reserved a slot");
      assert.deepEqual([...new Set(during.map((x) => x.count))], [1], "one slot for the folder");
      assert.deepEqual([...new Set(seen.flatMap((x) => x.ys))], [tiles[0].y], `no tile leaves the row: ${JSON.stringify(seen.slice(-3))}`);
      assert.deepEqual([...new Set(seen.map((x) => x.h))], [tiles[0].h], "the grid keeps its height");
      const after = (await run(`${FOLDERS} return cells();`)).filter((t) => t.section === "tiles");
      assert.equal(after.at(-1).folder, "tf-drag", "the folder went to the end, still a folder");
    } finally {
      await run(`st().pinTabs(${JSON.stringify(made.ids)}, false); st().closeTabs(${JSON.stringify(made.ids)}); st().pinTabs(${JSON.stringify(made.others)}, true); return settle(900);`);
    }
  });

  const drops = join(scratch, "drops");
  mkdirSync(drops, { recursive: true });
  const crc = (buf) => { let c = ~0; for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return ~c >>> 0; };
  const chunk = (type, body) => { const head = Buffer.alloc(8); head.writeUInt32BE(body.length); head.write(type, 4, "ascii"); const tail = Buffer.alloc(4); tail.writeUInt32BE(crc(Buffer.concat([Buffer.from(type, "ascii"), body]))); return Buffer.concat([head, body, tail]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(8, 0); ihdr.writeUInt32BE(8, 4); ihdr[8] = 8; ihdr[9] = 2;
  const pixels = Buffer.alloc(8 * (1 + 8 * 3), 0x7f); for (let y = 0; y < 8; y++) pixels[y * 25] = 0;
  const file = (name, body) => { const path = join(drops, name); writeFileSync(path, body); return path; };
  const pdf = file("drop test.pdf", "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");
  const png = file("drop.png", Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0))]));
  const plist = (url) => `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${url}</string></dict></plist>\n`;
  const badLink = file("bad.webloc", plist("javascript:alert(1)"));
  const goodLink = file("good.webloc", plist("https://example.com/from-webloc"));
  const download = file("downloaded.pdf", readFileSync(pdf));
  const fileUrl = (path) => "file://" + path.split("/").map(encodeURIComponent).join("/");

  const SIDEBAR = `const c = globalThis.sidebarDrag;
    const measured = () => Promise.all([...c.items.values()].filter((i) => i.view && i.kind !== "tail").map((i) => new Promise((r) => i.view.measureInWindow((x, y, w, h) => r({ key: i.key, kind: i.kind, id: i.tabIds[0], group: i.parentGroup ?? null, section: i.section, x, y, w, h }))))).then((l) => l.filter((i) => i.w > 0).sort((a, b) => a.y - b.y || a.x - b.x));`;
  const listRows = () => run(`${SIDEBAR} return measured().then((l) => l.filter((i) => i.kind === "row" && i.section === "list" && !i.group));`);
  const fileDrop = (points, payload) => run(`${SIDEBAR}
    const FD = ac.shell.devFileDrag; const log = []; let during = null;
    const pts = ${JSON.stringify(points)};
    const before = new Set(Object.keys(st().tabs));
    const step = (i) => i >= pts.length ? Promise.resolve() : (i === pts.length - 1 ? Promise.resolve(during = { gapKey: c.gapKey, pitch: c.pitch, external: c.external, pins: c.marks.getState().pins, dropInto: c.marks.getState().dropInto }) : Promise.resolve())
      .then(() => FD.drag("w1", i === pts.length - 1 ? "drop" : "move", pts[i][0], pts[i][1], i === 0 ? ${JSON.stringify(payload)} : undefined))
      .then((r) => { log.push(r); return settle(i === 0 ? 500 : 150); }).then(() => step(i + 1));
    return step(0).then(() => settle(900)).then(() => {
      const w = st().windows.w1;
      return { log, during, active: w.activeTabIds[w.profileId], order: w.tabIds, after: c.external,
        added: w.tabIds.filter((id) => !before.has(id)).map((id) => ({ id, url: st().tabs[id].url, pinned: !!st().tabs[id].pinned, group: Object.values(st().groups).find((g) => g.tabIds.includes(id))?.id ?? null })) };
    });`);
  const closeAdded = (out) => run(`st().closeTabs(${JSON.stringify(out.added.map((a) => a.id))}); return settle(700);`);

  await check("file drop: a PDF dropped between two sidebar rows opens there, behind the same drop gap as a tab drag", async () => {
    const rows = await listRows();
    assert.ok(rows.length >= 3, JSON.stringify(rows));
    const [, b] = rows;
    const x = Math.round(b.x + b.w / 2), y = Math.round(b.y + 3);
    const out = await fileDrop([[x, y + 8], [x, y + 2], [x, y]], { files: [pdf] });
    assert.match(out.log[0], /(FileDropView|SidebarShellColumn) 1$/, `the sidebar takes the drag: ${out.log}`);
    assert.match(out.log.at(-1), /(FileDropView|SidebarShellColumn) performed/, out.log.join(" | "));
    assert.equal(out.during?.gapKey, b.key, `gap before ${b.key}: ${JSON.stringify(out.during)}`);
    assert.ok(out.during.pitch > 0, "the gap opens");
    assert.equal(out.after, 0, "the drag ended");
    assert.equal(out.added.length, 1, JSON.stringify(out.added));
    assert.equal(out.added[0].url, fileUrl(pdf));
    assert.equal(out.order[out.order.indexOf(b.id) - 1], out.added[0].id, "right before the row it was dropped on");
    assert.equal(out.active, out.added[0].id, "and selected");
    await closeAdded(out);
  });

  await check("file drop: at the top of the list, and at its end", async () => {
    const rows = await listRows();
    const first = rows[0], last = rows.at(-1);
    const x = Math.round(first.x + first.w / 2);
    const top = await fileDrop([[x, first.y + 3], [x, first.y + 2]], { files: [png] });
    assert.equal(top.added.length, 1, JSON.stringify(top));
    assert.equal(top.added[0].url, fileUrl(png));
    assert.equal(top.order[top.order.indexOf(first.id) - 1], top.added[0].id, "above the first row");
    await closeAdded(top);
    const end = await fileDrop([[x, last.y + last.h + 14], [x, last.y + last.h + 16]], { files: [png] });
    assert.equal(end.during?.gapKey, "tail:list", JSON.stringify(end.during));
    assert.equal(end.added.length, 1, JSON.stringify(end));
    const loose = end.order.filter((id) => !end.added.some((a) => a.id === id) && rows.some((r) => r.id === id));
    assert.ok(end.order.indexOf(end.added[0].id) > end.order.indexOf(loose.at(-1)), `after the last row: ${end.order}`);
    await closeAdded(end);
  });

  await check("file drop: two files at once open two tabs, in order", async () => {
    const rows = await listRows();
    const b = rows[1];
    const x = Math.round(b.x + b.w / 2);
    const out = await fileDrop([[x, b.y - 8], [x, b.y + 3]], { files: [pdf, png] });
    assert.ok(out.during?.pitch > 1.5 * (rows[1].y - rows[0].y), `a two-row gap: ${JSON.stringify(out.during)}`);
    assert.deepEqual(out.added.map((a) => a.url), [fileUrl(pdf), fileUrl(png)]);
    const at = out.order.indexOf(out.added[0].id);
    assert.deepEqual(out.order.slice(at, at + 3), [out.added[0].id, out.added[1].id, b.id]);
    assert.equal(out.active, out.added[0].id, "the first is selected");
    await closeAdded(out);
  });

  await check("file drop: onto an open group joins the group where it's dropped", async () => {
    const rows = await listRows();
    const ids = rows.slice(0, 2).map((r) => r.id);
    const group = await run(`const g = st().groupTabs(${JSON.stringify(ids)}, { pinned: false }); return settle(900).then(() => g);`);
    const members = await run(`${SIDEBAR} return measured().then((l) => l.filter((i) => i.kind === "row" && i.group === ${JSON.stringify(group)}));`);
    assert.equal(members.length, 2, JSON.stringify(members));
    const second = members[1];
    const x = Math.round(second.x + second.w / 2);
    const out = await fileDrop([[x, second.y - 6], [x, second.y + 3]], { files: [pdf] });
    assert.equal(out.during?.dropInto, null, JSON.stringify(out.during));
    assert.equal(out.added[0]?.group, group, JSON.stringify(out.added));
    const g = await run(`return st().groups[${JSON.stringify(group)}].tabIds;`);
    assert.deepEqual(g, [members[0].id, out.added[0].id, second.id]);
    await closeAdded(out);
    await run(`const g = st().groups[${JSON.stringify(group)}]; if (g) st().placeTabs(g.tabIds, { pinned: false, groupId: null, beforeId: null }); return settle(700);`);
  });

  await check("file drop: onto the pinned tiles pins it", async () => {
    const rows = await listRows();
    await run(`st().pinTabs(${JSON.stringify(rows.slice(-2).map((r) => r.id))}, true, false); return settle(1000);`);
    const tiles = await run(`${SIDEBAR} return measured().then((l) => l.filter((i) => i.kind === "tile"));`);
    assert.ok(tiles.length >= 2, JSON.stringify(tiles));
    const t = tiles[1];
    const x = Math.round(t.x + 4), y = Math.round(t.y + t.h / 2);
    const out = await fileDrop([[x + 30, y], [x, y]], { files: [png] });
    assert.equal(out.during?.pins, true, JSON.stringify(out.during));
    assert.equal(out.added.length, 1, JSON.stringify(out));
    assert.equal(out.added[0].pinned, true, "pinned");
    assert.equal(out.order[out.order.indexOf(t.id) - 1], out.added[0].id, "before the tile it was dropped on");
    await closeAdded(out);
    await run(`const pinned = st().windows.w1.tabIds.filter((id) => st().tabs[id].pinned); st().placeTabs(pinned, { pinned: false, beforeId: null }); return settle(800);`);
  });

  await check("file drop: links open, scripts and data URLs don't (text, URLs, .webloc)", async () => {
    const rows = await listRows();
    const b = rows[1];
    const x = Math.round(b.x + b.w / 2), y = Math.round(b.y + 3);
    for (const payload of [{ text: "javascript:alert(1)" }, { urls: ["data:text/html,<h1>x"] }, { urls: ["javascript:alert(1)"] }, { files: [badLink] }, { text: "file:///etc/hosts" }]) {
      const out = await fileDrop([[x, y - 6], [x, y]], payload);
      assert.deepEqual(out.added, [], `${JSON.stringify(payload)} opened ${JSON.stringify(out.added)}`);
      assert.match(out.log.at(-1), /refused/, `${JSON.stringify(payload)}: ${out.log}`);
      assert.equal(out.after, 0);
    }
    const fileAsWebLink = await fileDrop([[x, y - 6], [x, y]], { publicURLs: ["file:///etc/hosts"] });
    assert.deepEqual(fileAsWebLink.added, [], "a file URL under the web-link type");
    assert.match(fileAsWebLink.log.at(-1), /refused/, fileAsWebLink.log.join(" | "));
    const links = await fileDrop([[x, y - 6], [x, y]], { files: [goodLink] });
    assert.deepEqual(links.added.map((a) => a.url), ["https://example.com/from-webloc"]);
    await closeAdded(links);
    const web = await fileDrop([[x, y - 6], [x, y]], { urls: ["https://example.com/dropped"] });
    assert.deepEqual(web.added.map((a) => a.url), ["https://example.com/dropped"]);
    await closeAdded(web);
    const text = await fileDrop([[x, y - 6], [x, y]], { text: "example.com/typed" });
    assert.deepEqual(text.added.map((a) => a.url), ["https://example.com/typed"]);
    await closeAdded(text);
  });

  await check("file drop: a drag that leaves the sidebar closes its gap and opens nothing", async () => {
    const rows = await listRows();
    const b = rows[1];
    const x = Math.round(b.x + b.w / 2);
    const out = await run(`${SIDEBAR} const FD = ac.shell.devFileDrag; const before = st().windows.w1.tabIds.length;
      return FD.drag("w1", "move", ${x}, ${Math.round(b.y + 3)}, { files: [${JSON.stringify(pdf)}] }).then(() => settle(500))
        .then(() => { const open = c.gapKey; return FD.drag("w1", "move", 700, 400).then((r) => settle(300).then(() => ({ open, r, gap: c.gapKey, external: c.external }))); })
        .then((o) => FD.drag("w1", "cancel", 700, 400).then(() => settle(300)).then(() => ({ ...o, opened: st().windows.w1.tabIds.length - before })));`);
    assert.equal(out.open, b.key, JSON.stringify(out));
    assert.equal(out.gap, null, JSON.stringify(out));
    assert.equal(out.external, 0, JSON.stringify(out));
    assert.equal(out.opened, 0);
  });

  await check("file drop: a drag that ends without an exit or a drop leaves nothing behind", async () => {
    const rows = await listRows();
    const b = rows[1];
    const x = Math.round(b.x + b.w / 2);
    const out = await run(`${SIDEBAR} const FD = ac.shell.devFileDrag;
      return FD.drag("w1", "move", ${x}, ${Math.round(b.y + 3)}, { files: [${JSON.stringify(pdf)}] }).then(() => settle(500))
        .then(() => { const open = c.gapKey; return FD.drag("w1", "end", ${x}, ${Math.round(b.y + 3)}).then((r) => settle(400).then(() => ({ open, r, gap: c.gapKey, external: c.external, active: c.active }))); });`);
    assert.equal(out.open, b.key, JSON.stringify(out));
    assert.deepEqual([out.r, out.gap, out.external, out.active], ["ended", null, 0, false], JSON.stringify(out));
  });

  await check("file drop: a finished download dragged from the Downloads popover opens in the tab list", async () => {
    await run(`st().upsertDownload({ id: "dl-drop", url: "https://example.com/downloaded.pdf", filename: "downloaded.pdf", path: ${JSON.stringify(download)}, state: "finished", paused: false, received: 10, total: 10, speed: 0, mimeType: "application/pdf" });
      st().setDownloadsOpen("w1", true); return settle(900);`);
    let dragged = [];
    try {
      const spot = await run(`return win("w1").then((n) => { const pts = []; for (let y = 30; y < 420; y += 6) for (let x = 20; x < 700; x += 12) pts.push([x, y]);
        return Promise.all(pts.map(([x, y]) => C.devWindow(n, "hit:" + x + "," + y).then((h) => (/FileDragView|DownloadRowView/.test(h) ? [x, y] : null)))).then((hits) => hits.filter(Boolean)); });`);
      assert.ok(spot.length, "a download row in the popover");
      const [sx, sy] = spot[Math.floor(spot.length / 2)];
      dragged = await run(`return act("w1", "drag:${sx},${sy};${sx + 8},${sy + 6};${sx + 60},${sy + 160}").then(() => settle(900)).then(() => Promise.all([ac.shell.devFileDrag.lastFileDrag(), globalThis.expo.modules.SolaraDownloads?.devLastFileDrag?.() ?? []])).then(([rn, native]) => [...rn, ...native]);`);
      assert.deepEqual(dragged, [download], "the row starts a file drag");
      const nativeFiles = await untilSnapshot("native download file drag", (s) => isDeepStrictEqual(s.fileDragURLs, dragged.map((path) => normalizeURL(fileUrl(path)))), 5000, { fields: ["root.fileDragURLs"] });
      assert.deepEqual(nativeFiles.fileDragURLs, dragged.map((path) => normalizeURL(fileUrl(path))));
    } finally {
      await run(`st().setDownloadsOpen("w1", false); return settle(600);`);
    }
    const rows = await listRows();
    const b = rows[1];
    const x = Math.round(b.x + b.w / 2);
    const out = await fileDrop([[x, b.y - 6], [x, b.y + 3]], { files: dragged });
    assert.deepEqual(out.added.map((a) => a.url), [fileUrl(download)]);
    assert.equal(out.order[out.order.indexOf(b.id) - 1], out.added[0].id);
    await closeAdded(out);
  });

  await check("file drop: a file dropped on the top strip opens where the incoming gap was", async () => {
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1500);`);
    const loose = await tabsOf("w1");
    const xs = await run(`return tabItems("w1");`);
    assert.ok(xs.length >= 3, JSON.stringify(xs));
    const x = xs[1][0] + 4;
    const out = await run(`const FD = ac.shell.devFileDrag; const before = new Set(Object.keys(st().tabs)); let gap = null;
      return FD.drag("w1", "move", ${x + 30}, 20, { files: [${JSON.stringify(pdf)}] }).then(() => settle(400)).then(() => FD.drag("w1", "move", ${x}, 20)).then(() => settle(400))
        .then(() => { gap = globalThis.acTabDrag.getState().insert; return FD.drag("w1", "drop", ${x}, 20); }).then((r) => settle(900).then(() => ({ r, gap,
          added: st().windows.w1.tabIds.filter((id) => !before.has(id)), order: st().windows.w1.tabIds, idle: globalThis.acTabDrag.getState().tabIds.length === 0 })));`);
    assert.match(out.r, /FileDropView performed/, JSON.stringify(out));
    assert.ok(out.gap?.beforeId && loose.indexOf(out.gap.beforeId) > 0, `an incoming gap inside the strip: ${JSON.stringify(out.gap)} in ${loose}`);
    assert.equal(out.added.length, 1);
    assert.equal(out.order[out.order.indexOf(out.gap.beforeId) - 1], out.added[0], JSON.stringify(out.order));
    assert.ok(out.idle, "the strip's drag state is idle again");
    await run(`st().closeTabs(${JSON.stringify(out.added)}); return settle(500);`);
    const ended = await run(`const FD = ac.shell.devFileDrag;
      return FD.drag("w1", "move", ${x}, 20, { files: [${JSON.stringify(pdf)}] }).then(() => settle(400)).then(() => { const busy = globalThis.acTabDrag.getState().tabIds.length;
        return FD.drag("w1", "end", ${x}, 20).then(() => settle(400)).then(() => ({ busy, idle: globalThis.acTabDrag.getState().tabIds.length === 0 })); });`);
    assert.deepEqual(ended, { busy: 1, idle: true }, "a drag that just ends frees the strip for tab drags");
  });

  await check("file drop: a private window takes a dropped file too", async () => {
    const out = await run(`const FD = ac.shell.devFileDrag;
      const id = st().createWindow({ incognito: true, frame: [240, 140, 900, 600] });
      return settle(2500).then(() => { const before = st().windows[id].tabIds.length;
        return FD.drag(id, "move", 330, 20, { files: [${JSON.stringify(pdf)}] }).then(() => settle(400)).then(() => FD.drag(id, "drop", 330, 20))
          .then((r) => settle(900).then(() => { const w = st().windows[id]; const added = w.tabIds.slice(before);
            const out = { r, windowId: id, added: w.tabIds.filter((t) => st().tabs[t].url === ${JSON.stringify(fileUrl(pdf))}).length, total: w.tabIds.length - before, profile: w.profileId };
            return out; })); });`);
    assert.match(out.r, /FileDropView performed/, JSON.stringify(out));
    assert.equal(out.added, 1, JSON.stringify(out));
    await run(`st().closeWindow(${JSON.stringify(out.windowId)}); return settle(600);`);
  });
  await check("hidden tab drags never perform a haptic", async () => {
    const native = await app.snapshot({ fields: ["root.haptics"] }, { timeout: 1000 });
    assert.equal(native.consistent, true);
    assert.equal(native.haptics.performed, 0);
  });
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);
