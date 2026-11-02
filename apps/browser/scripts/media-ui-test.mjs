import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
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
if (!appArg || args.some((arg) => arg.startsWith("--") && !["--shell", "--prompts", "--keep-data"].includes(arg))) {
  console.error(`usage: node media-ui-test.mjs <Debug Solara.app> [--shell | --prompts] [--keep-data]

The media controls on a local tone page: the sidebar player shows for a playing tab that isn't shown, its play
button pauses and plays, Close Player hides it without pausing or moving to the tab, a new play brings it back, Back
to Tab shows the tab and ends the player; the pinned tab's hover player scrolls a long title and ticks its time; the
CLI pill appears and hides with RN's timing (and, under --shell, holds still while the toolbar hides and shows); the cast and share pickers open at RN's size and answer their buttons. The native controls are clicked directly. --shell adds SOLARA_NATIVE_SHELL=1: the pickers
and the CLI pill then live in the pane overlay container on the shell's card, with no RN-hosted NativeMediaView.
--prompts is --shell with the page pool: RN mounts no CliControlPill and the pill comes
from the window's published CLI state. The sidebar and hover players are always native. Every mode but --prompts
pins SOLARA_NATIVE_PAGES_POOL=0, so the page is RN's TabWebView.`);
  process.exit(2);
}
const prompts = args.includes("--prompts");
const shell = prompts || args.includes("--shell");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-media-ui-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "media-ui-test.log"), { name: `media-ui-test${prompts ? " --prompts" : shell ? " --shell" : ""}` });

const LONG_TITLE = "A very long fixture track title that has to scroll in the hover player";
const tone = (() => {
  const rate = 8000;
  const n = rate * 120;
  const wav = Buffer.alloc(44 + n * 2);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + n * 2, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(rate, 24); wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 33), 44 + i * 2);
  return wav;
})();
const server = createServer((req, res) => {
  if (req.url === "/tone.wav") {
    res.writeHead(200, { "content-type": "audio/wav", "content-length": String(tone.length) });
    return res.end(tone);
  }
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  if (name === "player")
    return res.end(`<!doctype html><title>Player</title><link rel="icon" href="data:,"><audio id="tone" src="/tone.wav" loop></audio>
<script>navigator.mediaSession.metadata = new MediaMetadata({ title: ${JSON.stringify(LONG_TITLE)}, artist: "Fixture Artist" });</script>`);
  res.end(`<!doctype html><title>${name.toUpperCase()}</title><link rel="icon" href="data:,"><body>${name}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "p" } }],
  tabs: [{ id: "p", url: url("player"), title: "Player", pinned: true, pinnedUrl: url("player") }, { id: "b", url: url("b"), title: "B" }],
  settings: { sidebarMediaControls: true, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const shown = () => st().windows.w1.activeTabIds[st().windows.w1.profileId];
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const probe = (kind) => (M ? M.probe(kind, "w1").then(JSON.parse) : Promise.resolve([]));
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const hover = ([x, y]) => ac.shell.devSetPointer("w1", { x, y }).then(() => act("mouse:moved:" + x + "," + y));
const click = (p) => hover(p).then(() => settle(60)).then(() => act("mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act("mouse:up:" + p[0] + "," + p[1]));
const playerShown = () => probe("media.sidebarPlayer").then((rows) => rows.length);
const first = (kind) => probe(kind).then((rows) => rows[0] || null);
const session = () => acMedia.useMedia.getState().sessions.p;
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const pane = (kind) => M.describePaneOverlays("w1").then(JSON.parse).then((d) => ({ top: d.top, inCard: d.inCard, entry: Object.values(d.tabs).map((t) => t[kind]).find(Boolean) ?? null }));
const hosted = (kind) => acPerf.findFibers("NativeMediaView", 200).filter((f) => f.memoizedProps?.kind === kind).length;
`;
let app = null;
const run = (body, timeout = 20000) => evaluate(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const untilSnapshot = async (what, accept, ms = 5000, windowId = "w1") => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: app exited`);
    if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
    last = await app.snapshot({ windowId, fields: ["windows.media", "windows.mediaKinds", "windows.paneOverlays", "windows.hoverCard", "windows.selectedTabId", "windows.contentFrame"] }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    assert.ok(Buffer.byteLength(JSON.stringify(last)) + 256 < 64 * 1024, "native snapshot reply exceeds 64 KiB");
    if (Date.now() < end && !last.error && last.consistent && await acceptSnapshot(end, accept, last.windows.find((w) => w.id === windowId), last) && Date.now() < end) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const nearRect = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => Number.isFinite(v) && Number.isFinite(b[i]) && Math.abs(v - b[i]) <= 0.5);
const mediaRow = (window, kind) => window?.media?.[kind]?.[0];
const selected = (state) => state.windows.find((w) => w.id === "w1")?.selectedTabId;

const sameMediaRows = (native, js, what) => {
  assert.equal(native?.length, js.length, `${what} row count`);
  for (let i = 0; i < js.length; i++) {
    const ours = native[i], theirs = js[i];
    for (const key of ["frame", "card"]) if (key in theirs) assert.ok(nearRect(ours[key], theirs[key]), `${what} ${key}`);
    for (const [key, frame] of Object.entries(theirs.frames ?? {})) assert.ok(nearRect(ours.frames?.[key], frame), `${what} ${key} frame`);
    for (const key of ["stopClipped", "shown", "corners", "artwork", "selected", "primary", "hovered", "labels"])
      if (key in theirs) assert.deepEqual(ours[key], theirs[key], `${what} ${key}`);
    for (const key of ["height", "titleOverflow", "artistOverflow"])
      if (key in theirs) assert.ok(Number.isFinite(ours[key]) && Math.abs(ours[key] - theirs[key]) <= 0.5, `${what} ${key}`);
  }
};
const readMedia = (kind) => run(`return probe(${JSON.stringify(kind)});`);
const crossCheckMedia = async (what, kind, rows, windowId = "w1", read = null) => {
  const state = await untilSnapshot(what, async (window) => {
    const live = read ? await read() : await readMedia(kind);
    try {
      sameMediaRows(window?.media?.[kind], live, what);
      sameMediaRows(window?.media?.[kind], rows, what);
      return true;
    } catch {
      return false;
    }
  }, 5000, windowId);
  sameMediaRows(state.windows.find((w) => w.id === windowId).media[kind], rows, what);
  return state;
};

function readPng(path) {
  const buf = readFileSync(path);
  assert.deepEqual(buf.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), "PNG signature");
  let width = 0, height = 0, channels = 0;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    assert.ok(at + 12 + length <= buf.length, "PNG chunk bounds");
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
      assert.equal(buf[at + 16], 8, "PNG bit depth");
      assert.equal(buf[at + 20], 0, "noninterlaced PNG");
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  assert.ok(width > 0 && height > 0 && channels, "RGB or RGBA PNG dimensions");
  const stride = width * channels;
  const raw = inflateSync(Buffer.concat(idat));
  assert.equal(raw.length, (stride + 1) * height, "PNG scanline size");
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    assert.ok(filter <= 4, "PNG scanline filter");
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

function controlInk(image, frame, scale) {
  assert.ok(frame?.length === 4 && frame.every(Number.isFinite), "control frame");
  const [x, y, width, height] = frame;
  const left = Math.ceil((x + 2) * scale), top = Math.ceil((y + 2) * scale);
  const right = Math.floor((x + width - 2) * scale), bottom = Math.floor((y + height - 2) * scale);
  assert.ok(left >= 0 && top >= 0 && right <= image.width && bottom <= image.height && right > left && bottom > top, "control inside capture");
  const colors = new Map();
  for (let py = top; py < bottom; py++) for (let px = left; px < right; px++) {
    const at = (py * image.width + px) * image.channels;
    const color = Array.from(image.data.subarray(at, at + image.channels)).join(",");
    colors.set(color, (colors.get(color) ?? 0) + 1);
  }
  const background = [...colors].sort((a, b) => b[1] - a[1])[0][0].split(",").map(Number);
  let ink = 0;
  for (const [color, count] of colors) if (color.split(",").some((v, i) => Math.abs(Number(v) - background[i]) > 8)) ink += count;
  assert.ok(ink > 0, `control has no non-background ink: ${JSON.stringify(frame)}`);
  return ink;
}

const capturePlayerInk = async (state) => {
  const window = state.windows.find((w) => w.id === "w1");
  const row = mediaRow(window, "media.sidebarPlayer");
  assert.equal(row.corners, true, "corner controls are visible for capture");
  const capture = await app.probe("view.capture", { windowId: "w1" }, { timeout: 20000 });
  assert.match(capture.artifact, /^\.solara-probe-window-[a-f0-9-]+\.png$/);
  assert.ok(Number.isFinite(capture.scale) && capture.scale > 0, "capture scale");
  const image = readPng(join(app.data, capture.artifact));
  assert.deepEqual([image.width, image.height], [capture.width, capture.height], "decoded capture size");
  assert.deepEqual([image.width, image.height], [window.contentFrame.width, window.contentFrame.height].map((v) => Math.trunc(v * capture.scale)), "window content capture size");
  const ink = {};
  for (const name of ["play", "art", "seek", "title", "close", "mute"]) ink[name] = controlInk(image, row.frames[name], capture.scale);
  return { artifact: capture.artifact, scale: capture.scale, ink };
};

const inPage = async (expression) => {
  const page = await app.page(url("player"));
  try {
    return await page.eval(expression, { userGesture: true });
  } finally {
    page.close();
  }
};
const paused = async () => (await inPage("document.getElementById('tone').paused")) === true;
const pressPlayer = async (control) => {

  return run(`return first("media.sidebarPlayer").then((row) => { if (!row) throw new Error("no native player"); return click(centre(row.frames[${JSON.stringify(control)}])); }).then(() => true);`);
};

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_ALLOW_AUDIO: "1", SOLARA_NATIVE_SHELL: shell ? "1" : "0",
      ...(prompts ? { SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" } : { SOLARA_NATIVE_PAGES_POOL: "0" }) },
    switches: "--disable-audio-output --autoplay-policy=no-user-gesture-required",
    ready: "return !!ac.store.getState().windows.w1",
  });

  await rep.check("native-kinds", async () => {
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
    const want = ["media.cliPill", "media.hoverPlayer", "media.sidebarPlayer"];
    const have = want.filter((k) => kinds.includes(k));
    if (have.length !== want.length) throw new Error(`native kinds missing: ${JSON.stringify(kinds)}`);
    await untilSnapshot("registered native media kinds", async (window) => {
      const live = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
      return !!window && want.every((kind) => window.mediaKinds.includes(kind) === live.includes(kind) && live.includes(kind) === kinds.includes(kind));
    });
    for (const kind of ["media.sidebarPlayer", "media.hoverPlayer", "media.cliPill", "media.castPicker", "media.sharePicker", "media.shareBar", "littleSolara.bar"]) {
      const rows = await run(`return probe(${JSON.stringify(kind)});`);
      await crossCheckMedia(`${kind} initial rows`, kind, rows);
    }
    return { kinds: have };
  });

  if (prompts) await rep.check("share-picker-escape-at-launch", async () => {
    const request = { id: "share-at-launch", origin: "https://meet.test", frameOrigin: null, audio: { tab: true, screen: false, window: null },
      sources: [{ id: "screen:fixture", kind: "screen", name: "Fixture Display", width: 1512, height: 982 }], pageUrl: url("b") };
    await run(`ac.actions.switchToTab("b"); acMedia.useMedia.setState((m) => ({ displayRequests: { ...m.displayRequests, b: ${JSON.stringify(request)} } })); return true;`);
    try {
      await until("share picker focused", `return first("media.sharePicker").then((r) => r && r.opacity > 0.99 && r.focused ? true : null);`, 5000);
      await run(`globalThis.__shareLog = []; const a = acNativeMedia.actions; globalThis.__shareReal = a.sharePicker; a.sharePicker = (w, t, e) => { __shareLog.push(e.action); }; return true;`);
      try {
        await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\r", keyCode: 36, modifiers: [], send: true, asKey: true, wait: 30 }).then(() => true);`);
        await until("Return reaches the first share picker after launch", `return __shareLog.includes("share") || null;`, 3000);
      } finally {
        await run(`acNativeMedia.actions.sharePicker = __shareReal; return true;`);
      }
      await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u001b", keyCode: 53, modifiers: [], send: true, asKey: true, wait: 30 }).then(() => true);`);
      await until("Escape cancels the first share picker after launch", `return !acMedia.useMedia.getState().displayRequests.b;`, 3000);
    } finally {
      await run(`acMedia.useMedia.setState((m) => { const { b, ...rest } = m.displayRequests; return { displayRequests: rest }; }); ac.actions.switchToTab("p"); return true;`);
    }
    return true;
  });

  await rep.check("sidebar-player-shows", async () => {
    await until("player page loaded", `return st().tabs.p?.title === "Player" && !st().live.p?.isLoading;`, 15000);
    await inPage("document.getElementById('tone').play().then(() => true)");
    await until("session playing", `return session()?.playbackState === "playing" && session()?.controllable;`, 10000);
    await run(`ac.actions.switchToTab("b"); return true;`);
    const count = await until("sidebar player", `return playerShown().then((n) => n || null);`, 6000);
    const rows = await run(`return probe("media.sidebarPlayer");`);
    await crossCheckMedia("sidebar player rows and labels", "media.sidebarPlayer", rows);
    assert.equal(rows[0].labels.play, "Pause");
    assert.equal(rows[0].labels.close, "Close Player");
    assert.equal(rows[0].labels.art, "Back to Tab");
    if (rows[0].height !== 74) throw new Error(`player height ${rows[0].height}, RN draws 74`);
    await untilSnapshot("sidebar player", async (window) => {
      const live = await run(`return probe("media.sidebarPlayer");`);
      const row = mediaRow(window, "media.sidebarPlayer");
      return row?.height === live[0]?.height && row?.height === rows[0].height && Object.keys(rows[0].frames).every((name) => nearRect(row.frames[name], live[0].frames[name]) && nearRect(row.frames[name], rows[0].frames[name]));
    });
    if (await run(`return hosted("media.sidebarPlayer");`)) throw new Error("RN hosts a sidebar player beside the native column's");
    return { count, height: rows?.[0]?.height };
  });

  await rep.check("play-pause", async () => {
    await pressPlayer("play");
    await until("paused", `return session()?.playbackState === "paused";`, 6000);
    if (!(await paused())) throw new Error("the page kept playing");
    const pausedRows = await run(`return probe("media.sidebarPlayer");`);
    await crossCheckMedia("paused player labels", "media.sidebarPlayer", pausedRows);
    assert.equal(pausedRows[0].labels.play, "Play");
    await pressPlayer("play");
    await until("playing", `return session()?.playbackState === "playing";`, 6000);
    const playingRows = await run(`return probe("media.sidebarPlayer");`);
    await crossCheckMedia("playing player labels", "media.sidebarPlayer", playingRows);
    assert.equal(playingRows[0].labels.play, "Pause");
    return { paused: await paused() };
  });

  await rep.check("close-keeps-playing", async () => {
    await run(`return first("media.sidebarPlayer").then((row) => hover(centre(row.frames.title))).then(() => true);`);
    await until("corner buttons on hover", `return first("media.sidebarPlayer").then((row) => row?.corners || null);`, 3000);
    const rows = await run(`return probe("media.sidebarPlayer");`);
    assert.equal(rows[0].corners, true);
    const state = await crossCheckMedia("hovered sidebar player rows", "media.sidebarPlayer", rows);
    const capture = await capturePlayerInk(state);
    await pressPlayer("close");
    await until("player gone", `return playerShown().then((n) => n === 0);`, 4000);
    await sleep(500);
    const still = { paused: await paused(), shown: await run(`return shown();`) };
    if (still.paused) throw new Error("closing the player paused playback");
    if (still.shown !== "b") throw new Error(`closing the player moved to tab ${still.shown}`);
    await untilSnapshot("player closes without switching", async (window, state) =>
      selected(state) === await run(`return shown();`) && selected(state) === still.shown && window.media["media.sidebarPlayer"].length === 0);
    return { ...still, capture };
  });

  await rep.check("new-play-brings-it-back", async () => {
    await inPage("document.getElementById('tone').pause(), true");
    await until("paused", `return session()?.playbackState === "paused";`, 6000);
    await inPage("document.getElementById('tone').play().then(() => true)");
    const count = await until("player again", `return playerShown().then((n) => n || null);`, 6000);
    await untilSnapshot("player returns", async (window) => window?.media?.["media.sidebarPlayer"]?.length === await run(`return playerShown().then((n) => n || null);`) && window?.media?.["media.sidebarPlayer"]?.length === count);
    return count;
  });

  await rep.check("back-to-tab", async () => {
    await pressPlayer("art");
    await until("tab shown", `return shown() === "p";`, 4000);
    await until("player ends", `return playerShown().then((n) => n === 0);`, 4000);
    await untilSnapshot("back to playing tab", (window, state) => selected(state) === "p" &&
      window.media["media.sidebarPlayer"].length === 0);
    return { paused: await paused() };
  });

  await rep.check("hover-player", async () => {
    await run(`ac.actions.switchToTab("b"); return true;`);
    await run(`return Promise.resolve(acMediaHover("w1", "p")).then(() => true);`);

    const card = () => `return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1").then(JSON.parse)`;
    if (shell) {
      const shownCard = await until("the native column's hover player", `${card()}.then((c) => c && c.kind === "player" && c.phase === "shown" ? c : null);`, 3000);
      if (await run(`return hosted("media.hoverPlayer");`)) throw new Error("RN hosts a hover player beside the native card");
      await untilSnapshot("sidebar hover player card", async (window) => {
        const live = await run(`${card()}.then((c) => c && c.kind === "player" && c.phase === "shown" ? c : null);`);
        return window?.hoverCard?.kind === live?.kind && nearRect(window?.hoverCard?.frame, live?.frame)
          && window?.hoverCard?.kind === shownCard.kind && nearRect(window.hoverCard.frame, shownCard.frame);
      });
      const rows = await run(`return probe("media.hoverPlayer");`);
      assert.ok(rows.length > 0, "native column hover player rows");
      await crossCheckMedia("native column hover player rows and labels", "media.hoverPlayer", rows);
      assert.equal(rows[0].labels.play, "Pause");
    }
    const first = await until("native hover player", `return first("media.hoverPlayer");`, 3000);
    await crossCheckMedia("hover player initial rows and labels", "media.hoverPlayer", [first]);
    assert.equal(first.labels.play, "Pause");
    if (!(first.titleOverflow > 0)) throw new Error(`the long title doesn't overflow: ${JSON.stringify(first)}`);
    await sleep(2600);
    const later = (await run(`return probe("media.hoverPlayer");`))[0];
    await crossCheckMedia("hover player later rows and labels", "media.hoverPlayer", [later]);
    const max = Math.max(later.titleOverflow, later.artistOverflow);
    const expected = Math.max(0, Math.min(1, ((later.t - first.t - 1.5) * 30) / max));
    if (!(Math.abs(later.marquee - expected) <= 0.1)) throw new Error(`marquee at ${later.marquee}, RN would be near ${expected}`);
    if (!/^\d+:\d\d$/.test(first.elapsed) || !/^\d+:\d\d$/.test(later.elapsed) || later.elapsed === first.elapsed) throw new Error(`time stood still at ${later.elapsed}`);
    await untilSnapshot("hover player marquee", async (window) => {
      const live = (await run(`return probe("media.hoverPlayer");`))[0];
      const row = mediaRow(window, "media.hoverPlayer");
      return row?.titleOverflow === live?.titleOverflow && row?.titleOverflow === later.titleOverflow && row.elapsed >= first.elapsed
        && Math.abs(row.marquee - live.marquee) <= 0.1 && Math.abs(row.marquee - later.marquee) <= 0.1;
    });
    await run(`return Promise.resolve(acMediaHover("w1", null)).then(() => true);`);
    await until("hover player gone", `return first("media.hoverPlayer").then((r) => !r);`, 3000);
    if (shell) await until("hover player card hidden", `${card()}.then((c) => !c || c.phase === "hidden");`, 3000);
    await sleep(300);
    if (await paused()) throw new Error("hiding the hover player paused playback");
    const after = await run(`return shown();`);
    if (after !== "b") throw new Error(`hiding the hover player moved to tab ${after}`);
    return { overflow: later.titleOverflow, marquee: later.marquee, expected, elapsed: [first.elapsed, later.elapsed] };
  });

  const inPane = async (kind, entry) => {
    if (!shell) return null;
    const where = await run(`return pane(${JSON.stringify(entry)}).then((p) => ({ ...p, hosted: hosted(${JSON.stringify(kind)}) }));`);
    if (!where.entry) throw new Error(`no ${entry} in the pane overlays: ${JSON.stringify(where)}`);
    if (!where.top || !where.inCard) throw new Error(`the overlay container is not the card's top child: ${JSON.stringify(where)}`);
    if (where.hosted) throw new Error(`RN still hosts a NativeMediaView for ${kind}`);
    await untilSnapshot(`${entry} pane placement`, async (window) => {
      const live = await run(`return pane(${JSON.stringify(entry)}).then((p) => ({ ...p, hosted: hosted(${JSON.stringify(kind)}) }));`);
      const pane = window?.paneOverlays;
      const nativeEntry = pane && Object.values(pane.tabs ?? {}).map((tab) => tab[entry]).find(Boolean);
      return pane?.top === live.top && pane?.inCard === live.inCard && pane?.top === where.top && pane?.inCard === where.inCard && nativeEntry &&
        nearRect(nativeEntry.frame, live.entry?.frame) && nearRect(nativeEntry.frame, where.entry.frame);
    });
    return { inCard: true };
  };
  await rep.check("cli-pill-timing", async () => {

    const samples = await run(`
      const indicator = globalThis.acCli.indicator;
      const out = [];
      const sample = (until) => performance.now() >= until ? Promise.resolve() : first("media.cliPill").then((row) => { if (row) out.push(row); return settle(16); }).then(() => sample(until));
      indicator.setState({ shown: true });
      return sample(performance.now() + 260).then(() => { indicator.setState({ shown: false }); return sample(performance.now() + 320); }).then(() => out);`, 10000);
    const on = samples.filter((s) => s.shown);
    const off = samples.filter((s) => !s.shown);
    if (!on.length || !off.length) throw new Error(`no samples: ${JSON.stringify(samples.slice(0, 3))}`);
    const peak = Math.max(...on.map((s) => s.opacity));
    if (peak < 0.99) throw new Error(`never fully shown: ${peak}`);
    if (off.at(-1).opacity > 0.01) throw new Error(`still visible 320 ms after hiding: ${off.at(-1).opacity}`);
    if (on[0].opacity > 0.9) throw new Error(`appeared at once instead of animating in: ${on[0].opacity}`);
    const left = await run(`return settle(100).then(() => first("media.cliPill"))`);
    if (left) throw new Error(`a hidden pill stays mounted: ${JSON.stringify(left)}`);
    await untilSnapshot("CLI pill unmounted", (window) => window?.media?.["media.cliPill"]?.length === 0);
    await run(`globalThis.acCli.indicator.setState({ shown: true }); return true;`);
    try {
      const pill = await until("CLI pill row at rest", `return first("media.cliPill").then((r) => r && r.opacity > 0.99 ? r : null);`, 3000);
      await crossCheckMedia("CLI pill rows and labels at rest", "media.cliPill", [pill]);
      assert.equal(pill.shown, true);
      assert.equal(pill.stopClipped, false);
      assert.equal(pill.labels.stop, "Stop");
    } finally {
      await run(`globalThis.acCli.indicator.setState({ shown: false }); return true;`);
      await sleep(320);
    }
    const pane = await (async () => {
      if (!shell) return null;
      await run(`globalThis.acCli.indicator.setState({ shown: true }); return true;`);
      try {
        const where = await inPane("media.cliPill", "cliPill");
        if (prompts && (await run(`return acPerf.findFibers("CliControlPill", 5).length;`))) throw new Error("RN still mounts CliControlPill");
        return where;
      } finally {
        await run(`globalThis.acCli.indicator.setState({ shown: false }); return true;`);
      }
    })();
    return { samples: samples.length, frame: on.at(-1).frame, peak, pane };
  });
  await rep.check("cli-pill-auto-hide", async () => {
    if (!shell) return { skipped: "RN-hosted: the pill rides RN's native-driver transforms, which its AppKit frame doesn't show" };
    await run(`ac.store.getState().updateSettings({ hideToolbarWhileScrolling: true }); globalThis.acCli.indicator.setState({ shown: true }); return true;`);
    try {
      await until("pill shown", `return first("media.cliPill").then((r) => r && r.opacity > 0.99 ? r : null);`, 3000);
      await sleep(600);
      const pill = await run(`return first("media.cliPill");`);
      await crossCheckMedia("CLI pill before toolbar slide", "media.cliPill", [pill]);
      const rest = pill.frame;
      await untilSnapshot("CLI pill frame", async (window) => {
        const live = await run(`return first("media.cliPill");`);
        const row = mediaRow(window, "media.cliPill");
        return row?.opacity > 0.99 && nearRect(row.frame, live?.frame) && nearRect(row.frame, rest);
      });
      const { frames, tops } = await run(`
        const out = [];
        const tops = [];
        const page = () => ${prompts} ? Promise.resolve(tops.push(ac.store.getState().tabs[shown()] ? 0 : -1)) : measure(acPerf.findFibers("TabWebView", 50).find((f) => !!f.child && f.memoizedProps.tabId === shown())).then((r) => tops.push(r[1]));
        const sample = (until) => performance.now() >= until ? Promise.resolve() : first("media.cliPill").then((r) => { out.push(r.frame); return settle(8); }).then(() => sample(until));
        return page().then(() => { ac.toolbarAutoHide.noteScroll(shown(), { state: "down" }); return sample(performance.now() + 700); }).then(page)
          .then(() => { ac.toolbarAutoHide.noteScroll(shown(), { state: "up" }); return sample(performance.now() + 700); }).then(page).then(() => ({ frames: out, tops }));`, 10000);
      if (!prompts && (!(tops[1] < tops[0]) || tops[2] !== tops[0])) throw new Error(`the toolbar never hid and came back: page tops ${JSON.stringify(tops)}`);
      const off = frames.filter((f) => !nearRect(f, rest));
      if (off.length) throw new Error(`the pill moved off ${JSON.stringify(rest)} while the toolbar slid: ${JSON.stringify(off.slice(0, 5))}`);
      const slid = await run(`return M.describePaneOverlays("w1").then(JSON.parse).then((d) => d.tabs[shown()].cliPill.frame);`);
      const tabId = await run(`return shown();`);
      await untilSnapshot("CLI pill slot after toolbar slide", async (window) => {
        const live = await run(`return M.describePaneOverlays("w1").then(JSON.parse).then((d) => d.tabs[shown()].cliPill.frame);`);
        return nearRect(window?.paneOverlays?.tabs?.[tabId]?.cliPill?.frame, live)
          && nearRect(window?.paneOverlays?.tabs?.[tabId]?.cliPill?.frame, slid);
      });
      return { rest, samples: frames.length, pageTops: tops, slot: slid };
    } finally {
      await run(`globalThis.acCli.indicator.setState({ shown: false }); ac.store.getState().updateSettings({ hideToolbarWhileScrolling: false }); return true;`);
      await sleep(400);
    }
  });
  const CAST_FRAME = [925, 55, 340, 185];
  const SHARE_FRAME = [501.5, 55, 460, 423];
  const sameRect = (what, rect, want) => {
    if (!nearRect(rect, want)) throw new Error(`${what} popover at ${JSON.stringify(rect)}, RN draws ${JSON.stringify(want)}`);
  };
  const staysUp = async (kind) => {
    const gaps = await run(`
      const out = [];
      const sample = (until) => performance.now() >= until ? Promise.resolve() : first(${JSON.stringify(kind)}).then((r) => { if (!r) out.push(Math.round(performance.now())); return settle(50); }).then(() => sample(until));
      return sample(performance.now() + 2700).then(() => out);`, 10000);
    if (gaps.length) throw new Error(`${kind} went missing ${gaps.length} times in its first 2.7 s`);
    return true;
  };
  const openPopover = async (kind, open) => {

    const samples = await run(`
      const out = [];
      const sample = (until) => performance.now() >= until ? Promise.resolve() : first(${JSON.stringify(kind)}).then((r) => { if (r) out.push(r); return settle(8); }).then(() => sample(until));
      ${open}
      return sample(performance.now() + 400).then(() => out);`, 10000);
    const last = samples.at(-1);
    if (!last) throw new Error("no native popover");
    const moving = samples.filter((r) => r.opacity > 0.02 && r.opacity < 0.98);
    if (!moving.length) throw new Error(`the popover never animated in: ${JSON.stringify(samples.map((r) => r.opacity))}`);
    const hidden = samples.filter((r) => r.opacity <= 0.02);
    const shownAt = Math.min(...moving.map((r) => r.t));
    const span = Math.max(...moving.map((r) => r.t)) - (hidden.length ? Math.max(...hidden.map((r) => r.t)) : shownAt);
    const delay = shownAt - samples[0].t;
    if (span > 0.17) throw new Error(`open took ${span}s, RN's is 0.15: ${JSON.stringify(samples.map((r) => [Math.round((r.t - samples[0].t) * 1000), r.opacity, r.progress, r.height]))}`);
    if (delay > 0.05) throw new Error(`the popover waited ${delay}s before animating: ${JSON.stringify(samples.map((r) => [r.t - samples[0].t, r.opacity, r.height]))}`);
    for (const r of moving) {
      if (Math.abs(r.opacity - r.progress) > 0.08) throw new Error(`opacity ${r.opacity} at progress ${r.progress}`);
    }
    if (last.opacity < 0.999) throw new Error(`popover still at ${last.opacity} after 400 ms`);
    await crossCheckMedia(`${kind} rows and labels at rest`, kind, [last]);
    return { rect: last.card, frames: last.frames, height: last.height, labels: last.labels, animatedSamples: moving.length };
  };
  const CAST = {
    id: "cast-fixture", browserId: 0, open: true, header: "Cast tab", permissionRejected: false,
    sinks: [
      { id: "s1", name: "Living Room", state: "available", modes: 1, icon: 0, status: "", issue: "" },
      { id: "s2", name: "Kitchen Speaker", state: "connected", routeId: "r2", modes: 1, icon: 2, status: "Casting Player", issue: "" },
    ],
  };
  await rep.check("cast-picker", async () => {
    const opened = await openPopover("media.castPicker", `acCast.useCast.setState({ dialogs: { b: ${JSON.stringify(CAST)} } });`);
    sameRect("cast", opened.rect, CAST_FRAME);
    assert.equal(opened.labels.done, "Done");
    assert.equal(opened.labels.stop1, "Stop");
    await untilSnapshot("cast picker card", async (window) => {
      const live = (await readMedia("media.castPicker"))[0];
      const row = mediaRow(window, "media.castPicker");
      return row?.opacity > 0.99 && nearRect(row.card, live?.card) && nearRect(row.card, opened.rect) &&
        Object.keys(opened.frames).every((name) => nearRect(row.frames[name], live.frames[name]) && nearRect(row.frames[name], opened.frames[name]));
    });
    const out = { rect: opened.rect, samples: opened.animatedSamples, pane: await inPane("media.castPicker", "castPicker") };
    if (shell) out.staysUp = await staysUp("media.castPicker");
    await run(`globalThis.__castLog = []; const a = acNativeMedia.actions; globalThis.__castReal = a.castPicker; a.castPicker = (w, t, e) => { __castLog.push(e); }; return true;`);
    await run(`return first("media.castPicker").then((r) => click(centre(r.frames.done))).then(() => true);`);
    await run(`return first("media.castPicker").then((r) => click(centre(r.frames.sink0))).then(() => true);`);
    await run(`return first("media.castPicker").then((r) => click([Math.round(r.card[0] - 200), Math.round(r.card[1] + 100)])).then(() => true);`);
    const log = await until("cast actions", `return __castLog.length >= 3 ? __castLog : null;`, 3000);
    await run(`acNativeMedia.actions.castPicker = __castReal; return true;`);
    if (log.map((e) => e.action).join() !== "done,cast,dismiss" || log[1].sinkId !== "s1") throw new Error(`cast actions ${JSON.stringify(log)}`);
    out.actions = log.map((e) => e.action);
    await run(`acCast.useCast.setState({ dialogs: {} }); return true;`);
    return out;
  });

  const SHARE = {
    id: "share-fixture", origin: "https://meet.test", frameOrigin: null, audio: { tab: true, screen: false, window: null },
    sources: [
      { id: "screen:fixture", kind: "screen", name: "Fixture Display", width: 1512, height: 982 },
      { id: "window:fixture", kind: "window", name: "Fixture Notes", app: "Notes" },
    ],
    pageUrl: url("b"),
  };
  const openShare = `acMedia.useMedia.setState((m) => ({ displayRequests: { ...m.displayRequests, b: ${JSON.stringify(SHARE)} } }));`;
  await rep.check("share-picker", async () => {
    const opened = await openPopover("media.sharePicker", openShare);
    sameRect("share", opened.rect, SHARE_FRAME);
    assert.equal(opened.labels.share, "Share");
    assert.equal(opened.labels.cancel, "Cancel");
    await untilSnapshot("share picker card", async (window) => {
      const live = (await readMedia("media.sharePicker"))[0];
      const row = mediaRow(window, "media.sharePicker");
      return row?.opacity > 0.99 && nearRect(row.card, live?.card) && nearRect(row.card, opened.rect) &&
        Object.keys(opened.frames).every((name) => nearRect(row.frames[name], live.frames[name]) && nearRect(row.frames[name], opened.frames[name]));
    });
    const out = { rect: opened.rect, samples: opened.animatedSamples, pane: await inPane("media.sharePicker", "sharePicker") };
    if (shell) out.staysUp = await staysUp("media.sharePicker");
    await run(`return first("media.sharePicker").then((r) => click(centre(r.frames["tab:p"]))).then(() => true);`);
    const picked = await until("tab selected", `return first("media.sharePicker").then((r) => r.selected === "tab:p" ? r : null);`, 3000);
    await crossCheckMedia("share picker selected rows and labels", "media.sharePicker", [picked]);
    out.focused = picked.focused;
    await untilSnapshot("share picker selection", async (window) => {
      const live = (await readMedia("media.sharePicker"))[0];
      const row = mediaRow(window, "media.sharePicker");
      return row?.selected === live?.selected && row?.selected === picked.selected && row.focused === live.focused && row.focused === picked.focused && !!row.frames.audio;
    });
    if (!picked.frames.audio) throw new Error("no tab audio checkbox for a tab");
    if (!picked.focused) throw new Error("the share picker doesn't hold focus for Escape and Enter");
    if (shell) {
      await run(`ac.actions.switchToTab("p"); return true;`);
      await until("share picker off screen", `return first("media.sharePicker").then((r) => !r || !r.focused ? true : null);`, 3000);
      await run(`ac.actions.switchToTab("b"); return true;`);
      const back = await until("share picker focused again", `return first("media.sharePicker").then((r) => r && r.focused ? r : null);`, 3000);
      out.refocused = back.focused;
      await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\u001b", keyCode: 53, modifiers: [], send: true, asKey: true, wait: 30 }).then(() => true);`);
      await until("Escape cancels after the round trip", `return !acMedia.useMedia.getState().displayRequests.b;`, 3000);
      await run(`${openShare} return true;`);
      await until("share picker reopened", `return first("media.sharePicker").then((r) => r && r.opacity > 0.99 && r.focused ? r : null);`, 3000);
    }
    await run(`return first("media.sharePicker").then((r) => click(centre(r.frames.cancel))).then(() => true);`);
    await until("share request ends", `return !acMedia.useMedia.getState().displayRequests.b;`, 3000);
    await run(`${openShare} return true;`);
    const again = await until("share picker again", `return first("media.sharePicker").then((r) => r && r.opacity > 0.99 ? r : null);`, 3000);
    const below = [Math.round(again.card[0] + again.card[2] / 2), Math.round(again.card[1] + again.card[3] + 40)];
    await run(`return click(${JSON.stringify(below)}).then(() => true);`);
    await until("share request ends", `return !acMedia.useMedia.getState().displayRequests.b;`, 3000);
    return out;
  });
  await rep.check("cli-pill-native-indicator", async () => {
    const set = (shown) => run(`return globalThis.expo.modules.SolaraMedia.devSetCliIndicator(${shown}).then(() => true);`);
    await set(true);
    try {
      await until("JS mirrors the native indicator", `return globalThis.acCli.indicator.getState().shown || null;`, 3000);
      await run(`setTimeout(() => { try { globalThis.nativeModuleProxy.DevSettings.reload(); } catch {} }, 50); return true;`);
      await sleep(1500);
      await app.ready({ timeout: 60000, test: "return !!ac.store.getState().windows.w1" });
      await until("the native indicator survives a JS reload", `return globalThis.acCli.indicator.getState().shown || null;`, 5000);
      const pill = await until("the native pill shows after the reload", `return first("media.cliPill").then((r) => r && r.opacity > 0.99 ? r : null);`, 5000);
      if (pill) await crossCheckMedia("native indicator rows after reload", "media.cliPill", [pill]);
      if (pill) await untilSnapshot("native indicator after reload", async (window) => {
        const live = await run(`return first("media.cliPill").then((r) => r && r.opacity > 0.99 ? r : null);`);
        return nearRect(mediaRow(window, "media.cliPill")?.frame, live?.frame) && nearRect(mediaRow(window, "media.cliPill")?.frame, pill.frame);
      });
      await set(false);
      await until("JS follows the native indicator off", `return globalThis.acCli.indicator.getState().shown ? null : true;`, 3000);
      return { pill: pill ? pill.frame : null };
    } finally {
      await set(false).catch(() => {});
    }
  });
  await rep.check("share-bar-state", async () => {
    await until("share bar fixture page state", `return !!ac.pageState.getState().pages.b;`, 5000);
    await run(`
      ac.actions.switchToTab("b");
      globalThis.__mediaShareFixture = { access: ac.pageState.getState().pages.b.mediaAccess, shares: acMedia.useMedia.getState().tabShares };
      acMedia.useMedia.setState((m) => ({ tabShares: { ...m.tabShares, b: { capturedTabId: "b", origin: "https://meet.test", dismissed: {} } } }));
      ac.pageState.setState((s) => ({ pages: { ...s.pages, b: { ...s.pages.b, mediaAccess: { camera: false, microphone: false, screen: true } } } }));
      return true;`);
    try {
      const shared = await until("share bar primary", `return first("media.shareBar").then((r) => r?.primary === "Stop Sharing" ? r : null);`, 5000);
      await crossCheckMedia("share bar shared rows and labels", "media.shareBar", [shared]);
      assert.equal(shared.labels.primary, "Stop Sharing");
      assert.equal(shared.labels.dismiss, "Dismiss");
      await run(`acMedia.useMedia.setState((m) => ({ tabShares: { ...m.tabShares, b: { ...m.tabShares.b, capturedTabId: "p" } } })); return true;`);
      const other = await until("share bar other tab primary", `return first("media.shareBar").then((r) => r?.primary === "Share This Tab Instead" ? r : null);`, 5000);
      await crossCheckMedia("share bar other tab rows and labels", "media.shareBar", [other]);
      assert.equal(other.labels.primary, "Share This Tab Instead");
      return { shared: shared.primary, other: other.primary };
    } finally {
      await run(`
        acMedia.useMedia.setState({ tabShares: __mediaShareFixture.shares });
        ac.pageState.setState((s) => ({ pages: { ...s.pages, b: { ...s.pages.b, mediaAccess: __mediaShareFixture.access } } }));
        delete globalThis.__mediaShareFixture;
        return true;`);
    }
  });
  await rep.check("small-bar-hover-state", async () => {
    const before = await run(`return Object.keys(st().windows);`);
    await run(`ac.runCommand({ command: "newLittleSolara" }); return true;`);
    const id = await until("small window for bar hover", `return Object.values(st().windows).find((w) => w.kind === "small" && !${JSON.stringify(before)}.includes(w.id))?.id ?? null;`, 8000);
    try {
      await run(`st().closePanel(${JSON.stringify(id)}); return true;`);
      const bar = await until("small bar field", `return M.probe("littleSolara.bar", ${JSON.stringify(id)}).then(JSON.parse).then((rows) => rows[0]?.frames.field?.[2] > 0 ? rows[0] : null);`, 5000);
      const field = bar.frames.field;
      await run(`return ac.shell.devSetPointer(${JSON.stringify(id)}, { x: ${field[0] + field[2] / 2}, y: ${field[1] + field[3] / 2} }).then(() => true);`);
      const hovered = await until("small bar hovered", `return M.probe("littleSolara.bar", ${JSON.stringify(id)}).then(JSON.parse).then((rows) => rows[0]?.hovered === true ? rows[0] : null);`, 3000);
      await crossCheckMedia("small bar hovered rows", "littleSolara.bar", [hovered], id, async () => [await run(`return M.probe("littleSolara.bar", ${JSON.stringify(id)}).then(JSON.parse).then((rows) => rows[0]?.hovered === true ? rows[0] : null);`)]);
      await run(`return ac.shell.devSetPointer(${JSON.stringify(id)}, { x: ${field[0] + field[2] / 2}, y: ${field[1] + field[3] + 20} }).then(() => true);`);
      const left = await until("small bar hover leaves", `return M.probe("littleSolara.bar", ${JSON.stringify(id)}).then(JSON.parse).then((rows) => rows[0]?.hovered === false ? rows[0] : null);`, 3000);
      await crossCheckMedia("small bar unhovered rows", "littleSolara.bar", [left], id, async () => [await run(`return M.probe("littleSolara.bar", ${JSON.stringify(id)}).then(JSON.parse).then((rows) => rows[0]?.hovered === false ? rows[0] : null);`)]);
      return { hovered: hovered.hovered, left: left.hovered };
    } finally {
      await run(`st().closeWindow(${JSON.stringify(id)}); return true;`);
      await until("small fixture window closes", `return !st().windows[${JSON.stringify(id)}];`, 5000);
    }
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
