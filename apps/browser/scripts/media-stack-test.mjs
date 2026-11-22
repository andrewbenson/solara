import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
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
const server = createServer((req, res) => {
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
      const page = await app.page(url(name), { timeout: 15000 });
      page.close();
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
    (await app.page(url("player-e"), { timeout: 15000 })).close();
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
