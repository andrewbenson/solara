import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(
    "usage: node top-strip-test.mjs <Debug Solara.app> [--keep-data] [--only=rn|native]\n\nThe top tab strip with pinned tabs, groups (expanded, collapsed, one holding a nested folder) and a split, once on React Native and once with SOLARA_NATIVE_TOP_STRIP=1: every item's span at the strip's middle within 0.5 pt of RN's, the store's strip entries, a click on a tab selects it, a click on a group's chip collapses it, hovering moves nothing, the two strips' pixels compared, every tooltip and VoiceOver name along the strip, the docked profile and downloads controls and the drop glow (pixels, and the glow's fade frame for frame), and the peek over a hidden strip: its slide in and out frame for frame at 30 fps, its downloads button holding it out, and a press in it reaching only what was pressed, not the address field under it.",
  );
  process.exit(2);
}
const appPath = resolve(appArg);
const keep = args.includes("--keep-data");
const only = args.find((a) => a.startsWith("--only="))?.slice(7);
const scratch = mkdtempSync(join(tmpdir(), "ac-top-strip-"));
const rep = reporter(join(scratch, "top-strip-test.log"), { name: "top-strip-test" });
const peekPending = "pending: the RN reference draws the profile tint above the card and the native profile pager draws it below, so these layer renders compare different scenes; the references are to be redone from a window-server capture (docs/backlog.md, the top-strip peek references row)";

const tab = (id, extra = {}) => ({ id, url: `https://${id}.example/`, title: `Tab ${id}`, lastActiveAt: id === "t1" ? 9 : 1, ...extra });
const fixture = () =>
  session({
    settings: { tabLayout: "top" },
    profiles: ["Personal", "Work"],
    windows: [{ id: "w1", activeTabIds: { default: "t1", work: "k1" }, frame: [80, 80, 1600, 800] }],
    tabs: ["p1", "p2"]
      .map((id) => tab(id, { pinned: true }))
      .concat(["t1", "g1a", "g1b", "g2a", "g2b", "s1a", "s1b", "f0", "fa", "fb"].map((id) => tab(id)), [tab("t2", { muted: true })], ["k1", "k2", "k3"].map((id) => tab(id, { profileId: "work" }))),
    groups: [
      { id: "g1", windowId: "w1", profileId: "default", name: "Work", icon: null, color: "blue", collapsed: false, pinned: false, tabIds: ["g1a", "g1b"], createdAt: 1 },
      { id: "g2", windowId: "w1", profileId: "default", name: "", icon: null, color: null, collapsed: true, pinned: false, tabIds: ["g2a", "g2b"], createdAt: 2 },
      { id: "g3", windowId: "w1", profileId: "default", name: "Reading", icon: "symbol:book", color: "green", collapsed: false, pinned: false, tabIds: ["f0", "fa", "fb"], createdAt: 3 },
      { id: "g3c", windowId: "w1", profileId: "default", name: "Docs", icon: null, color: null, collapsed: false, pinned: false, parentId: "g3", tabIds: ["fa", "fb"], createdAt: 4 },
    ],
    splits: [{ id: "s1", windowId: "w1", tabIds: ["s1a", "s1b"], orientation: "horizontal", sizes: [0.5, 0.5] }],
  });

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const st = () => ac.store.getState();
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const act = (id, a) => win(id).then((n) => C.devWindow(n, a));
const postDrag = (id, path) => {
  const points = path.split(";").map((p) => p.split(",").map(Number));
  const steps = [["down", points[0]]];
  for (let i = 1; i < points.length; i++) {
    const [ax, ay] = points[i - 1], [bx, by] = points[i];
    for (let k = 1; k <= 12; k++) steps.push(["dragged", [ax + (bx - ax) * k / 12, ay + (by - ay) * k / 12]]);
  }
  steps.push(["up", points.at(-1)]);
  const start = performance.now();
  steps.reduce((chain, [type, [x, y]], i) => chain
    .then(() => new Promise((r) => setTimeout(r, Math.max(0, start + (i ? 150 + i * 16 : 0) - performance.now()))))
    .then(() => act(id, "mouse:" + type + ":" + Math.round(x * 100) / 100 + "," + Math.round(y * 100) / 100)), Promise.resolve());
  return Promise.resolve(steps.length + " events posted");
};
const runs = (id, y) => win(id).then((n) => { const xs = []; for (let x = 60; x < st().windows[id].frame[2] - 90; x += 0.5) xs.push(x);
  return Promise.all(xs.map((x) => C.devWindow(n, "hit:" + x + "," + y))).then((hits) => { const out = []; let cur = null;
    hits.forEach((h, i) => { const on = /ContextMenuArea|ImageView|Symbol|FadeLabel|Strip(TabChip|PinnedCell|GroupHeader|FolderChip|SplitPart|IconButton|NewTabButton)/.test(h);
      const kind = /^SolaraUI.StripIconButton < NSView < SolaraUI.StripGroupView/.test(h) ? "groupClose" : h.split(/[ :<(]/)[0];
      if (on && !cur) cur = [xs[i], xs[i], kind]; else if (on) cur[1] = xs[i]; else if (cur) { out.push(cur); cur = null; } });
    if (cur) out.push(cur); return out; }); });
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const pageSettled = (id) => !!ac.nativePages.facts(id)?.ready && st().live[id]?.isLoading === false;
const pageReady = (id, deadline = Date.now() + 15000, settledSince = null) => {
  if (pageSettled(id) && settledSince !== null && Date.now() - settledSince >= 500) return Promise.resolve();
  if (Date.now() > deadline) return Promise.reject(new Error(id + "'s native page didn't finish its first navigation after showing it"));
  return settle(100).then(() => pageReady(id, deadline, pageSettled(id) ? settledSince ?? Date.now() : null));
};
const themesHold = (themes) => {
  for (const [id, themeColor] of Object.entries(themes))
    if ((st().live[id]?.themeColor ?? null) !== themeColor) throw new Error(id + "'s live theme is " + st().live[id]?.themeColor + " around the capture, expected " + themeColor);
};
const withPages = (ids, then) => {
  if (!ac.nativePages.ownsLive()) return Promise.resolve().then(then);
  const front = st().windows.w1.activeTabIds.default;
  return ids.filter((id) => !pageSettled(id)).reduce((shown, id) => shown.then(() => { st().activate(id); return pageReady(id); }), Promise.resolve())
    .then(() => { st().activate(front); return pageReady(front); }).then(then);
};
const pageTheme = (id, themeColor) => {
  const pages = ac.nativePages;
  if (!pages.ownsLive()) return st().updateLive(id, { themeColor });
  const facts = pages.facts(id);
  if (!facts) throw new Error("no native page for " + id);
  const live = st().live[id];
  const tab = st().tabs[id];
  const out = pages.report(id, { type: "navigation", generation: facts.generation, url: tab.url, title: tab.title, isLoading: !!live?.isLoading,
    canGoBack: !!live?.canGoBack, canGoForward: !!live?.canGoForward, themeColor });
  if (!out || out.error) throw new Error("the native store refused " + id + "'s theme: " + (out?.error ?? "no response"));
  if (st().live[id]?.themeColor !== themeColor) throw new Error(id + "'s live theme is " + st().live[id]?.themeColor + ", expected " + themeColor);
};
`;

const STRIP_FIELDS = ["root.hostedKinds", "root.swipeSimulation", "root.haptics",
  ...["profileId", "selectedTabId", "tabIds", "topStrip", "stripPoints", "overlays", "dropTargets", "hoverLayout"].map((key) => "windows." + key)];
const nativeSnapshot = (app, args = {}) => app.snapshot({ windowId: "w1", topStrip: true, fields: STRIP_FIELDS, ...args });

async function untilSnapshot(app, what, accept, ms = 8000, args = {}) {
  const end = Date.now() + ms;
  let state;
  do {
    state = await nativeSnapshot(app, args);
    if (state.consistent && accept(state.windows?.find((w) => w.id === "w1"), state)) return state;
    await sleep(50);
  } while (Date.now() < end);
  throw new Error(`${what}: ${JSON.stringify(state)}`);
}

async function pointSamples(app, points, labels = false) {
  const rows = [];
  for (let at = 0; at < points.length; at += 4) {
    const chunk = points.slice(at, at + 4);
    const state = await untilSnapshot(app, "native point samples", (w) => w?.stripPoints?.length === chunk.length, 8000, { stripPoints: chunk, stripLabels: labels, topStrip: false, fields: ["windows.stripPoints"] });
    rows.push(...state.windows.find((w) => w.id === "w1").stripPoints);
  }
  return rows;
}

function nativeWindow(state) { return state.windows.find((w) => w.id === "w1"); }

function compareItems(a, b) {
  assert.deepEqual(a.keys, b.keys);
  assert.ok(Math.abs(a.chip - b.chip) <= 0.5);
  assert.ok(Math.abs(a.scrolled - b.scrolled) <= 0.5);
  assert.equal(a.items.length, b.items.length);
  for (let i = 0; i < a.items.length; i++) {
    const ours = a.items[i], theirs = b.items[i];
    assert.deepEqual([ours.id, ours.kind], [theirs.id, theirs.kind]);
    for (const key of ["x", "y", "width", "height", "windowX", "windowY"]) assert.ok(Math.abs(ours[key] - theirs[key]) <= 0.5, `${ours.kind}/${ours.id} ${key}`);
    assert.equal(ours.alpha, theirs.alpha);
  }
}

async function nativeCapture(app, legacy, band = 42) {
  if (!legacy) return null;
  const capture = await app.probe("view.capture", { windowId: "w1" });
  assert.equal(capture.consistent, true, "native capture is consistent around the PNG");
  assert.match(capture.artifact, /^\.solara-probe-window-[a-f0-9-]+\.png$/);
  const path = join(app.data, capture.artifact);
  const ours = readPng(path), theirs = readPng(legacy);
  assert.deepEqual([ours.width, ours.height], [capture.width, capture.height]);
  assert.deepEqual([ours.width, ours.height], [theirs.width, theirs.height]);
  assert.equal(capture.scale, 2);
  assert.ok(stripDiff(ours, theirs, 0, band).share < 0.01, "native capture matches the JS window capture");
  return path;
}

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

function crop(png, left, right) {
  const width = (right - left) * 2;
  const data = Buffer.alloc(width * png.height * png.channels);
  for (let y = 0; y < png.height; y++) png.data.copy(data, y * width * png.channels, (y * png.width + left * 2) * png.channels, (y * png.width + right * 2) * png.channels);
  return { width, height: png.height, channels: png.channels, data };
}

function stripDiff(a, b, top, bottom, threshold = 24) {
  let differ = 0, total = 0, worst = 0;
  const columns = [];
  for (let y = top * 2; y < bottom * 2; y++)
    for (let x = 0; x < Math.min(a.width, b.width); x++) {
      const i = (y * a.width + x) * a.channels, j = (y * b.width + x) * b.channels;
      const d = Math.max(Math.abs(a.data[i] - b.data[j]), Math.abs(a.data[i + 1] - b.data[j + 1]), Math.abs(a.data[i + 2] - b.data[j + 2]));
      total++;
      if (d > threshold) {
        differ++;
        columns[x >> 1] = (columns[x >> 1] ?? 0) + 1;
      }
      worst = Math.max(worst, d);
    }
  const hot = columns.flatMap((n, x) => (n > 4 ? [x] : []));
  return { share: differ / total, worst, hot: hot.length ? `${hot[0]}..${hot.at(-1)} (${hot.length} columns)` : "" };
}

const SWIPE = [{ phase: "began", dx: 0, dy: 0 }, ...[-30, -30, -30, -30].map((dx) => ({ phase: "changed", dx, dy: 0 }))].map((step, i) => ({ ...step, atMs: i * 16, timestampMs: i * 16 }));
const LOOKS = [
  [
    "paging",
    `win("w1").then((n) => { globalThis.expo.modules.SolaraSwipe.devSimulate(700, 22, n, ${JSON.stringify(SWIPE)}, true); return true; });`,
    `win("w1").then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(700, 22, n, [{ phase: "changed", dx: 60, dy: 0, atMs: 0, timestampMs: 0 }, { phase: "ended", dx: 0, dy: 0, atMs: 16, timestampMs: 16 }], true)).then(() => st().switchProfile("w1", "default"));`,
  ],
  ["flipped", `st().updateSettings({ appearance: st().ui.appDark ? "light" : "dark" });`, `st().updateSettings({ appearance: "auto" });`],
  [
    "bands",
    `globalThis.acBands = { t1: "#2b6cb0", g1a: "#f6e05e", t2: "#1a202c" };
      return withPages(Object.keys(globalThis.acBands), () => { st().updateSettings({ extendWebsiteColor: true }); for (const [id, color] of Object.entries(globalThis.acBands)) pageTheme(id, color); })
        .then(() => settle(900)).then(() => themesHold(globalThis.acBands));`,
    `themesHold(globalThis.acBands); st().updateSettings({ extendWebsiteColor: false }); for (const id of Object.keys(globalThis.acBands)) pageTheme(id, null);`,
  ],
  [
    "capture",
    `const pages = ac.pageState.getState().pages; globalThis.acCapturePages = { t1: pages.t1, p1: pages.p1, g1a: pages.g1a }; const media = (id, access) => ac.pageState.setState((s) => ({ pages: { ...s.pages, [id]: { ...(s.pages[id] ?? s.pages.t1), mediaAccess: access } } })); media("t1", { camera: false, microphone: false, screen: true }); media("p1", { camera: true, microphone: true, screen: false }); media("g1a", { camera: true, microphone: false, screen: false });`,
    `ac.pageState.setState((s) => { const pages = { ...s.pages }; for (const [id, page] of Object.entries(globalThis.acCapturePages)) if (page) pages[id] = page; else delete pages[id]; return { pages }; });`,
  ],
  [
    "peek",
    `st().toggleSidebar("w1"); setTimeout(() => globalThis.acLayout.peek["strip:w1"].show(), 450);`,
    `globalThis.acLayout.peek["strip:w1"].hide(); st().toggleSidebar("w1");`,
    56,
  ],
];

async function measure(native) {
  const data = join(scratch, native ? "native" : "rn", "data");
  const app = await launch(appPath, { data, session: fixture(), env: { SOLARA_NATIVE_TOP_STRIP: native ? "1" : "0" } });
  const run = (body) => app.eval(`${HELPERS}\n${body}`);
  try {
    await sleep(2500);
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
    assert.equal(kinds.includes("topStrip"), native, `topStrip kind registered: ${kinds}`);
    await untilSnapshot(app, "registered top strip", (_, state) => state.hostedKinds.includes("topStrip") === native);
    const hello = await app.probe("probe.hello");
    assert.ok(hello.capabilities.includes("state.snapshot"));
    const out = { spans: await run(`return runs("w1", 21);`) };
    const nativeSpans = [];
    let span = null;
    for (const row of await pointSamples(app, Array.from({ length: (1600 - 150) * 2 }, (_, i) => [60 + i / 2, 21]))) {
      const on = /ContextMenuArea|ImageView|Symbol|FadeLabel|Strip(TabChip|PinnedCell|GroupHeader|FolderChip|SplitPart|IconButton|NewTabButton)/.test(row.hit);
      const kind = /^SolaraUI.StripIconButton < NSView < SolaraUI.StripGroupView/.test(row.hit) ? "groupClose" : row.hit.split(/[ :<(]/)[0];
      if (on && !span) span = [row.x, row.x, kind];
      else if (on) span[1] = row.x;
      else if (span) { nativeSpans.push(span); span = null; }
    }
    if (span) nativeSpans.push(span);
    assert.deepEqual(nativeSpans, out.spans, "the native snapshot sees the same hit spans");
    if (native) {
      out.items = JSON.parse(await run(`return globalThis.expo.modules.SolaraTopStrip.items("w1");`));
      out.keys = await run(`return globalThis.expo.modules.SolaraTopStrip.keys("w1", "default");`);
      const state = await untilSnapshot(app, "native strip items", (w) => !!w?.topStrip?.items);
      const strip = nativeWindow(state).topStrip;
      compareItems(strip.items, out.items);
      assert.deepEqual(strip.keys, out.keys);
    }
    const png = join(scratch, native ? "native.png" : "rn.png");
    out.snapshot = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(png)});`)) ? png : null;
    await nativeCapture(app, out.snapshot);
    out.looks = {};
    for (const [look, setup, undo] of LOOKS) {
      const shot = join(scratch, `${native ? "native" : "rn"}-${look}.png`);
      await run(`return Promise.resolve((() => { ${setup} })()).then(() => settle(900));`);
      out.looks[look] = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`)) ? shot : null;
      await nativeCapture(app, out.looks[look], look === "peek" ? 56 : 42);
      if (look === "peek") {
        out.peekHit = await run(`return act("w1", "hit:200,22");`);
        assert.equal((await pointSamples(app, [[200, 22]]))[0].hit, out.peekHit);
      }
      await run(`${undo} return settle(600);`);
    }
    const peekShown = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().trace()).then(() => settle(50)).then(() => peek().show()).then(() => settle(500)).then(() => peek().live);`);
    if (native) await untilSnapshot(app, "peek shown", (w) => w?.topStrip?.peek?.live === true && w.topStrip.peek.live === peekShown);
    out.peekMotion = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      peek().hide(); return settle(600).then(() => peek().samples());`);
    if (native) {
      const state = await untilSnapshot(app, "native peek trace and hidden state", (w) => w?.topStrip?.peek?.live === false && w.topStrip.peekTrace?.length > 3, 8000, { stripTrace: "peek", fields: ["windows.topStrip"] });
      assert.deepEqual(nativeWindow(state).topStrip.peekTrace, out.peekMotion.slice(-128));
    }
    await run(`st().toggleSidebar("w1"); return settle(600);`);
    out.peekHeld = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      const seen = {};
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => act("w1", "hit:1569,27")).then((hit) => (seen.hit = hit)).then(() => seen);`);
    await untilSnapshot(app, "native hit before the click", (w) => !w.topStrip.downloadsOpen &&
      w.stripPoints.some((p) => p.x === 1569 && p.y === 27 && p.hit === out.peekHeld.hit), 8000, { stripPoints: [[1569, 27]] });
    Object.assign(out.peekHeld, await run(`return act("w1", "click:1569,27").then(() => settle(400)).then(() => ({ open: !!st().windowUi.w1?.downloadsOpen, panel: !!st().windowUi.w1?.panel.open }));`));
    await untilSnapshot(app, "native downloads open", (w) => w.topStrip.downloadsOpen === out.peekHeld.open && w.topStrip.panelOpen === out.peekHeld.panel, 8000);
    out.peekHeld.heldLive = await run(`st().closePanel("w1"); globalThis.acLayout.peek["strip:w1"].hide(); return settle(500).then(() => globalThis.acLayout.peek["strip:w1"].live);`);
    if (native) {
      await untilSnapshot(app, "downloads hold peek after hide", (w) => w?.topStrip?.peek?.live === out.peekHeld.heldLive && w.overlays.some((o) => o.kind === "downloads" && o.visible));
    }
    out.peekHeld.afterClose = await run(`st().setDownloadsOpen("w1", false); return settle(800).then(() => globalThis.acLayout.peek["strip:w1"].live);`);
    if (native) await untilSnapshot(app, "closed downloads release peek before strip restore", (w) => w?.topStrip?.peek?.live === out.peekHeld.afterClose && !w.overlays.some((o) => o.kind === "downloads" && o.visible));
    await run(`st().toggleSidebar("w1"); return settle(600);`);
    await run(`st().toggleSidebar("w1"); return settle(600).then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(400));`);
    out.peekPress = { presses: [] };
    const press = (x, y) => run(`return act("w1", "mouse:down:${x},${y}").then(() => settle(100)).then(() => act("w1", "mouse:up:${x},${y}")).then(() => settle(500))
      .then(() => ({ panel: !!st().windowUi.w1?.panel.open, active: st().windows.w1.activeTabIds.default, downloads: !!st().windowUi.w1?.downloadsOpen }));`);
    for (const [x, y, what] of [[420, 22, "tab"], [1569, 27, "downloads"]]) {
      const hit = await run(`return act("w1", "hit:${x},${y}");`);
      await untilSnapshot(app, `${what} native hit before press`, (w) => (!native || w?.topStrip?.peek?.live === true) &&
        w.stripPoints.some((p) => p.x === x && p.y === y && p.hit === hit), 8000, { stripPoints: [[x, y]] });
      const seen = { what, hit, ...await press(x, y) };
      out.peekPress.presses.push(seen);
      await untilSnapshot(app, `${what} native state after press`, (w) => w?.selectedTabId === seen.active && w.topStrip.panelOpen === seen.panel && w.topStrip.downloadsOpen === seen.downloads);
      await run(`st().closePanel("w1"); st().setDownloadsOpen("w1", false); return settle(500).then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(400));`);
    }
    await run(`st().activate("t1"); globalThis.acLayout.peek["strip:w1"].hide(); return settle(700);`);
    out.peekPress.fieldHit = await run(`return act("w1", "hit:600,24");`);
    await untilSnapshot(app, "native address field hit before press", (w) => (!native || w?.topStrip?.peek?.live === false) &&
      w.stripPoints.some((p) => p.x === 600 && p.y === 24 && p.hit === out.peekPress.fieldHit), 8000, { stripPoints: [[600, 24]] });
    out.peekPress.field = (await press(600, 24)).panel;
    await untilSnapshot(app, "native address panel opens after press", (w) => w.topStrip.panelOpen === out.peekPress.field);
    await run(`st().closePanel("w1"); return settle(400).then(() => { st().toggleSidebar("w1"); return settle(600); });`);
    const peekSwipeBefore = await untilSnapshot(app, "before peek swipe", () => true);
    out.peekSwipe = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      const flick = [["began", 0], ["changed", -18], ["changed", -22], ["changed", -22], ["ended", 0]].map(([phase, dx], i) => ({ phase, dx, dy: 0, atMs: i * 16, timestampMs: i * 16, dispatch: "app" }));
      const seen = {};
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400)).then(() => win("w1"))
        .then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(700, 22, n, flick, true)).then((r) => (seen.where = r.where))
        .then(() => settle(700)).then(() => { seen.profile = st().windows.w1.profileId; seen.live = peek().live; return seen; });`);
    await untilSnapshot(app, "peek swipe native profile, route and visibility", (w, state) => state.swipeSimulation.count === peekSwipeBefore.swipeSimulation.count + 1 &&
      w?.profileId === out.peekSwipe.profile && state.swipeSimulation.where?.hit === out.peekSwipe.where.hit && state.swipeSimulation.where?.target === out.peekSwipe.where.target &&
      (!native || w?.topStrip?.peek?.live === out.peekSwipe.live));
    await run(`st().switchProfile("w1", "default"); return settle(600).then(() => { globalThis.acLayout.peek["strip:w1"].hide(); return settle(600); }).then(() => { st().toggleSidebar("w1"); return settle(600); });`);
    out.peekFile = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      const drag = (action, x, payload) => globalThis.expo.modules.SolaraFileDrop.devDrag("w1", action, x, 27, payload);
      const before = st().windows.w1.tabIds.slice();
      const seen = {};
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => drag("move", 200, { urls: ["https://dropped.example/"] })).then((r) => (seen.over = r)).then(() => settle(100))
        .then(() => drag("move", 300)).then(() => settle(300))
        .then(() => drag("drop", 300)).then((r) => (seen.drop = r)).then(() => settle(800))
        .then(() => {
          const ids = st().windows.w1.tabIds;
          const added = ids.find((id) => !before.includes(id));
          seen.after = added ? ids[ids.indexOf(added) - 1] ?? null : "none";
          seen.added = added ?? null;
          return seen;
        });`);
    assert.ok(out.peekFile.added, "peek drop added a tab");
    await untilSnapshot(app, "peek drop native order", (w, state) => {
      const added = state.tabs.find((t) => t.id === out.peekFile.added && t.url === "https://dropped.example/");
      return added && w.tabIds.includes(added.id) && (w.tabIds[w.tabIds.indexOf(added.id) - 1] ?? null) === out.peekFile.after;
    }, 8000, { fields: [...STRIP_FIELDS, "tabs.url"] });
    await run(`st().closeTab(${JSON.stringify(out.peekFile.added)}); st().activate("t1"); st().toggleSidebar("w1"); return settle(600);`);
    out.peekFrames = {};
    for (const value of [0.25, 0.5, 0.75]) {
      const shot = join(scratch, `${native ? "native" : "rn"}-peek-${value}.png`);
      await run(`st().toggleSidebar("w1"); return settle(600).then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(400)).then(() => globalThis.acLayout.peek["strip:w1"].pin(${value})).then(() => settle(200));`);
      out.peekFrames[value] = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`)) ? shot : null;
      await nativeCapture(app, out.peekFrames[value], 80);
      await run(`globalThis.acLayout.peek["strip:w1"].pin(1); globalThis.acLayout.peek["strip:w1"].hide(); return settle(600).then(() => { st().toggleSidebar("w1"); return settle(600); });`);
    }
    out.downloadsAt = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => act("w1", "click:1569,27")).then(() => settle(100)).then(() => st().closePanel("w1")).then(() => settle(600)).then(() => win("w1"))
        .then((n) => {
          const points = [];
          for (let y = 60; y < 700; y += 4) points.push([1500, y]);
          for (let x = 1100; x < 1600; x += 4) points.push([x, 140]);
          return Promise.all(points.map(([x, y]) => C.devWindow(n, "hit:" + x + "," + y))).then((hits) => {
            const edges = []; let prev = null;
            hits.forEach((h, i) => { if (i === 160 || h !== prev) edges.push(points[i].join(",") + " " + h); prev = h; });
            return edges;
          });
        })
        .then((edges) => edges);`);
    const downloadsPoints = [...Array.from({ length: 160 }, (_, i) => [1500, 60 + i * 4]), ...Array.from({ length: 125 }, (_, i) => [1100 + i * 4, 140])];
    const downloadEdges = (rows) => rows.flatMap((row, i) => i === 0 || i === 160 || row.hit !== rows[i - 1].hit ? [`${row.x},${row.y} ${row.hit}`] : []);
    assert.deepEqual(downloadEdges(await pointSamples(app, downloadsPoints)), out.downloadsAt);
    await run(`st().setDownloadsOpen("w1", false); return settle(600).then(() => { st().toggleSidebar("w1"); return settle(600); });`);
    const dockedBefore = await untilSnapshot(app, "before docked swipe", () => true);
    out.docked = await run(`
      const W = st().windows.w1.frame[2];
      const seen = {};
      return win("w1").then((n) => {
        const xs = [];
        for (let x = W - 8 - 110; x < W; x += 0.5) xs.push(x);
        return Promise.all(xs.map((x) => C.devWindow(n, "hit:" + x + ",21"))).then((hits) => {
          const edges = []; let prev = null;
          hits.forEach((h, i) => { const k = /WindowDragRegion/.test(h) ? "drag" : /SwipeArea/.test(h) ? "swipe" : "item"; if (k !== prev) edges.push(xs[i] + " " + k); prev = k; });
          seen.edges = edges;
          seen.downloadsHit = hits[xs.indexOf(W - 25)];
          return seen;
        });
      });`);
    const dockedEdges = [];
    const dockedPoints = await pointSamples(app, Array.from({ length: 236 }, (_, i) => [1482 + i / 2, 21]));
    for (const point of dockedPoints) {
      const kind = /WindowDragRegion/.test(point.hit) ? "drag" : /SwipeArea/.test(point.hit) ? "swipe" : "item";
      if (!dockedEdges.length || !dockedEdges.at(-1).endsWith(` ${kind}`)) dockedEdges.push(`${point.x} ${kind}`);
    }
    assert.deepEqual(dockedEdges, out.docked.edges);
    assert.equal(dockedPoints.find((p) => p.x === 1575).hit, out.docked.downloadsHit);
    Object.assign(out.docked, await run(`
      const flick = [["began", 0], ["changed", -18], ["changed", -22], ["changed", -22], ["ended", 0]].map(([phase, dx], i) => ({ phase, dx, dy: 0, atMs: i * 16, timestampMs: i * 16, dispatch: "app" }));
      return win("w1").then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(st().windows.w1.frame[2] - 25, 21, n, flick, true))
        .then((r) => settle(600).then(() => ({ swipe: r.where, swipedTo: st().windows.w1.profileId })));`));
    await untilSnapshot(app, "docked swipe native profile and route", (w, state) => state.swipeSimulation.count === dockedBefore.swipeSimulation.count + 1 &&
      w?.profileId === out.docked.swipedTo && state.swipeSimulation.where?.hit === out.docked.swipe.hit && state.swipeSimulation.where?.target === out.docked.swipe.target);
    await run(`st().switchProfile("w1", "default"); return settle(600);`);
    Object.assign(out.docked, await run(`
      const before = st().windows.w1.tabIds.slice();
      const drag = (action, payload) => globalThis.expo.modules.SolaraFileDrop.devDrag("w1", action, st().windows.w1.frame[2] - 25, 21, payload);
      return drag("move", { urls: ["https://dropped.example/"] }).then((over) => settle(200).then(() => drag("drop")).then(() => settle(800)).then(() => {
        const ids = st().windows.w1.tabIds;
        const added = ids.find((id) => !before.includes(id));
        return { over, added: added ?? null, dropped: added ? ids[ids.indexOf(added) - 1] ?? null : "none" };
      }));`));
    assert.ok(out.docked.added, "docked drop added a tab");
    await untilSnapshot(app, "docked drop native order", (w, state) => {
      const added = state.tabs.find((t) => t.id === out.docked.added && t.url === "https://dropped.example/");
      return added && w.tabIds.includes(added.id) && (w.tabIds[w.tabIds.indexOf(added.id) - 1] ?? null) === out.docked.dropped;
    }, 8000, { fields: [...STRIP_FIELDS, "tabs.url"] });
    await run(`st().closeTab(${JSON.stringify(out.docked.added)}); st().activate("t1"); return settle(500);`);
    out.labels = await run(`
      const W = st().windows.w1.frame[2];
      return win("w1").then((n) => {
        const xs = [];
        for (let x = 60; x < W; x += 1) xs.push(x);
        const runsOf = (prefix) => Promise.all(xs.map((x) => C.devWindow(n, prefix + x + ",21"))).then((all) => {
          const out = []; let prev = null;
          all.forEach((v, i) => { if (v !== prev) out.push([xs[i], v]); prev = v; });
          return out;
        });
        return runsOf("tip:").then((tips) => runsOf("ax:").then((ax) => ({ tips, ax })));
      });`);
    const nativeLabels = { tips: [], ax: [] };
    for (const row of await pointSamples(app, Array.from({ length: 1540 }, (_, i) => [60 + i, 21]), true)) {
      for (const [key, value] of [["tips", row.tip], ["ax", row.ax]]) if (!nativeLabels[key].length || nativeLabels[key].at(-1)[1] !== value) nativeLabels[key].push([row.x, value]);
    }
    assert.deepEqual(nativeLabels, out.labels, "native tooltip spans and AX labels match the JS read");
    out.dockedShots = {};
    const W = 1600;
    const dockedLooks = [
      ["rest", ``, ``],
      ["hoverDownloads", `ac.shell.devSetPointer("w1", { x: ${W - 25}, y: 21 }).then(() => act("w1", "mouse:moved:${W - 25},21"));`, `ac.shell.devSetPointer("w1", { x: 600, y: 400 }).then(() => act("w1", "mouse:moved:600,400")).then(() => ac.shell.devSetPointer("w1", null));`],
      ["hoverName", `ac.shell.devSetPointer("w1", { x: ${W - 80}, y: 21 }).then(() => act("w1", "mouse:moved:${W - 80},21"));`, `ac.shell.devSetPointer("w1", { x: 600, y: 400 }).then(() => act("w1", "mouse:moved:600,400")).then(() => ac.shell.devSetPointer("w1", null));`],
      ["pressDownloads", `act("w1", "mouse:down:${W - 25},21");`, `act("w1", "mouse:up:${W - 25},21").then(() => settle(300)).then(() => { st().setDownloadsOpen("w1", false); st().closePanel("w1"); });`],
      ["downloadsOpen", `st().setDownloadsOpen("w1", true);`, `st().setDownloadsOpen("w1", false);`],
      ["glow", `globalThis.acTabDrag.setState({ overWindow: "w1" });`, `globalThis.acTabDrag.setState({ overWindow: null });`],
    ];
    for (const [look, setup, undo] of dockedLooks) {
      const shot = join(scratch, `${native ? "native" : "rn"}-docked-${look}.png`);
      await run(`${setup} return settle(500);`);
      out.dockedShots[look] = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`)) ? shot : null;
      if (look !== "pressDownloads") await nativeCapture(app, out.dockedShots[look]);
      await run(`${undo} return settle(600);`);
    }
    const glowArm = native ? `globalThis.expo.modules.SolaraTopStrip.traceGlow("w1")` : `Promise.resolve(globalThis.acStrip.traceGlow("w1"))`;
    const glowRead = native ? `globalThis.expo.modules.SolaraTopStrip.glowTrace("w1").then((s) => s.map(([t, x]) => [t * 1000, x]))` : `Promise.resolve(globalThis.acStrip.glowTrace())`;
    out.glowMotion = {};
    for (const [name, hold] of [["full", 400], ["cut", 60]]) {
      out.glowMotion[name] = await run(`
        return ${glowArm}.then(() => settle(50)).then(() => { globalThis.acTabDrag.setState({ overWindow: "w1" }); return settle(${hold}); })
          .then(() => { globalThis.acTabDrag.setState({ overWindow: null }); return settle(400); }).then(() => ${glowRead});`);
      if (native) {
        const state = await untilSnapshot(app, "native drop glow trace", (w) => w?.topStrip?.glowTrace?.length > 3, 8000, { stripTrace: "glow", fields: ["windows.topStrip"] });
        assert.deepEqual(nativeWindow(state).topStrip.glowTrace.map(([t, x]) => [t * 1000, x]), out.glowMotion[name].slice(-128));
      }
    }
    out.dockedDownloadsAt = await run(`
      return act("w1", "click:${W - 25},21").then(() => settle(100)).then(() => st().closePanel("w1")).then(() => settle(600)).then(() => win("w1"))
        .then((n) => {
          const points = [];
          for (let y = 60; y < 700; y += 4) points.push([1500, y]);
          for (let x = 1100; x < 1600; x += 4) points.push([x, 140]);
          return Promise.all(points.map(([x, y]) => C.devWindow(n, "hit:" + x + "," + y))).then((hits) => {
            const edges = []; let prev = null;
            hits.forEach((h, i) => { if (i === 160 || h !== prev) edges.push(points[i].join(",") + " " + h); prev = h; });
            return edges;
          });
        })
        .then((edges) => edges);`);
    assert.deepEqual(downloadEdges(await pointSamples(app, downloadsPoints)), out.dockedDownloadsAt);
    await run(`st().setDownloadsOpen("w1", false); return settle(600);`);
    if (native) {
      out.hiddenTop = { points: [] };
      await run(`st().toggleSidebar("w1"); return settle(800);`);
      for (const [x, y] of [[600, 2], [600, 24], [1569, 27]]) {
        const point = { x, y, hit: await run(`return act("w1", "hit:${x},${y}");`) };
        const beforeDrag = await untilSnapshot(app, "hidden top hit before drag", (w) => w?.topStrip?.peek?.live === false &&
          w.stripPoints.some((p) => p.x === x && p.y === y && p.hit === point.hit), 8000, { stripPoints: [[x, y]], fields: [...STRIP_FIELDS, "root.fileDropSequence"] });
        assert.doesNotMatch(point.hit, /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the click at ${x},${y} reaches ${point.hit}`);
        point.drag = await run(`return globalThis.expo.modules.SolaraFileDrop.devDrag("w1", "move", ${x}, ${y}, { urls: ["https://dropped.example/"] });`);
        const destination = /^(\S+) ([0-9]+)$/.exec(point.drag);
        assert.ok(destination, `drag move result: ${point.drag}`);
        assert.doesNotMatch(point.drag, /FileDropView/, `the drop at ${x},${y} goes to ${point.drag}`);
        const target = JSON.parse(await run(`return win("w1").then((n) => globalThis.expo.modules.SolaraPages.devDropTarget(n, ${x}, ${y}, "public.url"));`));
        assert.ok(Object.hasOwn(target, "view") && Array.isArray(target.chain), `drop target result: ${JSON.stringify(target)}`);
        const duringDrag = await untilSnapshot(app, "hidden top drop during move", (w, state) => w?.topStrip?.peek?.live === false &&
          state.fileDropSequence === beforeDrag.fileDropSequence + 1 && state.fileDropResults.some((r) =>
            r.sequence === beforeDrag.fileDropSequence + 1 && r.windowId === "w1" && r.phase === "move" && r.result === point.drag) &&
          w.dropTargets.length === 1,
          8000, { dropTargets: [{ x, y, type: "public.url" }], tabDrag: true, fileDropAfter: beforeDrag.fileDropSequence,
            fields: [...STRIP_FIELDS, "root.fileDropSequence", "root.fileDropResults"] });
        assert.deepEqual(nativeWindow(duringDrag).dropTargets, [{ x, y, type: "public.url", view: target.view, chain: target.chain }]);
        await run(`return globalThis.expo.modules.SolaraFileDrop.devDrag("w1", "cancel", ${x}, ${y}, {});`);
        const before = await untilSnapshot(app, "before hidden top swipe", () => true);
        Object.assign(point, await run(`
          const flick = [["began", 0], ["changed", -18], ["changed", -22], ["changed", -22], ["ended", 0]].map(([phase, dx], i) => ({ phase, dx, dy: 0, atMs: i * 16, timestampMs: i * 16, dispatch: "app" }));
          return win("w1").then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(${x}, ${y}, n, flick, true)).then((r) => settle(500)
            .then(() => ({ swipe: r.where, profile: st().windows.w1.profileId, live: globalThis.acLayout.peek["strip:w1"]?.live ?? null })));`));
        await untilSnapshot(app, "hidden top swipe and peek visibility", (w, state) => state.swipeSimulation.count === before.swipeSimulation.count + 1 &&
          w?.profileId === point.profile && state.swipeSimulation.where?.hit === point.swipe.hit && state.swipeSimulation.where?.target === point.swipe.target &&
          w?.topStrip?.peek?.live === point.live);
        assert.doesNotMatch(String(point.swipe?.hit), /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the swipe at ${x},${y} hits ${point.swipe?.hit}`);
        assert.equal(point.profile, "default", `the swipe at ${x},${y} paged the strip's profiles`);
        assert.equal(point.live, false, "the peek stayed hidden");
        out.hiddenTop.points.push(point);
        await run(`st().switchProfile("w1", "default"); return settle(300);`);
      }
      await run(`st().toggleSidebar("w1"); return settle(600);`);
      const live = `globalThis.acLayout.peek["strip:w1"]?.live ?? null`;
      out.peekHover = {};
      out.peekHover.shown = await run(`
        st().toggleSidebar("w1");
        return settle(500)
          .then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(500)).then(() => ${live});`);
      await untilSnapshot(app, "native peek shown", (w) => w?.topStrip?.peek?.live === out.peekHover.shown);
      Object.assign(out.peekHover, await run(`return act("w1", "mouse:moved:300,24").then(() => settle(150)).then(() => act("w1", "mouse:moved:520,30")).then(() => settle(500))
        .then(() => act("w1", "hit:520,30")).then((hit) => ({ overStrip: ${live}, hit }));`));
      await untilSnapshot(app, "native peek stays under hover", (w) => w?.topStrip?.peek?.live === out.peekHover.overStrip &&
        w.stripPoints.some((p) => p.x === 520 && p.y === 30 && p.hit === out.peekHover.hit), 8000, { stripPoints: [[520, 30]] });
      Object.assign(out.peekHover, await run(`return act("w1", "mouse:moved:520,160").then(() => settle(600))
        .then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((afterHide) => ({ away: ${live}, afterHide }));`));
      await untilSnapshot(app, "native peek hidden after hover", (w) => w?.topStrip?.peek?.live === out.peekHover.away && w.topStrip.peekMonitors === out.peekHover.afterHide);
      out.peekHover.whileOut = await run(`globalThis.acLayout.peek["strip:w1"].show(); return settle(500).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors());`);
      await untilSnapshot(app, "native peek monitors while out", (w) => w?.topStrip?.peek?.live === true && w.topStrip.peekMonitors === out.peekHover.whileOut);
      out.peekHover.afterStripBack = await run(`st().toggleSidebar("w1"); return settle(700).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors());`);
      const stripRestored = await untilSnapshot(app, "native peek monitors after strip restore", (w) => w?.topStrip?.peekMonitors === out.peekHover.afterStripBack);
      out.peekHover.w2 = await run(`const id = st().createWindow({ frame: [200, 160, 1200, 700] }); return settle(2500).then(() => id);`);
      const w2 = JSON.stringify(out.peekHover.w2);
      out.peekHover.secondOut = await run(`st().toggleSidebar(${w2}); return settle(600).then(() => globalThis.acLayout.peek["strip:" + ${w2}]?.show()).then(() => settle(500))
        .then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors());`);
      await untilSnapshot(app, "native second window peek monitors", (_, state) => state.windows.some((w) => w.id === out.peekHover.w2 && w.topStrip?.peek?.live === true &&
        w.topStrip.peekMonitors === out.peekHover.secondOut), 8000, { windowId: out.peekHover.w2 });
      out.peekHover.afterClose = await run(`st().closeWindow(${w2}); return settle(1500).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors());`);
      const final = await untilSnapshot(app, "native peek monitors after second window closes", (w, state) => w?.topStrip?.peekMonitors === out.peekHover.afterClose &&
        !state.windows.some((w) => w.id === out.peekHover.w2), 8000, { windowId: undefined });
      assert.equal(nativeWindow(stripRestored).topStrip.peekMonitors, out.peekHover.afterStripBack, "native peek monitors after strip restore");
      assert.equal(nativeWindow(final).topStrip.peekMonitors, out.peekHover.afterClose, "native peek monitors after second window closes");
    }
    const t2 = out.spans.filter(([, , k]) => k !== "SolaraUI.StripNewTabButton").at(-1);
    await run(`return act("w1", "click:${t2[0] + 70},21").then(() => settle(400));`);
    out.clicked = await run(`return st().windows.w1.activeTabIds.default;`);
    await untilSnapshot(app, "clicked native tab", (w) => w?.selectedTabId === out.clicked);
    out.motion = await run(`
      const size = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.groupSize("w1", "g1")` : `() => Promise.resolve(globalThis.acStrip.groupSize("g1"))`};
      const arm = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.traceGroup("w1", "g1")` : `() => Promise.resolve(globalThis.acStrip.traceGroup("g1"))`};
      const trace = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.groupTrace("w1")` : `() => Promise.resolve(globalThis.acStrip.groupTrace())`};
      return size().then((open) => arm().then(() => {
        st().updateGroup("g1", { collapsed: true });
        return settle(800).then(trace).then((samples) => ({ open, samples }));
      }));`);
    if (native) {
      const state = await untilSnapshot(app, "native group trace", (w) => w?.topStrip?.groupTrace?.length > 3, 8000, { stripTrace: "group", fields: ["windows.topStrip"] });
      const trace = nativeWindow(state).topStrip.groupTrace;
      const captured = trace.filter(([t]) => t <= out.motion.samples.at(-1)[0]);
      assert.deepEqual(captured, out.motion.samples, "the native trace holds every JS collapse sample, from the first to the last read");
    }
    await run(`st().updateGroup("g1", { collapsed: false });`);
    if (native) await untilSnapshot(app, "native restored group width", (w) => Number.isFinite(out.motion.open) && w?.topStrip?.groupSizes.g1 === out.motion.open);
    else await run(`return settle(800);`);
    out.room = await run(`
      const key = "g1a,g1b";
      const trace = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.slotTrace("w1")` : `() => Promise.resolve(globalThis.acStrip.slotTrace(key))`};
      const arm = ${native ? `globalThis.expo.modules.SolaraTopStrip.traceSlot("w1", key)` : `Promise.resolve(globalThis.acStrip.traceSlot(key))`};
      const path = ["222,21", "232,21", "640,21", ...Array(4).fill("640,21")].join(";");
      return arm.then(() => postDrag("w1", path)).then(() => settle(150 + 74 * 16 + 700)).then(trace).then((samples) => {
        const moved = st().windows.w1.tabIds.indexOf("t1") > st().windows.w1.tabIds.indexOf("g1b");
        return { moved, samples, tabIds: st().windows.w1.tabIds.slice() };
      });`);
    const dragged = await untilSnapshot(app, "dragged native order", (w) => w.tabIds.includes("t1") && w.tabIds.includes("g1b") &&
      (w.tabIds.indexOf("t1") > w.tabIds.indexOf("g1b")) === out.room.moved);
    assert.deepEqual(nativeWindow(dragged).tabIds, out.room.tabIds);
    if (native) {
      const state = await untilSnapshot(app, "native slot trace", (w) => w?.topStrip?.slotTrace?.length > 3, 8000, { stripTrace: "slot", fields: ["windows.topStrip"] });
      assert.deepEqual(nativeWindow(state).topStrip.slotTrace, out.room.samples.slice(-128));
    }
    await run(`st().placeTabs(["t1"], { pinned: false, beforeId: "g1a" }); return settle(500);`);
    const haptics = await untilSnapshot(app, "final native haptics", () => true, 8000, { fields: ["root.haptics"] });
    assert.equal(haptics.haptics.performed, 0, "hidden drag and swipe paths performed no haptic");
    return { ...out, run, app };
  } catch (e) {
    await app.quit();
    throw e;
  }
}

let rn = null;
let native = null;
try {
  if (only !== "native") {
    rn = await measure(false);
    rep.log(`rn spans ${JSON.stringify(rn.spans)}`);
    await rn.app.quit();
  }
  if (only !== "rn") {
    native = await measure(true);
    rep.log(`native spans ${JSON.stringify(native.spans)}`);
    rep.log(`native items ${JSON.stringify(native.items)}`);
  }
  if (native) {
    await rep.check("native strip entries are the store's", async () => {
      assert.deepEqual(native.keys.slice(0, 4), ["pinned:p1", "pinned:p2", "tab:t1:", "group:g1:0"]);
      assert.ok(native.keys.includes("folder:g3c:fa,fb:g3"), native.keys.join(" "));
      assert.ok(native.keys.includes("split:s1:s1a,s1b:"), native.keys.join(" "));
    });
    await rep.check("a click on a tab selects it", async () => assert.equal(native.clicked, "t2"));
    await rep.check("a click on a group's chip collapses it", async () => {
      const g1 = native.items.items.find((i) => i.kind === "groupChip" && i.id === "g1");
      await native.run(`return act("w1", "click:${g1.windowX + g1.width / 2},21").then(() => settle(500));`);
      assert.equal(await native.run(`return st().groups.g1.collapsed;`), true);
      await untilSnapshot(native.app, "collapsed native group", (w) => w?.topStrip?.groups.some((g) => g.id === "g1" && g.collapsed));
      await native.run(`st().updateGroup("g1", { collapsed: false });`);
    });
    await rep.check("hovering moves nothing", async () => {
      await untilSnapshot(native.app, "native expanded group before hover", (w) => Number.isFinite(native.motion.open) &&
        w?.topStrip?.groups.some((g) => g.id === "g1" && g.collapsed === false) && w.topStrip.groupSizes.g1 === native.motion.open);
      const result = JSON.parse(await native.run(`return globalThis.expo.modules.SolaraTopStrip.hoverShifts("w1");`));
      assert.ok(result.hovered.length > 5, `hovered ${result.hovered.length}`);
      assert.deepEqual(result.shifts, []);
      const state = await untilSnapshot(native.app, "native hover targets", (w) => w?.hoverLayout?.targets.length > 5, 8000, { hoverArea: "topStrip" });
      const baseline = nativeWindow(state).hoverLayout;
      assert.equal(baseline.targets.length, result.hovered.length);
      for (const target of baseline.targets) {
        assert.equal((await native.app.probe("input.hover", { windowId: "w1", area: "topStrip", target, on: true })).delivered, true);
        const during = await untilSnapshot(native.app, "hovered native frames", (w) => !!w?.hoverLayout, 8000, { hoverArea: "topStrip" });
        assert.deepEqual(nativeWindow(during).hoverLayout.frames, baseline.frames);
        assert.equal((await native.app.probe("input.hover", { windowId: "w1", area: "topStrip", target, on: false })).delivered, true);
      }
    });
  }
  if (rn && native) {
    await rep.check("every item spans where RN's does, within 0.5 pt", async () => {
      const show = (s) => s.map(([a, b, k]) => `${a}-${b} ${k}`).join("\n");
      const pressables = native.spans.filter(([, , k]) => k === "groupClose" || k === "SolaraUI.StripNewTabButton");
      assert.equal(pressables.length, 3, show(native.spans));
      const joined = (spans) => spans.reduce((out, s) => (out.length && s[0] - out.at(-1)[1] <= 1 ? (out.at(-1)[1] = s[1], out) : [...out, [...s]]), []);
      const ours = joined(native.spans.filter((s) => !pressables.includes(s)));
      const theirs = joined(rn.spans);
      assert.equal(ours.length, theirs.length, `runs:\nrn\n${show(theirs)}\nnative\n${show(ours)}`);
      const off = ours.flatMap((s, i) => (Math.abs(s[0] - theirs[i][0]) > 0.5 || Math.abs(s[1] - theirs[i][1]) > 0.5 ? [`#${i} rn ${theirs[i]} native ${s}`] : []));
      assert.deepEqual(off, []);
    });
    await rep.check("a click on a tab selects it on RN too", async () => assert.equal(rn.clicked, "t2"));
    await rep.check("the peek's downloads button opens the list and holds the peek out until it closes, as on RN", async () => {
      rep.log(`peek held rn ${JSON.stringify(rn.peekHeld)} native ${JSON.stringify(native.peekHeld)}`);
      assert.match(native.peekHeld.hit, /^SolaraUI\.StripIconButton < SolaraUI\.StripControlsView/, `the native button is under the pointer: ${native.peekHeld.hit}`);
      assert.equal(native.peekHeld.panel, false, "the click presses only the native button, not the address field under it (RN's peek presses both; docs/backlog.md)");
      for (const [name, seen] of [["rn", rn.peekHeld], ["native", native.peekHeld]]) {
        assert.equal(seen.open, true, `${name}: the click opened the downloads list`);
        assert.equal(seen.heldLive, true, `${name}: the open list holds the peek out`);
        assert.equal(seen.afterClose, false, `${name}: closing the list lets the peek go`);
      }
    });
    await rep.check("a press on a tab or the downloads button in the peek presses only that, on RN as on native, and the address field still takes its own press", async () => {
      for (const [name, seen] of [["rn", rn.peekPress], ["native", native.peekPress]]) {
        rep.log(`peek press ${name} ${JSON.stringify(seen)}`);
        const [tab, downloads] = seen.presses;
        assert.equal(tab.active, "g1a", `${name}: the press selected the tab (${tab.hit})`);
        assert.equal(downloads.downloads, true, `${name}: the press opened the downloads list (${downloads.hit})`);
        for (const at of seen.presses) assert.equal(at.panel, false, `${name}: the ${at.what} press also pressed the address field under the peek (${at.hit})`);
        assert.match(seen.fieldHit, /ToolbarUrlFieldView/, `${name}: the field is under the pointer with the peek hidden`);
        assert.equal(seen.field, true, `${name}: a press on the address field with the peek hidden opens the command panel`);
      }
    });
    await rep.check("a two-finger swipe on the peek's strip pages to the next profile, as on RN", async () => {
      rep.log(`peek swipe rn ${JSON.stringify(rn.peekSwipe)} native ${JSON.stringify(native.peekSwipe)}`);
      for (const [name, seen] of [["rn", rn.peekSwipe], ["native", native.peekSwipe]]) {
        assert.equal(seen.profile, "work", `${name}: the swipe paged to the next profile (${JSON.stringify(seen.where)})`);
        assert.equal(seen.live, true, `${name}: the peek stayed out`);
      }
    });
    await rep.check("a link dropped on the peek opens where RN's peek puts it", async () => {
      rep.log(`peek file rn ${JSON.stringify(rn.peekFile)} native ${JSON.stringify(native.peekFile)}`);
      assert.match(native.peekFile.over, /FileDropView/, `the drag is over the peek's drop area: ${native.peekFile.over}`);
      assert.notEqual(rn.peekFile.after, "none", "RN opened the link");
      assert.equal(native.peekFile.after, rn.peekFile.after, "the link lands after the same tab");
      assert.notEqual(rn.peekFile.after, "t2", "RN puts it at the pointer, not at the end");
    });
    await rep.check("the downloads list opens from the peek's button where RN's does", async () => {
      const shown = (edges) => edges.filter((e) => !/^\d+,(60|64) /.test(e)).join("\n");
      assert.ok(rn.downloadsAt.length > 2, `RN's list shows: ${shown(rn.downloadsAt)}`);
      assert.equal(shown(native.downloadsAt), shown(rn.downloadsAt));
    });
    for (const value of [0.25, 0.5, 0.75]) {
      if (!rn.peekFrames?.[value] || !native.peekFrames?.[value]) continue;
      rep.log(`peek at ${value} pixel diff ${JSON.stringify(stripDiff(readPng(rn.peekFrames[value]), readPng(native.peekFrames[value]), 0, 80))}`);
      rep.record(`the peek's pixels match RN's ${value * 100}% of the way out, shadow included`, { skip: peekPending });
    }
    await rep.check("every tooltip along the strip reads and spans as RN's", async () => {
      const show = (runs) => runs.map(([x, t]) => `${x} ${JSON.stringify(t)}`).join("\n");
      assert.ok(rn.labels.tips.filter(([, t]) => t).length > 15, `RN shows tooltips:\n${show(rn.labels.tips)}`);
      assert.deepEqual(native.labels.tips.map(([, t]) => t), rn.labels.tips.map(([, t]) => t), `the same tooltips in order:\nrn\n${show(rn.labels.tips)}\nnative\n${show(native.labels.tips)}`);
      const off = native.labels.tips.flatMap(([x, t], i) => (Math.abs(x - rn.labels.tips[i][0]) <= 1 ? [] : [`${JSON.stringify(t)} from ${x}, RN's from ${rn.labels.tips[i][0]}`]));
      assert.deepEqual(off, []);
    });
    await rep.check("VoiceOver finds every strip item by its name, the selected tab as selected, and the controls", async () => {
      const at = (x) => native.labels.ax.findLast(([u]) => u <= x)?.[1] ?? "";
      const first = (x) => at(x).split(" < ")[0];
      rep.log(`native ax ${native.labels.ax.map(([x, a]) => `${x} ${a.split(" < ")[0]}`).join(" | ")}`);
      const expect = [
        [100, "AXRadioButton|Tab p1|0"],
        [220, "AXRadioButton|t1.example|1"],
        [300, "AXButton|Work|"],
        [420, "AXRadioButton|g1a.example|0"],
        [615, "AXButton|Close Group|"],
        [680, "AXButton|2 Tabs|"],
        [800, "AXRadioButton|Tab s1a|0"],
        [900, "AXRadioButton|Tab s1b|0"],
        [1220, "AXButton|Docs|"],
        [1340, "AXButton|Unmute|"],
        [1380, "AXRadioButton|t2.example|0"],
        [1440, "AXButton|New Tab|"],
        [1500, "AXButton|Personal|"],
        [1575, "AXButton|Downloads|"],
      ];
      const off = expect.flatMap(([x, want]) => (first(x) === want ? [] : [`${x}: ${first(x)}, want ${want}`]));
      assert.deepEqual(off, []);
    });
    await rep.check("the docked strip's controls take the same clicks, swipes and drops as RN's", async () => {
      rep.log(`docked rn ${JSON.stringify(rn.docked)}`);
      rep.log(`docked native ${JSON.stringify(native.docked)}`);
      assert.match(native.docked.edges[0], / item$/, "the row starts on the profile indicator");
      assert.match(native.docked.downloadsHit, /^SolaraUI\.StripIconButton < SolaraUI\.StripControlsView/, `the native button is under the pointer: ${native.docked.downloadsHit}`);
      assert.deepEqual(native.docked.edges, rn.docked.edges, "where the row drags the window, and where it takes clicks");
      assert.equal(native.docked.swipedTo, rn.docked.swipedTo, "a swipe over the controls pages profiles as on RN");
      assert.notEqual(rn.docked.swipedTo, "default", "RN pages on a swipe over its controls");
      assert.equal(native.docked.dropped, rn.docked.dropped, "a link dropped over the controls lands where RN puts it");
    });
    for (const look of ["rest", "hoverDownloads", "hoverName", "pressDownloads", "downloadsOpen", "glow"]) {
      if (!rn.dockedShots?.[look] || !native.dockedShots?.[look]) continue;
      await rep.check(`the docked strip's ${look} pixels match RN's`, async () => {
        const a = readPng(rn.dockedShots[look]), b = readPng(native.dockedShots[look]);
        const right = stripDiff(crop(a, 1440, 1600), crop(b, 1440, 1600), 0, 42, 8);
        const whole = stripDiff(a, b, 0, 42);
        rep.log(`docked ${look} controls ${JSON.stringify(right)} strip ${JSON.stringify(whole)}`);
        assert.ok(right.share < 0.005, `${(right.share * 100).toFixed(2)}% of the controls' pixels differ (worst ${right.worst}, ${right.hot})`);
        if (look !== "rest") {
          const rest = readPng(rn.dockedShots.rest);
          const changed = look === "glow" ? stripDiff(rest, a, 0, 42) : stripDiff(crop(rest, 1440, 1600), crop(a, 1440, 1600), 0, 42, 8);
          assert.ok(changed.share > 0.002, `RN's ${look} looks like its rest state (${JSON.stringify(changed)}), so this compares nothing`);
        }
        assert.ok(whole.share < 0.01, `${(whole.share * 100).toFixed(2)}% of the strip's pixels differ (worst ${whole.worst}, ${whole.hot})`);
      });
    }
    await rep.check("the downloads list opens from the docked button where RN's does", async () => {
      const shown = (edges) => edges.filter((e) => !/^\d+,(60|64) /.test(e)).join("\n");
      assert.ok(rn.dockedDownloadsAt.length > 2, `RN's list shows: ${shown(rn.dockedDownloadsAt)}`);
      assert.equal(shown(native.dockedDownloadsAt), shown(rn.dockedDownloadsAt));
    });
    await rep.check("the drop glow fades on RN's 140 ms out-quad, frame for frame at 30 fps, and turns back mid-fade as RN's does", async () => {
      const quad = (p) => 1 - Math.pow(1 - Math.min(1, Math.max(0, p)), 2);
      const fit = (samples, model) => {
        let best = null;
        const moving = samples[samples.findIndex(([, x]) => x > 0)]?.[0] ?? samples[1][0];
        for (let start = moving - 160; start <= moving + 20; start += 0.25) {
          const error = Math.max(...samples.filter(([t]) => t >= moving).map(([t, x]) => Math.abs(x - model(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const at = (samples, t) => {
        const i = samples.findIndex(([u]) => u >= t);
        if (i <= 0) return i === 0 ? samples[0][1] : samples.at(-1)[1];
        const [ta, xa] = samples[i - 1], [tb, xb] = samples[i];
        return xa + ((xb - xa) * (t - ta)) / (tb - ta);
      };
      const show = (samples) => JSON.stringify(samples.map(([t, x]) => [Math.round(t), Math.round(x * 1000) / 1000]));
      assert.ok(native.glowMotion.full && native.glowMotion.cut, "the native glow can be traced");
      for (const name of ["full", "cut"]) {
        rep.log(`rn glow ${name} ${show(rn.glowMotion[name])}`);
        rep.log(`native glow ${name} ${show(native.glowMotion[name])}`);
      }
      const rising = (samples) => samples.slice(0, samples.findIndex(([, x]) => x >= 0.9999) + 1);
      const falling = (samples) => samples.slice(samples.findLastIndex(([, x]) => x >= 0.9999));
      const theirs = rn.glowMotion.full, ours = native.glowMotion.full;
      for (const [phase, pick, model] of [["in", rising, (ms) => quad(ms / 140)], ["out", falling, (ms) => 1 - quad(ms / 140)]]) {
        const a = fit(pick(theirs), model), b = fit(pick(ours), model);
        const frames = Array.from({ length: 4 }, (_, k) => Math.abs(at(pick(theirs), a.start + ((k + 1) * 1000) / 30) - at(pick(ours), b.start + ((k + 1) * 1000) / 30)));
        rep.log(`glow ${phase}: RN within ${a.error.toFixed(3)} of the curve, native within ${b.error.toFixed(3)}; 30 fps frames differ by ${frames.map((d) => d.toFixed(3)).join(" ")}`);
        assert.ok(pick(ours).length > 3, `${phase}: native traced ${pick(ours).length} samples`);
        assert.ok(b.error <= 0.02, `native's glow ${phase} is ${b.error.toFixed(3)} off RN's 140 ms out-quad`);
        assert.ok(Math.max(...frames) <= 0.05, `${phase}: a 30 fps frame differs by ${Math.max(...frames).toFixed(3)}`);
      }
      const peak = (samples) => Math.max(...samples.map(([, x]) => x));
      const cutRn = rn.glowMotion.cut, cutNative = native.glowMotion.cut;
      rep.log(`glow cut peaks: RN ${peak(cutRn).toFixed(3)} native ${peak(cutNative).toFixed(3)}`);
      assert.ok(peak(cutRn) < 0.98 && peak(cutNative) < 0.98, "both turned back before reaching full");
      assert.ok(Math.abs(peak(cutRn) - peak(cutNative)) <= 0.12, `the glow turns back at ${peak(cutNative).toFixed(3)}, RN's at ${peak(cutRn).toFixed(3)}`);
      assert.equal(cutNative.at(-1)[1], 0, "native's glow ends hidden");
    });
    await rep.check("the peek slides in and out on RN's 180 ms out-cubic, frame for frame at 30 fps", async () => {
      const show = (samples) => JSON.stringify(samples.map(([t, x]) => [Math.round(t), Math.round(x * 1000) / 1000]));
      rep.log(`rn peek ${show(rn.peekMotion)}`);
      rep.log(`native peek ${show(native.peekMotion)}`);
      const phases = (samples) => {
        const top = samples.findIndex(([, x]) => x >= 0.9999);
        const last = samples.findLastIndex(([, x]) => x >= 0.9999);
        return { in: samples.slice(0, top + 1).filter(([, x], i) => i === 0 || x > 0), out: samples.slice(last) };
      };
      const cubic = (p) => 1 - Math.pow(1 - Math.min(1, Math.max(0, p)), 3);
      const models = { in: (ms) => cubic(ms / 180), out: (ms) => 1 - cubic(ms / 180) };
      const fit = (samples, model) => {
        let best = null;
        const moving = samples[1][0];
        for (let start = moving - 200; start <= moving + 20; start += 0.25) {
          const error = Math.max(...samples.slice(1).map(([t, x]) => Math.abs(x - model(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const at = (samples, t) => {
        const i = samples.findIndex(([u]) => u >= t);
        if (i <= 0) return i === 0 ? samples[0][1] : samples.at(-1)[1];
        const [ta, xa] = samples[i - 1], [tb, xb] = samples[i];
        return xa + ((xb - xa) * (t - ta)) / (tb - ta);
      };
      for (const phase of ["in", "out"]) {
        const theirs = phases(rn.peekMotion)[phase], ours = phases(native.peekMotion)[phase];
        assert.ok(theirs.length > 3 && ours.length > 3, `${phase}: traced rn ${theirs.length} native ${ours.length}`);
        const a = fit(theirs, models[phase]), b = fit(ours, models[phase]);
        const frames = Array.from({ length: 6 }, (_, k) => Math.abs(at(theirs, a.start + ((k + 1) * 1000) / 30) - at(ours, b.start + ((k + 1) * 1000) / 30)));
        rep.log(`peek ${phase}: RN within ${a.error.toFixed(3)} of the curve, native within ${b.error.toFixed(3)}; 30 fps frames differ by ${frames.map((d) => d.toFixed(3)).join(" ")}`);
        assert.ok(b.error <= 0.02, `native's slide ${phase} is ${b.error.toFixed(3)} off RN's 180 ms out-cubic`);
        assert.ok(Math.max(...frames) <= 0.05, `${phase}: a 30 fps frame differs by ${Math.max(...frames).toFixed(3)} of the slide`);
      }
    });
    await rep.check("a collapsing group closes on RN's spring, frame for frame", async () => {
      const ours = native.motion.samples, theirs = rn.motion.samples;
      rep.log(`rn motion ${JSON.stringify(theirs.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      rep.log(`native motion ${JSON.stringify(ours.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      assert.equal(native.motion.open, rn.motion.open, "the same open width");
      assert.ok(theirs.length > 3 && ours.length > 3, `traced: rn ${theirs.length} native ${ours.length}`);
      const omega = (2 * Math.PI) / 0.3, zeta = 0.82, damped = omega * Math.sqrt(1 - zeta * zeta);
      const fit = (samples) => {
        const from = samples[0][1], to = samples.at(-1)[1];
        const group = (ms) => (ms <= 0 ? from : to + (from - to) * Math.exp((-zeta * omega * ms) / 1000) * (Math.cos((damped * ms) / 1000) + ((zeta * omega) / damped) * Math.sin((damped * ms) / 1000)));
        let best = null;
        for (let start = 0; start <= 120; start += 0.25) {
          const error = Math.max(...samples.map(([t, x]) => Math.abs(x - group(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const a = fit(theirs), b = fit(ours);
      rep.log(`motion: RN's spring starts at ${a.start} ms and keeps within ${a.error.toFixed(2)} pt of GROUP_SPRING; native's at ${b.start} ms, within ${b.error.toFixed(2)} pt`);
      assert.ok(Math.abs(ours.at(-1)[1] - theirs.at(-1)[1]) < 0.05, `both settle at the same width: rn ${theirs.at(-1)[1]} native ${ours.at(-1)[1]}`);
      assert.ok(a.error <= 2, `RN's own curve is ${a.error.toFixed(2)} pt off GROUP_SPRING`);
      assert.ok(b.error <= 2, `native's curve is ${b.error.toFixed(2)} pt off RN's GROUP_SPRING`);
      assert.ok(b.start - a.start <= 25, `native starts ${b.start - a.start} ms after RN: more than a frame and a half`);
    });
    await rep.check("the strip makes room for a dragged tab on RN's spring, frame for frame", async () => {
      const ours = native.room.samples, theirs = rn.room.samples;
      rep.log(`rn room ${JSON.stringify(theirs.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      rep.log(`native room ${JSON.stringify(ours.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      assert.ok(rn.room.moved && native.room.moved, `the tab landed past the group: rn ${rn.room.moved} native ${native.room.moved}`);
      assert.ok(theirs.length > 3 && ours.length > 3, `traced: rn ${theirs.length} native ${ours.length}`);
      const far = (samples) => samples.reduce((m, [, x]) => (Math.abs(x) > Math.abs(m) ? x : m), 0);
      assert.ok(Math.abs(far(theirs)) > 100 && Math.abs(far(ours) - far(theirs)) < 0.05, `the same room: rn ${far(theirs)} native ${far(ours)}`);
      const room = far(theirs);
      const slide = (t) => (t <= 0 ? 0 : room * (1 - (1 + 0.09 * t) * Math.exp(-0.09 * t)));
      const fit = (samples) => {
        let best = null;
        for (let start = -30; start <= 30; start += 0.25) {
          const error = Math.max(...samples.map(([t, x]) => Math.abs(x - slide(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const a = fit(theirs), b = fit(ours);
      rep.log(`room: RN's spring starts at ${a.start} ms and keeps within ${a.error.toFixed(2)} pt of SLIDE; native's at ${b.start} ms, within ${b.error.toFixed(2)} pt`);
      assert.ok(a.error <= 2, `RN's own curve is ${a.error.toFixed(2)} pt off SLIDE`);
      assert.ok(b.error <= 2, `native's curve is ${b.error.toFixed(2)} pt off RN's SLIDE spring`);
      assert.ok(Math.abs(a.start - b.start) <= 25, `RN starts ${a.start - b.start} ms after native: more than a frame and a half`);
    });
    if (rn.snapshot && native.snapshot) {
      await rep.check("the strips' pixels match RN's", async () => {
        const diff = stripDiff(readPng(rn.snapshot), readPng(native.snapshot), 0, 42);
        rep.log(`pixel diff ${JSON.stringify(diff)}`);
        assert.ok(diff.share < 0.01, `${(diff.share * 100).toFixed(2)}% of the strip's pixels differ (worst ${diff.worst}, ${diff.hot})`);
      });
    }
    await rep.check("with the peek hidden, a drop, a swipe and a click at the top of the window reach what is under it", async () => {
      for (const at of native.hiddenTop.points) {
        rep.log(`hidden peek at ${at.x},${at.y}: ${JSON.stringify(at).slice(0, 400)}`);
        assert.doesNotMatch(at.hit, /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the click at ${at.x},${at.y} reaches ${at.hit}`);
        assert.doesNotMatch(at.drag, /FileDropView/, `the drop at ${at.x},${at.y} goes to ${at.drag}`);
        assert.doesNotMatch(String(at.swipe?.hit), /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the swipe at ${at.x},${at.y} hits ${at.swipe?.hit}`);
        assert.equal(at.profile, "default", `the swipe at ${at.x},${at.y} paged the strip's profiles`);
        assert.equal(at.live, false, "the peek stayed hidden");
      }
    });
    await rep.check("the peek stays out while the pointer is over its native strip, and slides away once it leaves the panel", async () => {
      const seen = native.peekHover;
      rep.log(`peek hover ${JSON.stringify(seen)}`);
      assert.equal(seen.shown, true, "the peek came out");
      assert.match(seen.hit, /^SolaraUI\.Strip/, `the pointer is over the native strip: ${seen.hit}`);
      assert.equal(seen.overStrip, true, "still out over the native strip");
      assert.equal(seen.away, false, "gone once the pointer left the panel");
      assert.deepEqual([seen.afterHide, seen.whileOut, seen.afterStripBack, seen.secondOut, seen.afterClose], [1, 1, 0, 1, 0], "one pointer monitor per window while its strip is hidden, none once the strip comes back or its window closes");
    });
    for (const [look, , , bottom = 42] of LOOKS) {
      if (!rn.looks?.[look] || !native.looks?.[look]) continue;
      const name = `the strips' pixels match RN's, ${{ paging: "halfway through a swipe to the next profile", flipped: "in the other appearance", bands: "with website colour bands", capture: "with a tab sharing its screen, a pinned tab and a grouped tab on camera", peek: "in the peek over a hidden strip" }[look]}`;
      if (look === "peek") {
        await rep.check("the peek over a hidden strip holds the native strip", async () => assert.match(native.peekHit, /^SolaraUI\.Strip/, `the peek holds the native strip: ${native.peekHit}`));
        rep.log(`peek pixel diff ${JSON.stringify(stripDiff(readPng(rn.looks[look]), readPng(native.looks[look]), 0, bottom))}`);
        rep.record(name, { skip: peekPending });
        continue;
      }
      await rep.check(name, async () => {
        const diff = stripDiff(readPng(rn.looks[look]), readPng(native.looks[look]), 0, bottom);
        rep.log(`${look} pixel diff ${JSON.stringify(diff)}`);
        assert.ok(diff.share < 0.01, `${(diff.share * 100).toFixed(2)}% of the strip's pixels differ (worst ${diff.worst}, ${diff.hot})`);
      });
    }
  }
} finally {
  if (native) {
    try { assert.equal((await untilSnapshot(native.app, "native haptics before quit", () => true, 8000, { fields: ["root.haptics"] })).haptics.performed, 0); }
    finally { await native.app.quit(); }
  }
  if (!keep && rep.disposable) for (const name of ["rn", "native", "rn.png", "native.png", ...LOOKS.flatMap(([look]) => [`rn-${look}.png`, `native-${look}.png`]), ...[0.25, 0.5, 0.75].flatMap((v) => [`rn-peek-${v}.png`, `native-peek-${v}.png`])]) rmSync(join(scratch, name), { recursive: true, force: true });
  else rep.say(`kept ${scratch}`);
}
process.exit(rep.summary() ? 0 : 1);
