import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node profile-pager-test.mjs <Debug Solara.app> [--keep-data]

The shell's profile pager under the native sidebar and top strip: RN mounts none of its SwipeArea, ProfileTint or
WindowProfile bridges. Simulated swipes hold the sidebar and strip between profiles, rubber-band at the first profile,
and flick to the next while the native tint follows the pager position. A reverse swipe interrupts the settle; store
switches jump the pager and animated ones settle; a flick on the auto-hide peek strip switches once, with no second
switch from JS and no jump back. Native snapshots cross-check profile IDs and tab ownership.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-profile-pager-"));
const rep = reporter(join(scratch, "profile-pager-test.log"), { name: "profile-pager-test" });

const tab = (id, profileId, windowId = "w1") => ({ id, profileId, windowId, url: "solara://newtab", title: "New Tab" });
const fixture = session({
  profiles: ["Personal", "Work", "Play"],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800] }, { id: "w2", frame: [120, 120, 1200, 760], tabLayout: "top" }],
  tabs: [tab("t1", "default"), tab("t2", "work"), tab("t3", "play"), tab("u1", "default", "w2"), tab("u2", "work", "w2")],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const S = globalThis.expo.modules.SolaraSwipe;
const P = globalThis.expo.modules.SolaraProfilePager;
const H = globalThis.expo.modules.SolaraHosted;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w || null; });
const swipe = (id, x, y, steps) => win(id).then((w) => S.devSimulate(x, y, w.window, steps, true));
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 4000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(50);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const steps = (moves, end) =>
  [{ phase: "began", dx: 0, dy: 0 }, ...moves.map((dx) => ({ phase: "changed", dx, dy: 0 })), ...(end ? [{ phase: "ended", dx: 0, dy: 0 }] : [])]
    .map((s, i) => ({ ...s, atMs: i * 16, timestampMs: i * 16 }));
const flick = (sign) => steps([18 * sign, 22 * sign, 22 * sign], true);
const SIDEBAR = [120, 400];
const STRIP = [420, 20];
const pagerState = (id) => run(`return S.devPagerState(${JSON.stringify(id)});`);
const profileOf = (id) => run(`return st().windows[${JSON.stringify(id)}].profileId;`);
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot().catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && await accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const nativeProfile = async (id, profileId) => {
  const state = await untilSnapshot(`native ${id} profile ${profileId}`, (state) => profileOf(id).then((selected) => selected === profileId && state.windows.some((window) => window.id === id && window.profileId === selected)));
  const window = state.windows.find((entry) => entry.id === id);
  if (!window.tabIds.every((tabId) => state.tabs.some((tab) => tab.id === tabId && tab.windowId === id))) throw new Error(`native ${id} tab ownership changed`);
};
const reset = async () => {
  for (const id of ["w1", "w2"]) await run(`st().switchProfile(${JSON.stringify(id)}, "default"); return true;`);
  await until("the pagers rest at Personal", `return Promise.all([S.devPagerState("w1"), S.devPagerState("w2")]).then((s) => s.every((p) => p && p.phase === "idle" && p.position === 0) || null);`);
  await nativeProfile("w1", "default");
  await nativeProfile("w2", "default");
};
const release = async (id, point) => {
  await run(`return swipe(${JSON.stringify(id)}, ${point[0]}, ${point[1]}, ${JSON.stringify([{ phase: "ended", dx: 0, dy: 0, atMs: 0, timestampMs: 2000 }])});`);
  await until("the pager settles", `return S.devPagerState(${JSON.stringify(id)}).then((p) => p.phase === "idle" || null);`);
};
const traced = async (body, wait) => {
  await run(`return P.devTrace("w1", true);`);
  await run(body);
  await sleep(wait);
  return JSON.parse(await run(`return P.devTrace("w1", false);`));
};
const near = (a, b, tolerance = 1e-6) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tolerance;
const widthOf = (target) => {
  const width = target?.frame?.[2];
  if (!Number.isFinite(width) || width <= 0) throw new Error(`invalid target width ${JSON.stringify(target)}`);
  return width;
};
const rounded = (value) => value < 0 ? -Math.round(-value) : Math.round(value);
const springAt = (width, time) => {
  const omega = 2 * Math.PI / 0.25;
  const from = 62 * 0.5 / width;
  const velocity = 44 * 0.5 / width / 0.032;
  const x0 = from - 1;
  const b = velocity + omega * x0;
  const decay = Math.exp(-omega * time);
  const x = (x0 + b * time) * decay;
  const v = (velocity - omega * b * time) * decay;
  const settled = Math.abs(x) < 0.003 && Math.abs(v) < 0.1;
  return { position: settled ? 1 : 1 + x, settled };
};
const springDuration = (width) => {
  let lo = 0;
  for (let hi = 0.001; hi <= 2; hi += 0.001) {
    if (springAt(width, hi).settled) {
      for (let i = 0; i < 50; i++) {
        const mid = (lo + hi) / 2;
        if (springAt(width, mid).settled) hi = mid;
        else lo = mid;
      }
      return hi;
    }
    lo = hi;
  }
  throw new Error(`spring never rests for width ${width}`);
};
try {
  const tag = "native";
  const mine = {};
  app = await launch(resolve(appArg), {
    data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDEBAR: "1", SOLARA_NATIVE_TOP_STRIP: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!ac.store.getState().windows.w2",
  });
  await until("both windows", `return Promise.all([win("w1"), win("w2")]).then((ws) => ws.every(Boolean) || null);`, 15000);
  await sleep(1500);
  await reset();

  await rep.check(`${tag}-mounts`, async () => {
    const fibers = await run(`return Object.fromEntries(["ReactSwipeArea", "ReactProfileTint", "ReactWindowProfile"].map((n) => [n, acPerf.findFibers(n, 50).length]));`);
    const counts = Object.values(fibers);
    if (counts.some((n) => n > 0)) throw new Error(JSON.stringify(fibers));
    const d = JSON.parse(await run(`return P.describe("w1");`));
    if (d.sidebar.hidden || !d.sidebar.native || d.tint.hidden || d.tint.pages.length !== 3) throw new Error(JSON.stringify(d));
    return fibers;
  });

  await rep.check(`${tag}-held-sidebar`, async () => {
    await run(`return swipe("w1", ${SIDEBAR}, ${JSON.stringify(steps([-18, -22, -22]))});`);
    try {
      const [held, d, pages] = await run(`return Promise.all([S.devPagerState("w1"), P.describe("w1"), H.sidebarPages("w1")]).then(([held, d, pages]) => [held, JSON.parse(d), JSON.parse(pages)]);`);
      const width = widthOf(d.sidebar);
      mine.held = { position: held.position, phase: held.phase, x: pages.filter((p) => p.id).map((p) => p.x) };
      if (held.phase !== "tracking" || !(held.position > 0.1) || !near(held.position, 62 * 0.5 / width)) throw new Error(JSON.stringify({ held, width }));
      const ids = ["default", "work", "play"];
      const rows = pages.filter((p) => p.id);
      const positions = pages.filter((p) => Object.hasOwn(p, "position"));
      if (rows.length !== ids.length || rows.some((p, slot) => p.id !== ids[slot]) || positions.length !== 1 || !near(positions[0].position, held.position)) throw new Error(JSON.stringify(pages));
      rows.forEach((page, slot) => {
        const shown = Math.abs(slot - held.position) < 1;
        if (shown) {
          const x = rounded((slot - held.position) * width);
          if (page.made !== true || page.hidden !== false || !Number.isSafeInteger(page.x) || !Number.isSafeInteger(x) || page.x !== x) throw new Error(JSON.stringify({ page, x, slot, position: held.position, width }));
        } else if (page.made && page.hidden !== true) throw new Error(JSON.stringify(page));
      });
      return mine.held;
    } finally {
      await release("w1", SIDEBAR);
    }
  });

  await rep.check(`${tag}-rubber-band`, async () => {
    await run(`return swipe("w1", ${SIDEBAR}, ${JSON.stringify(steps([30, 40, 40]))});`);
    try {
      const [held, d] = await run(`return Promise.all([S.devPagerState("w1"), P.describe("w1")]).then(([held, d]) => [held, JSON.parse(d)]);`);
      const width = widthOf(d.sidebar);
      const expected = -(1 - 1 / (110 * 0.5 * 0.15 / 255 + 1)) * 255 / width;
      mine.band = held.position;
      if (!(held.position < 0 && held.position > -0.5) || !near(held.position, expected)) throw new Error(JSON.stringify({ held, expected, width }));
      return held.position;
    } finally {
      await release("w1", SIDEBAR);
    }
  });

  await rep.check(`${tag}-flick`, async () => {
    const d = JSON.parse(await run(`return P.describe("w1");`));
    const width = widthOf(d.sidebar);
    const trace = await traced(`return swipe("w1", ${SIDEBAR}, ${JSON.stringify(flick(-1))});`, 900);
    await until("Work", `return st().windows.w1.profileId === "work" || null;`, 1800);
    const engine = await until("the window's engine profile", `return win("w1").then((w) => w.profile === "work" ? w.profile : null);`, 2000);
    await nativeProfile("w1", engine);
    if (!Array.isArray(trace) || trace.length < 5 || trace.some((row, i) => !Array.isArray(row) || !Number.isFinite(row[0]) || !Number.isFinite(row[1]) || !Array.isArray(row[2]) || row[2].length !== 3 || row[2].some((o) => !Number.isFinite(o)) || i > 0 && !(row[0] > trace[i - 1][0]))) throw new Error(`invalid trace ${JSON.stringify(trace)}`);
    const t0 = trace[0][0];
    mine.flick = trace.map(([t, p, tint]) => [t - t0, p, tint]);
    if (!near(trace.at(-1)[1], 1, 1e-9)) throw new Error(`ended at ${trace.at(-1)[1]}`);
    const tracking = [18, 40, 62, 62].map((distance) => distance * 0.5 / width);
    if (tracking.some((position, i) => !near(trace[i][1], position))) throw new Error(`tracking ${JSON.stringify(trace.slice(0, 4))}, expected ${JSON.stringify(tracking)}`);
    const releaseTime = trace[3][0];
    let worst = 0;
    for (const [t, p] of trace.slice(4)) {
      const expected = springAt(width, t - releaseTime).position;
      worst = Math.max(worst, Math.abs(p - expected));
      if (!near(p, expected, 0.03)) throw new Error(`position ${p} at ${t - releaseTime}, expected ${expected}`);
    }
    const duration = trace.at(-1)[0] - releaseTime;
    const expectedDuration = springDuration(width);
    if (!near(duration, expectedDuration, 0.034)) throw new Error(`settle ${duration}, expected ${expectedDuration}`);
    for (const [, p, tint] of mine.flick) {
      tint.forEach((o, k) => {
        const want = k === 0 ? 1 : Math.min(1, Math.max(0, p - (k - 1)));
        if (!near(o, want, 1e-3)) throw new Error(`tint ${k} ${o} at position ${p}, expected ${want}`);
      });
    }
    return { frames: mine.flick.length, settle: mine.flick.at(-1)[0], duration, expectedDuration, worst, engine };
  });

  await rep.check(`${tag}-reverse-mid-settle`, async () => {
    await reset();
    const second = steps([18, 22, 22], true).map((s) => ({ ...s, atMs: s.atMs + 140, timestampMs: s.timestampMs + 140 }));
    await run(`return swipe("w1", ${SIDEBAR}, ${JSON.stringify([...flick(-1), ...second])});`);
    await until("the pager settles", `return S.devPagerState("w1").then((p) => p.phase === "idle" || null);`);
    await sleep(300);
    mine.reverse = [await profileOf("w1"), (await pagerState("w1")).position];
    if (mine.reverse[0] !== "default" || !Object.is(mine.reverse[1], 0)) throw new Error(JSON.stringify(mine.reverse));
    await nativeProfile("w1", mine.reverse[0]);
    return mine.reverse;
  });

  await rep.check(`${tag}-store-switches`, async () => {
    await reset();
    await run(`st().switchProfile("w1", "play"); return true;`);
    const jumped = await until("the pager jumps to Play", `return S.devPagerState("w1").then((p) => p.selected === 2 && p.position === 2 && p.phase === "idle" ? p : null);`);
    await nativeProfile("w1", "play");
    const d = JSON.parse(await run(`return P.describe("w1");`));
    if (d.tint.pages.map((p) => p.opacity).join() !== "1,1,1") throw new Error(JSON.stringify(d.tint));
    const trace = await traced(`ac.actions.switchProfile("w1", "default", true); return true;`, 900);
    await until("Personal", `return st().windows.w1.profileId === "default" || null;`, 1800);
    await nativeProfile("w1", "default");
    if (trace.length < 5 || trace.at(-1)[1] !== 0) throw new Error(`animated switch: ${trace.length} frames, ending at ${trace.at(-1)?.[1]}`);
    return { jumped: jumped.position, frames: trace.length };
  });

  await rep.check(`${tag}-held-strip`, async () => {
    await reset();
    await run(`return swipe("w2", ${STRIP}, ${JSON.stringify(steps([-18, -22, -22]))});`);
    try {
      const [held, d, strips] = await run(`return Promise.all([S.devPagerState("w2"), P.describe("w2")]).then(([held, d]) => [held, JSON.parse(d), acPerf.findFibers("NativeTopStrip", 50).map((f) => f.memoizedProps).filter((p) => p.windowId === "w2" && p.floating === false).map((p) => p.pageWidth)]);`);
      const width = strips.length === 1 && Number.isFinite(strips[0]) && strips[0] >= 0 ? strips[0] + 2 * 15 : NaN;
      mine.strip = held.position;
      if (!Number.isFinite(width) || width <= 0 || !near(d.strip.pageWidth, width) || held.phase !== "tracking" || !(held.position > 0.02) || !near(held.position, 62 * 0.5 / width)) throw new Error(JSON.stringify({ held, target: d.strip, strips, width }));
      return held.position;
    } finally {
      await release("w2", STRIP);
    }
  });

  await rep.check(`${tag}-peek-flick`, async () => {
    await reset();
    const seen = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w2"];
      const original = st().switchProfile;
      const calls = [];
      const profiles = [];
      ac.store.setState({ switchProfile: (...a) => { calls.push(a[1]); return original(...a); } });
      const stop = ac.store.subscribe((s, prev) => { if (s.windows.w2?.profileId !== prev.windows.w2?.profileId) profiles.push(s.windows.w2.profileId); });
      st().toggleSidebar("w2");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => swipe("w2", 700, 22, ${JSON.stringify(flick(-1))}))
        .then(() => settle(900)).then(() => S.devPagerState("w2"))
        .then((p) => { stop(); ac.store.setState({ switchProfile: original }); const out = { calls, profiles, live: peek().live, phase: p.phase, position: p.position, profile: st().windows.w2.profileId }; peek().hide(); return settle(600).then(() => { st().toggleSidebar("w2"); return settle(600); }).then(() => out); });`);
    mine.peek = seen;
    if (!seen.live || seen.profile !== "work" || seen.phase !== "idle" || seen.position !== 1 || JSON.stringify(seen.profiles) !== '["work"]') throw new Error(JSON.stringify(seen));
    if (seen.calls.length !== 0) throw new Error(`JS switched too: ${JSON.stringify(seen)}`);
    await nativeProfile("w2", seen.profile);
    return seen;
  });

  await app.quit();
  app = null;
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
