import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
const keep = args.includes("--keep-data");
const pooled = args.includes("--pool");
if (!appArg || args.some((arg) => arg.startsWith("--") && !["--keep-data", "--pool"].includes(arg))) {
  console.error(`usage: node media-stack-test.mjs <Debug Solara.app> [--pool] [--keep-data]

The sidebar mini player stack across windows: two normal windows in different profiles and a private window. Both
normal windows show the same cross-profile stack, newest first, and each hides only the card for the tab it shows; a
private window shows only private videos. The ✕ on a card in one window pauses its video and removes the card in
every window, and playing it again brings it back. The resting stack peeks the older card 7 pt above the front one;
hovering opens it after 150 ms, rising 82 pt over 280 ms with a 30 ms stagger, and it closes 400 ms after the pointer
leaves; a click on the peeking edge opens it and Escape closes it. Motion is sampled from the cards' presentation
layers and judged at 60 fps. --pool runs the pages in the native page pool; the default pins SOLARA_NATIVE_PAGES_POOL=0.`);
  process.exit(2);
}

const FRAME = 1000 / 60;
const scratch = mkdtempSync(join(tmpdir(), "ac-media-stack-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "media-stack-test.log"), { name: `media-stack-test${pooled ? " --pool" : ""}` });
const tone = (() => {
  const rate = 8000, seconds = 120, samples = rate * seconds;
  const buf = Buffer.alloc(44 + samples * 2);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + samples * 2, 4); buf.write("WAVE", 8); buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34); buf.write("data", 36); buf.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) buf.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 32), 44 + i * 2);
  return buf;
})();
let clipBytes = null;
const clip = () => {
  const path = join(scratch, "media", "clip.webm");
  if (!existsSync(path)) {
    mkdirSync(join(scratch, "media"), { recursive: true });
    execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30",
      "-f", "lavfi", "-i", "aevalsrc=0.001*sin(2*PI*440*t):s=48000", "-t", "30", "-c:v", "libvpx", "-b:v", "200k", "-c:a", "libopus",
      "-shortest", path], { stdio: "ignore" });
  }
  return (clipBytes ??= readFileSync(path));
};
const server = createServer((req, res) => {
  if (req.url === "/clip.webm") {
    const bytes = clip();
    res.writeHead(200, { "content-type": "video/webm", "content-length": String(bytes.length) });
    return res.end(bytes);
  }
  if (req.url === "/video-v" || req.url === "/video-w") {
    const name = req.url.slice(1);
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>${name}</title><link rel="icon" href="data:,"><video id="v" src="/clip.webm" loop playsinline style="width: 320px; height: 180px"></video>
<script>navigator.mediaSession.metadata = new MediaMetadata({ title: "Track ${name}", artist: "Fixture Artist" });
const v = document.getElementById("v");
v.addEventListener("play", () => { navigator.mediaSession.playbackState = "playing"; });
v.addEventListener("pause", () => { navigator.mediaSession.playbackState = "paused"; });</script>`);
  }
  if (req.url === "/tone.wav") {
    res.writeHead(200, { "content-type": "audio/wav", "content-length": String(tone.length) });
    return res.end(tone);
  }
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  if (name.startsWith("player-"))
    return res.end(`<!doctype html><title>${name}</title><link rel="icon" href="data:,"><audio id="tone" src="/tone.wav" loop></audio>
<script>navigator.mediaSession.metadata = new MediaMetadata({ title: ${JSON.stringify(`Track ${name}`)}, artist: "Fixture Artist" });
const tone = document.getElementById("tone");
tone.addEventListener("play", () => { navigator.mediaSession.playbackState = "playing"; });
tone.addEventListener("pause", () => { navigator.mediaSession.playbackState = "paused"; });</script>`);
  res.end(fixturePage(name));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  profiles: ["Personal", "Work"],
  windows: [
    { id: "w1", profileId: "default", frame: [80, 80, 1100, 760], activeTabIds: { default: "a2", work: "c" } },
    { id: "w2", profileId: "work", frame: [300, 120, 1000, 700], activeTabIds: { work: "d2" } },
  ],
  tabs: [
    { id: "a", windowId: "w1", profileId: "default", url: url("player-a"), title: "player-a" },
    { id: "a2", windowId: "w1", profileId: "default", url: url("a2"), title: "A2" },
    { id: "c", windowId: "w1", profileId: "work", url: url("player-c"), title: "player-c" },
    { id: "d", windowId: "w2", profileId: "work", url: url("player-d"), title: "player-d" },
    { id: "d2", windowId: "w2", profileId: "work", url: url("d2"), title: "D2" },
    { id: "e", windowId: "w2", profileId: "work", url: url("player-e"), title: "player-e" },
    { id: "v", windowId: "w2", profileId: "work", url: url("video-v"), title: "video-v" },
    { id: "w", windowId: "w2", profileId: "work", url: url("video-w"), title: "video-w" },
  ],
  settings: { sidebarWidth: 220, sidebarMediaControls: true, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const act = (id, a) => win(id).then((n) => C.devWindow(n, a));
const rows = (id) => M.probe("media.sidebarPlayer", id).then(JSON.parse).then((r) => r.filter((row) => !row.leaving));
const allRows = (id) => M.probe("media.sidebarPlayer", id).then(JSON.parse);
const ids = (id) => rows(id).then((r) => r.filter((row) => !row.leaving).map((row) => row.tabId));
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const hover = (id, [x, y]) => ac.shell.devSetPointer(id, { x, y }).then(() => act(id, "mouse:moved:" + x + "," + y));
const click = (id, p) => hover(id, p).then(() => settle(60)).then(() => act(id, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(id, "mouse:up:" + p[0] + "," + p[1]));
const sample = (id, ms, during) => {
  const out = [];
  const end = Date.now() + ms;
  let marks = {};
  const step = () => allRows(id).then((r) => { out.push(r.map((row) => ({ id: row.tabId, t: row.t, py: row.py, px: row.px, o: row.opacity, peeking: row.peeking }))); return Date.now() < end ? step() : { out, marks }; });
  const running = step();
  return Promise.resolve(during ? during((name) => rows(id).then((r) => { marks[name] = r[0]?.t ?? null; })) : null).then(() => running);
};
`;
let app;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
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
const inPage = async (name, expression) => {
  const page = await app.page(url(name));
  try {
    return await page.eval(expression, { userGesture: true });
  } finally {
    page.close();
  }
};
const play = async (name) => {
  const started = await inPage(name, "Promise.race([document.getElementById('tone').play().then(() => 'played', (e) => 'rejected ' + e.name), new Promise((r) => setTimeout(() => r('pending ' + document.getElementById('tone').readyState + ' ' + document.visibilityState), 3000))])");
  const tab = ["a", "c", "d", "e"].map((id) => `player-${id}`).includes(name) ? name.slice(7) : null;
  if (tab) await until(`${tab} reports playing`, `return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.some((e) => e.tabId === ${JSON.stringify(tab)} && e.playbackState === "playing" && e.controllable && !e.removed) || null);`, 10000).catch((e) => { throw new Error(`${e.message} (play: ${started})`); });
  await sleep(50);
};
const paused = async (name) => (await inPage(name, "document.getElementById('tone').paused")) === true;
const stackIs = (windowId, want, ms = 6000) =>
  until(`${windowId} stack ${JSON.stringify(want)}`, `return ids(${JSON.stringify(windowId)}).then((got) => JSON.stringify(got) === ${JSON.stringify(JSON.stringify(want))} ? got : M.probe("media.nowPlaying", "w1").then((np) => ({ error: JSON.stringify({ got, np: JSON.parse(np).map((e) => [e.tabId, e.playbackState, e.controllable, e.removed, Math.round(e.touchedAt % 100000)]), w: Object.values(st().windows).map((w) => [w.id, w.profileId, w.activeTabIds, w.incognito]) }) })));`, ms);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];

const bezier = (x1, y1, x2, y2) => (x) => {
  let lo = 0, hi = 1;
  for (let i = 0; i < 40; i++) {
    const t = (lo + hi) / 2;
    const bx = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t ** 2 * x2 + t ** 3;
    if (bx < x) lo = t; else hi = t;
  }
  const t = (lo + hi) / 2;
  return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t ** 2 * y2 + t ** 3;
};
const rise = bezier(0.2, 0.9, 0.25, 1);
const track = (samples, id) => samples.map((frame) => frame.find((card) => card.id === id)).filter(Boolean).map((card) => ({ ...card, t: card.t * 1000 }));
const frames = (ms) => Math.round(ms / FRAME);
const firstMove = (series, from) => series.find((s) => Math.abs(s.py - from) > 0.5)?.t ?? null;
const cadence = (samples) => {
  const ts = samples.map((frame) => frame[0]?.t).filter(Number.isFinite).map((t) => t * 1000);
  const gaps = ts.slice(1).map((t, i) => t - ts[i]).sort((a, b) => a - b);
  return { samples: ts.length, median: gaps.length ? gaps[Math.floor(gaps.length / 2)] : Infinity, max: gaps.length ? gaps[gaps.length - 1] : Infinity };
};
const settledAt = (series, to) => {
  let at = null;
  for (const s of series) {
    if (Math.abs(s.py - to) <= 0.5) at ??= s.t;
    else at = null;
  }
  return at;
};

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_ALLOW_AUDIO: "1", ...(pooled ? { SOLARA_NATIVE_PAGES_POOL: "1" } : { SOLARA_NATIVE_PAGES_POOL: "0" }) },
    switches: "--disable-audio-output --autoplay-policy=no-user-gesture-required",
    ready: "return !!ac.store.getState().windows.w1 && !!ac.store.getState().windows.w2",
  });

  await rep.check("pages-load", async () => {
    for (const [tab, name] of [["a", "player-a"], ["c", "player-c"], ["d", "player-d"]]) {
      await run(`ac.actions.switchToTab(${JSON.stringify(tab)}); return true;`);
      const end = Date.now() + 15000;
      while (Date.now() < end && (await inPage(name, "!!document.getElementById('tone')").catch(() => false)) !== true) await sleep(200);
    }
    await run(`ac.actions.switchToTab("a2"); ac.actions.switchToTab("d2"); return true;`);
    return await until("fixture tabs shown", `const s = st(); return s.windows.w1.profileId === "default" && s.windows.w1.activeTabIds.default === "a2" && s.windows.w2.activeTabIds.work === "d2" || null;`, 5000);
  });

  await rep.check("shared-stack", async () => {
    await play("player-a");
    await stackIs("w1", ["a"]);
    await play("player-c");
    await play("player-d");
    const w1 = await stackIs("w1", ["d", "c", "a"]);
    const w2 = await stackIs("w2", ["d", "c", "a"]);
    const peeks = await run(`return rows("w1").then((r) => r.map((row) => row.peeking));`);
    assert.deepEqual(peeks, [false, true, true]);
    return { w1, w2 };
  });

  await rep.check("profile-swipe-keeps-the-stack-still", async () => {
    const swipe = (sign, end) => run(`
      const H = globalThis.expo.modules.SolaraHosted;
      const steps = [
        { phase: "began", dx: 0, dy: 0 }, { phase: "changed", dx: ${18 * sign}, dy: 0 }, { phase: "changed", dx: ${22 * sign}, dy: 0 },
        { phase: "changed", dx: ${22 * sign}, dy: 0 }, { phase: "changed", dx: ${22 * sign}, dy: 0 }, { phase: ${JSON.stringify(end)}, dx: 0, dy: 0 },
      ].map((step, i) => ({ ...step, atMs: i * 16, timestampMs: i * 16 }));
      const samples = [];
      let done = false;
      const tick = () => Promise.all([H.sidebarPages("w1").then(JSON.parse), rows("w1")]).then(([pages, cards]) => {
        samples.push({ pages: pages.filter((page) => page.id && page.made).map((page) => [page.id, page.x, page.hidden]),
          player: pages.find((entry) => entry.player)?.player ?? null, cards: cards.map((card) => [card.tabId, card.px, card.py]) });
        return done ? null : settle(8).then(tick);
      });
      const sampling = tick();
      return win("w1").then((n) => globalThis.expo.modules.SolaraSwipe.devSimulate(120, 400, n, steps, true))
        .then(() => settle(700)).then(() => { done = true; return sampling; })
        .then(() => ({ samples, profile: st().windows.w1.profileId, shown: st().windows.w1.activeTabIds[st().windows.w1.profileId] }));
    `);
    const still = (label, result, rest, from, startCards) => {
      const moved = result.samples.filter((s) => s.pages.some(([, x, hidden]) => !hidden && Math.abs(x) > 1));
      assert.ok(moved.length > 0, `${label}: the pages moved during the swipe (${result.samples.length} samples)`);
      for (const s of result.samples) {
        assert.ok(s.player?.made && !s.player.hidden, `${label}: the stack is shown (${JSON.stringify(s.player)})`);
        assert.deepEqual([s.player.x, s.player.y, s.player.width, s.player.height], rest.frame, `${label}: the stack stays put (${JSON.stringify(s)})`);
        if (s.player.driver === from) assert.deepEqual(s.cards, startCards, `${label}: the cards stay put until the switch commits (${JSON.stringify(s)})`);
      }
      const last = result.samples.at(-1);
      const want = rest.all.filter((id) => id !== result.shown);
      assert.deepEqual(last.cards.map(([id]) => id), want, `${label}: after the switch the stack hides only the tab this window now shows (${result.shown})`);
      return { samples: result.samples.length, moved: moved.length, widest: Math.max(...moved.map((s) => Math.max(...s.pages.map(([, x]) => Math.abs(x))))),
        drivers: [...new Set(result.samples.map((s) => s.player.driver))], shown: result.shown, cards: last.cards.map(([id]) => id), end: last.cards };
    };
    const before = (await swipe(0, "cancelled")).samples.at(-1);
    const rest = { frame: [before.player.x, before.player.y, before.player.width, before.player.height], all: before.cards.map(([id]) => id) };
    const cancelled = await swipe(-1, "cancelled");
    assert.equal(cancelled.profile, "default", "a swipe that snaps back keeps the profile");
    const back = still("snap-back", cancelled, rest, "default", before.cards);
    assert.deepEqual(cancelled.samples.at(-1).cards, before.cards, "a snap-back leaves the cards where they were");
    const committed = await swipe(-1, "ended");
    assert.equal(committed.profile, "work", "a full swipe switches the profile");
    const forward = still("switch", committed, rest, "default", before.cards);
    const returned = await swipe(1, "ended");
    assert.equal(returned.profile, "default", "swiping back returns to the first profile");
    const home = still("switch back", returned, rest, "work", forward.end);
    assert.deepEqual(returned.samples.at(-1).cards, before.cards, "switching back restores the first profile's cards");
    await run(`ac.actions.switchToTab("a2"); return true;`);
    return { rest, back, forward, home };
  });

  await rep.check("watched-tab-hides-only-here", async () => {
    await run(`ac.actions.switchToTab("a"); return true;`);
    const w1 = await stackIs("w1", ["d", "c"]);
    await stackIs("w2", ["d", "c", "a"]);
    await run(`ac.actions.switchToTab("d"); return true;`);
    const w2 = await stackIs("w2", ["c", "a"]);
    await stackIs("w1", ["d", "c"]);
    await run(`ac.actions.switchToTab("a2"); ac.actions.switchToTab("d2"); return true;`);
    await stackIs("w1", ["d", "c", "a"]);
    await stackIs("w2", ["d", "c", "a"]);
    return { w1, w2 };
  });

  await rep.check("private-shows-only-private", async () => {
    const pw = await run(`return st().createWindow({ incognito: true, frame: [240, 140, 900, 600], url: ${JSON.stringify(url("player-x"))} });`);
    const pw2 = await run(`return st().createWindow({ incognito: true, frame: [260, 160, 900, 600], url: ${JSON.stringify(url("x3"))} });`);
    try {
      await until("private page", `return Object.values(st().tabs).some((t) => t.windowId === ${JSON.stringify(pw)} && !st().live[t.id]?.isLoading) || null;`, 15000);
      await play("player-x");
      const px = await run(`return st().windows[${JSON.stringify(pw)}].tabIds[0];`);
      await run(`st().newTab(${JSON.stringify(pw)}, { url: ${JSON.stringify(url("x2"))} }); return true;`);
      await until("private window shows another tab", `const w = st().windows[${JSON.stringify(pw)}]; return w.activeTabIds[w.profileId] !== ${JSON.stringify(px)} || null;`, 5000);
      const privateIds = await stackIs(pw, [px]);
      const second = await stackIs(pw2, [px]);
      const w1 = await stackIs("w1", ["d", "c", "a"]);
      const w2 = await stackIs("w2", ["d", "c", "a"]);
      return { private: privateIds, second, w1, w2 };
    } finally {
      await run(`st().closeWindow(${JSON.stringify(pw)}); st().closeWindow(${JSON.stringify(pw2)}); return true;`);
      await until("private windows close", `return (!st().windows[${JSON.stringify(pw)}] && !st().windows[${JSON.stringify(pw2)}]) || null;`, 5000);
    }
  });

  await rep.check("resting-peek", async () => {
    const r = await run(`return rows("w1");`);
    const [front, second, third] = r;
    assert.equal(Math.round((front.py - second.py) * 10) / 10, 7);
    assert.equal(Math.round((front.py - third.py) * 10) / 10, 14);
    return { py: r.map((row) => row.py) };
  });

  await rep.check("resting-click-reaches-the-front-card", async () => {
    const r = await run(`return rows("w1");`);
    assert.equal(r[0].tabId, "d");
    const p = centre(r[0].frames.play);
    const after = await run(`return hover("w1", ${JSON.stringify(p)}).then(() => act("w1", "mouse:down:${p[0]},${p[1]}")).then(() => settle(20)).then(() => act("w1", "mouse:up:${p[0]},${p[1]}")).then(() => rows("w1")).then((r) => r.map((row) => row.peeking));`);
    assert.deepEqual(after, [false, true, true], "the click opened the stack instead of reaching the front card");
    const end = Date.now() + 3000;
    let stopped = false;
    while (!stopped && Date.now() < end) { stopped = await paused("player-d"); if (!stopped) await sleep(150); }
    if (!stopped) throw new Error("play on the front card at rest didn't pause d");
    const profile = await run(`return st().windows.w1.profileId;`);
    assert.equal(profile, "default", "the card's play switched the window's profile");
    await run(`return hover("w1", [600, 300]).then(() => settle(900)).then(() => true);`);
    await play("player-d");
    await stackIs("w1", ["d", "c", "a"]);
    return { profile };
  });

  await rep.check("hover-opens-at-60fps", async () => {
    const r = await run(`return rows("w1");`);
    const target = centre(r[0].frames.title);
    const { out, marks } = await run(`return sample("w1", 900, (mark) => settle(80).then(() => hover("w1", ${JSON.stringify(target)})).then(() => mark("hover")));`, 8000);
    const pace = cadence(out);
    const other = await run(`return rows("w2").then((r) => r.map((row) => row.peeking));`);
    assert.deepEqual(other, [false, true, true], "hovering w1's stack opened w2's");
    if (pace.median > FRAME) return { notMeasurable: `median sample gap ${pace.median.toFixed(1)} ms is over one 60 fps frame`, pace };
    const t0 = marks.hover * 1000;
    const front = track(out, r[0].tabId), second = track(out, r[1].tabId), third = track(out, r[2].tabId);
    const restSecond = r[1].py, restThird = r[2].py;
    const openSecond = r[0].py - 82, openThird = r[0].py - 164;
    const moveSecond = firstMove(second, restSecond), moveThird = firstMove(third, restThird);
    const doneSecond = settledAt(second, openSecond), doneThird = settledAt(third, openThird);
    assert.ok(front.every((s) => Math.abs(s.py - r[0].py) <= 0.5), "the front card stays put");
    assert.ok(moveSecond !== null && moveThird !== null, "older cards rise");
    const delay = frames(moveSecond - t0), stagger = frames(moveThird - moveSecond);
    const riseSecond = frames(doneSecond - moveSecond);
    const detail = JSON.stringify({ delay, stagger, moveSecond: moveSecond - t0, moveThird: moveThird - t0, doneSecond: doneSecond - t0, pace });
    assert.ok(stagger >= frames(30) - 1 && stagger <= frames(30) + 1, `stagger ${stagger} frames ${detail}`);
    assert.ok(delay >= frames(150) - 1 && delay <= frames(150 + 30) + 2, `open delay ${delay} frames ${detail}`);
    assert.ok(riseSecond <= frames(280) + 2 && riseSecond >= frames(280 * 0.6), `rise ${riseSecond} frames`);
    const mid = second.find((s) => s.t >= moveSecond + 140);
    assert.ok(mid, "a sample halfway through the rise");
    const progress = (restSecond - mid.py) / (restSecond - openSecond);
    const want = rise((mid.t - moveSecond) / 280);
    assert.ok(Math.abs(progress - want) <= 0.12, `curve progress ${progress} wants ${want}`);
    const peeks = await run(`return rows("w1").then((r) => r.map((row) => row.peeking));`);
    assert.deepEqual(peeks, [false, false, false]);
    return { delay, stagger, riseSecond, doneThird: frames(doneThird - moveThird), progress, want, pace };
  });

  await rep.check("leave-closes-after-400ms", async () => {
    const r = await run(`return rows("w1");`);
    const { out, marks } = await run(`return sample("w1", 1100, (mark) => settle(60).then(() => hover("w1", [600, 300])).then(() => mark("leave")));`, 8000);
    const pace = cadence(out);
    if (pace.median > FRAME) {
      await until("stack closed", `return rows("w1").then((r) => r[1]?.peeking || null);`, 2000);
      return { notMeasurable: `median sample gap ${pace.median.toFixed(1)} ms is over one 60 fps frame`, pace };
    }
    const t0 = marks.leave * 1000;
    const second = track(out, r[1].tabId);
    const move = firstMove(second, r[1].py);
    assert.ok(move !== null, "the stack closes");
    const hold = frames(move - t0);
    assert.ok(hold >= frames(400 + 30) - 1 && hold <= frames(400 + 30) + 2, `close hold ${hold} frames`);
    const peeks = await run(`return rows("w1").then((r) => r.map((row) => row.peeking));`);
    assert.deepEqual(peeks, [false, true, true]);
    return { hold, pace };
  });

  await rep.check("peek-click-opens-escape-closes", async () => {
    const top = await run(`return rows("w1").then((r) => { const f = r[0].frames; return [Math.round(f.seek[0] + f.seek[2] / 2), Math.round(f.art[1] - 7.5 - 3)]; });`);
    const hit = await run(`return act("w1", "hit:" + ${top[0]} + "," + ${top[1]});`);
    await run(`return click("w1", ${JSON.stringify(top)}).then(() => true);`);
    await until("stack open", `return rows("w1").then((r) => r.every((row) => !row.peeking) || null);`, 2000);
    await run(`return act("w1", "keys:0:\\u001b:53").then(() => true);`);
    await until("stack closed", `return rows("w1").then((r) => r[1]?.peeking || null);`, 2000);
    await run(`return hover("w1", [600, 300]).then(() => true);`);
    return { top, hit };
  });

  await rep.check("close-pauses-everywhere", async () => {
    await run(`return rows("w2").then((r) => hover("w2", centre(r[0].frames.title))).then(() => settle(700)).then(() => true);`);
    await until("w2 corners", `return rows("w2").then((r) => r[0]?.corners || null);`, 3000);
    const before = await run(`return ids("w2");`);
    assert.equal(before[0], "d");
    await run(`return rows("w2").then((r) => click("w2", centre(r[0].frames.close))).then(() => true);`);
    await stackIs("w2", ["c", "a"]);
    await stackIs("w1", ["c", "a"]);
    const end = Date.now() + 3000;
    let stopped = false;
    while (!stopped && Date.now() < end) { stopped = await paused("player-d"); if (!stopped) await sleep(150); }
    if (!stopped) throw new Error("the ✕ left the video playing");
    const shown = await run(`return st().windows.w2.activeTabIds.work;`);
    assert.equal(shown, "d2", "the ✕ moved the window to another tab");
    await run(`return hover("w2", [600, 300]).then(() => true);`);
    await play("player-d");
    await stackIs("w2", ["d", "c", "a"]);
    await stackIs("w1", ["d", "c", "a"]);
    return { before, shown };
  });

  await rep.check("close-slides-out", async () => {
    await run(`return rows("w1").then((r) => hover("w1", centre(r[0].frames.title))).then(() => settle(700)).then(() => true);`);
    await until("w1 corners", `return rows("w1").then((r) => r[0]?.corners || null);`, 3000);
    const r = await run(`return rows("w1");`);
    const closing = r[0].tabId;
    const point = [Math.round(r[0].frames.close[0] + r[0].frames.close[2] / 2), Math.round(r[0].frames.close[1] + r[0].frames.close[3] / 2)];
    const { out, marks } = await run(`return sample("w1", 500, (mark) => mark("press").then(() => click("w1", ${JSON.stringify(point)})).then(() => mark("up")));`, 8000);
    const pace = cadence(out);
    const leaving = out.flatMap((frame) => frame.filter((card) => card.id === closing)).map((card) => ({ ...card, t: card.t * 1000 }));
    const gone = leaving.length ? leaving.length - 1 : -1;
    const slid = leaving.reduce((min, s) => Math.min(min, s.px - (r[0].px ?? 0)), 0);
    assert.ok(slid <= -20, `slid ${slid} pt`);
    const fade = gone >= 0 ? frames(leaving[gone].t - marks.up * 1000) : null;
    await run(`return hover("w1", [600, 300]).then(() => true);`);
    await play(`player-${closing}`);
    await stackIs("w1", ["d", "c", "a"]);
    if (pace.median > FRAME) return { notMeasurable: `median sample gap ${pace.median.toFixed(1)} ms is over one 60 fps frame`, slid, pace };
    assert.ok(fade !== null && fade <= frames(200) + 3, `fade ${fade} frames`);
    return { slid, fade, pace };
  });

  await rep.check("a-fourth-video-drops-the-oldest", async () => {
    await run(`ac.actions.switchToTab("e"); return true;`);
    const end = Date.now() + 15000;
    while (Date.now() < end && (await inPage("player-e", "!!document.getElementById('tone')").catch(() => false)) !== true) await sleep(200);
    await run(`ac.actions.switchToTab("d2"); return true;`);
    await until("w2 back on d2", `return st().windows.w2.activeTabIds.work === "d2" || null;`, 3000);
    const before = await run(`return { live: st().live.e ?? null, tab: st().tabs.e ? { url: st().tabs.e.url } : null };`);
    await play("player-e").catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(before)}`); });
    const both = [await stackIs("w1", ["e", "d", "c"]), await stackIs("w2", ["e", "d", "c"])];
    await run(`return rows("w1").then((r) => hover("w1", centre(r[0].frames.title))).then(() => settle(700)).then(() => true);`);
    await until("w1 corners", `return rows("w1").then((r) => r[0]?.corners || null);`, 3000);
    await run(`return rows("w1").then((r) => click("w1", centre(r[0].frames.close))).then(() => hover("w1", [600, 300])).then(() => true);`);
    const after = await stackIs("w1", ["d", "c", "a"]);
    await stackIs("w2", ["d", "c", "a"]);
    return { both, after };
  });

  await rep.check("card-click-goes-to-the-tab-in-its-profile", async () => {
    const r = await run(`return rows("w1");`);
    const card = r.find((row) => row.tabId === "c");
    assert.ok(card, "c has a card in w1");
    if (r[0].tabId !== "c") {
      await run(`return rows("w1").then((r) => hover("w1", centre(r[0].frames.title))).then(() => settle(700)).then(() => true);`);
      await until("w1 open", `return rows("w1").then((r) => r.every((row) => !row.peeking) || null);`, 2000);
    }
    await run(`return rows("w1").then((r) => click("w1", centre(r.find((row) => row.tabId === "c").frames.art))).then(() => true);`);
    const shown = await until("c shown in w1", `const w = st().windows.w1; return w.profileId === "work" && w.activeTabIds.work === "c" ? { profile: w.profileId, tab: w.activeTabIds.work } : null;`, 4000);
    await stackIs("w1", ["d", "a"]);
    return shown;
  });
  await rep.check("picture-in-picture-from-the-card", async () => {
    const holder = () => run(`return C.devPictureInPictureHolder();`);
    const state = () => run(`return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.find((e) => e.tabId === "v") || null);`);
    const front = (id) => run(`return rows(${JSON.stringify(id)}).then((r) => r.find((row) => row.tabId === "v") || null);`);
    await run(`ac.actions.switchToTab("v"); return true;`);
    const end = Date.now() + 15000;
    while (Date.now() < end && (await inPage("video-v", "!!document.getElementById('v')").catch(() => false)) !== true) await sleep(200);
    await run(`ac.actions.switchToTab("d2"); return true;`);
    await inPage("video-v", "(document.getElementById('v').play().catch(() => {}), true)");
    await until("v reports a playing video", `return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.some((e) => e.tabId === "v" && e.playbackState === "playing" && e.controllable && e.hasVideo) || null);`, 10000);
    const shownBefore = await run(`return [st().windows.w1.activeTabIds[st().windows.w1.profileId], st().windows.w2.activeTabIds.work];`);
    const card = await until("v's card offers PiP", `return rows("w1").then((r) => { const row = r[0]; return row?.tabId === "v" && row.frames.pip ? row : null; });`, 4000);
    const out = { label: card.labels?.pip ?? null };
    await run(`return rows("w1").then((r) => click("w1", centre(r[0].frames.pip))).then(() => true);`);
    out.holder = await until("v holds the PiP", `return C.devPictureInPictureHolder().then((h) => h === "v" ? h : null);`, 6000);
    out.playingInPiP = (await state())?.playbackState;
    const held = await until("both windows' cards offer Minimize", `return Promise.all([rows("w1"), rows("w2")]).then(([a, b]) => { const x = a.find((r) => r.tabId === "v"), y = b.find((r) => r.tabId === "v"); const minimize = "Minimize Picture in Picture"; return x?.labels?.pip === minimize && y?.labels?.pip === minimize ? [x.labels.pip, y.labels.pip, x.subtitle, y.subtitle] : null; });`, 4000);
    out.heldLabels = held.slice(0, 2);
    out.heldSubtitles = held.slice(2);
    out.shownAfter = await run(`return [st().windows.w1.activeTabIds[st().windows.w1.profileId], st().windows.w2.activeTabIds.work];`);
    await run(`return rows("w1").then((r) => click("w1", centre(r.find((row) => row.tabId === "v").frames.pip))).then(() => true);`);
    out.afterMinimize = await until("the PiP minimized", `return C.devPictureInPictureHolder().then((h) => h === "" ? "none" : null);`, 6000);
    await sleep(500);
    out.playingAfterMinimize = (await state())?.playbackState;
    await inPage("video-v", "(document.getElementById('v').pause(), true)");
    await until("v paused", `return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.some((e) => e.tabId === "v" && e.playbackState === "paused") || null);`, 6000);
    await run(`return rows("w1").then((r) => click("w1", centre(r.find((row) => row.tabId === "v").frames.pip))).then(() => true);`);
    out.pausedHolder = await until("paused v holds the PiP", `return C.devPictureInPictureHolder().then((h) => h === "v" ? h : null);`, 6000);
    await sleep(800);
    out.pausedInPiP = (await state())?.playbackState;
    await run(`return C.devPictureInPictureMinimize().then(() => true);`);
    out.flipsBack = await until("the card offers PiP again after a minimize elsewhere", `return rows("w1").then((r) => { const row = r.find((x) => x.tabId === "v"); return row && row.labels?.pip === "Open in Picture in Picture" ? row.labels.pip : null; });`, 4000);
    await run(`return hover("w1", [600, 300]).then(() => true);`);
    const want = { label: "Open in Picture in Picture", holder: "v", playingInPiP: "playing", afterMinimize: "none", playingAfterMinimize: "playing", pausedHolder: "v", pausedInPiP: "paused" };
    for (const [key, value] of Object.entries(want)) assert.equal(out[key], value, `${key} ${JSON.stringify(out)}`);
    assert.deepEqual(out.heldLabels, ["Minimize Picture in Picture", "Minimize Picture in Picture"], JSON.stringify(out));
    assert.ok(out.heldSubtitles.every((text) => !text.includes("In PiP")), `the subtitle shows only the profile in PiP: ${JSON.stringify(out.heldSubtitles)}`);
    assert.deepEqual(out.shownAfter, shownBefore, "entering PiP from the card switched tabs");
    assert.equal(out.flipsBack, "Open in Picture in Picture");
    return out;
  });
  await rep.check("picture-in-picture-takeover-pauses-the-old-card", async () => {
    const holder = () => run(`return C.devPictureInPictureHolder();`);
    const reported = (tab) => run(`return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.find((e) => e.tabId === ${JSON.stringify(tab)})?.playbackState ?? null);`);
    await run(`ac.actions.switchToTab("w"); return true;`);
    const end = Date.now() + 15000;
    while (Date.now() < end && (await inPage("video-w", "!!document.getElementById('v')").catch(() => false)) !== true) await sleep(200);
    await run(`ac.actions.switchToTab("d2"); return true;`);
    for (const [tab, name] of [["v", "video-v"], ["w", "video-w"]]) {
      await inPage(name, "(document.getElementById('v').play().catch(() => {}), true)");
      await until(`${tab} playing`, `return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.some((e) => e.tabId === ${JSON.stringify(tab)} && e.playbackState === "playing" && e.controllable && e.hasVideo && !e.removed) || null);`, 10000);
    }
    const pressPip = (tab) => run(`return rows("w1").then((r) => { const row = r.find((x) => x.tabId === ${JSON.stringify(tab)}); if (!row?.frames.pip) throw new Error("no PiP button on " + ${JSON.stringify(tab)} + "'s card: " + JSON.stringify(r.map((x) => [x.tabId, x.peeking]))); return click("w1", centre(row.frames.pip)); }).then(() => true);`);
    const openFor = async (tab) => {
      const r = await run(`return rows("w1");`);
      const row = r.find((x) => x.tabId === tab);
      if (row?.peeking) {
        await run(`return rows("w1").then((r) => hover("w1", centre(r[0].frames.title))).then(() => settle(700)).then(() => true);`);
        await until("w1 open", `return rows("w1").then((r) => r.every((row) => !row.peeking) || null);`, 2000);
      }
      await pressPip(tab);
      return until(`${tab} holds the PiP`, `return C.devPictureInPictureHolder().then((h) => h === ${JSON.stringify(tab)} ? h : null);`, 6000);
    };
    const out = { first: await openFor("v") };
    out.second = await openFor("w");
    out.oldPaused = await until("v pauses when w takes the PiP", `return M.probe("media.nowPlaying", "w1").then(JSON.parse).then((rows) => rows.some((e) => e.tabId === "v" && e.playbackState === "paused") ? "paused" : null);`, 6000).catch(() => "still playing");
    out.newPlaying = await reported("w");
    await run(`return hover("w1", [600, 300]).then(() => true);`);
    await sleep(1500);
    out.order = await run(`return ids("w1");`);
    out.order2 = await run(`return ids("w2");`);
    await run(`return C.devPictureInPictureMinimize().then(() => true);`);
    await until("the PiP closes", `return C.devPictureInPictureHolder().then((h) => h === "" || null);`, 6000);
    assert.equal(out.oldPaused, "paused", JSON.stringify(out));
    assert.equal(out.newPlaying, "playing", JSON.stringify(out));
    assert.equal(out.order[0], "w", `the new holder isn't in front: ${JSON.stringify(out)}`);
    assert.ok(out.order.indexOf("v") > 0, `the paused old holder came to the front: ${JSON.stringify(out)}`);
    assert.equal(out.order2[0], "w", `w2 disagrees: ${JSON.stringify(out)}`);
    return out;
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
