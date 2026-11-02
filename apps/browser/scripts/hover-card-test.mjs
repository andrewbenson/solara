#!/usr/bin/env node
import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node hover-card-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-hover-card-"));
const rep = reporter(join(scratch, "hover-card-test.log"), { name: "hover-card-test" });
const ids = Array.from({ length: 8 }, (_, i) => `t${i}`);
const titleOf = (id, i) => (i === 3 ? "Anker USB-C to USB-C Cable (240W, 6 ft), Nylon Braided" : `Tab ${id}`);
const tabs = ids.map((id, i) => ({ id, url: `data:text/html,<title>${titleOf(id, i)}</title>`, title: titleOf(id, i), lastActiveAt: Date.now() - i * 60_000 }));

const midnight = new Date();
midnight.setHours(24, 0, 0, 0);
const minutesLeftToday = Math.floor((midnight.getTime() - Date.now()) / 60_000);
const startToday = (minutes) => Math.min(minutes, minutesLeftToday - 5);
const calendarFixture = {
  calendars: [{ id: "work", title: "Work", color: "#3478F6", account: "Fixture", accountType: "local", owned: true }],
  events: [
    { id: "standup", calendarId: "work", color: "#3478F6", title: "Standup", startInMinutes: startToday(3), durationMinutes: 15, allDay: false, location: "", notes: "", url: "https://zoom.us/j/123456789", cancelled: false, declined: false, organizer: null, attendees: [{ name: "Ada Lovelace", email: "ada@example.com", me: false }] },
    { id: "review", calendarId: "work", color: "#34C759", title: "Design review", startInMinutes: startToday(90), durationMinutes: 30, allDay: false, location: "", notes: "", url: "", cancelled: false, declined: false, organizer: null, attendees: [] },
  ],
};

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  files: { "calendar-fixture.json": calendarFixture },
  env: { SOLARA_NATIVE_SHELL: "1", SOLARA_CALENDAR_FIXTURE: "1" },
  probe: true,
  session: session({ profiles: ["Personal", "Work"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t1" }, frame: [60, 60, 1200, 800] }], tabs }),
  ready: "return !!ac.store",
});
let nativePollDeadline = 0;
const run = (body, timeout = 30000) => {
  if (nativePollDeadline) {
    if (nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms remaining");
    timeout = Math.min(timeout, 1000);
  }
  return app.eval(body, { timeout });
};
const untilSnapshot = async (what, accept, ms = 3000, args = {}) => {
  const end = Date.now() + ms;
  let last;
  do {
    if (!app.alive) throw new Error(`${what}: the owned app exited`);
    if (end - Date.now() < 1000) break;
    last = await app.snapshot({ windowId: "w1", ...args }, { timeout: 1000 });
    assert.equal(last.schema, 1);
    nativePollDeadline = end;
    try {
      if (last.consistent && Date.now() < end && await accept(last) && Date.now() < end) return last;
    } finally {
      nativePollDeadline = 0;
    }
    await sleep(40);
  } while (Date.now() < end);
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const near = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => Number.isFinite(v) && Number.isFinite(b[i]) && Math.abs(v - b[i]) <= 0.5);
const crossCard = async (js) => {
  if (js && !["shown", "hidden"].includes(js.phase)) return js;
  const snapshot = await untilSnapshot("hover card", async (s) => {
    js = JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1")`));

    const n = s.windows[0]?.hoverCard;
    const same = js === null ? n === null : n && ["shown", "hidden"].includes(js.phase) && n.phase === js.phase && n.kind === js.kind && (!js.frame || near(n.frame, js.frame)) &&
      ["inWindow", "onScreen", "typingInCard", "titleShown", "title", "more", "rows"].every((key) => !(key in js) || isDeepStrictEqual(n[key], js[key])) &&
      ["buttons", "events"].every((key) => !js[key] || n[key] && isDeepStrictEqual(Object.keys(n[key]).sort(), Object.keys(js[key]).sort()) && Object.keys(js[key]).every((label) => near(n[key][label], js[key][label])));
    if (same) return true;
    return false;
  });
  const native = snapshot.windows[0].hoverCard;
  if (!js) { assert.equal(native, js); return js; }
  for (const key of ["kind", "phase", "inWindow", "onScreen", "typingInCard", "titleShown", "title", "more", "rows"]) if (key in js) assert.deepEqual(native[key], js[key], `native hover card ${key}`);
  for (const key of ["opacity", "scale"]) if (key in js) assert.ok(Math.abs(native[key] - js[key]) <= 0.02, `native hover card ${key}`);
  if (js.frame) assert.ok(near(native.frame, js.frame), "native hover card frame");
  for (const key of ["buttons", "events"]) if (js[key]) {
    assert.deepEqual(Object.keys(native[key]).sort(), Object.keys(js[key]).sort(), `native hover card ${key} labels`);
    for (const label of Object.keys(js[key])) assert.ok(near(native[key][label], js[key][label]), `native ${key} ${label} frame`);
  }
  return js;
};
const card = async () => crossCard(JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1")`)));
const hover = () => run(`const h = ac.sidebarRows.useSidebarUi.getState().hover; return h ? h.id : null`);
const point = (x, y) => run(`return ac.shell.devSetPointer("w1", { x: ${x}, y: ${y} })`);
const rnCards = () => run(`return acPerf.findFibers("DiaTabCard", 5).length`);
const row = async (id) => run(`return ac.sidebarRows.measureRow("w1", ${JSON.stringify(id)})`);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    const got = await test();
    if (got) return got;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what} (hover ${await hover()}, card ${JSON.stringify(await card())}, ${await run(`const h = ac.sidebarHover; return JSON.stringify({ rows: ["t3","t4","t5"].filter(h.pointerOnRow), onCard: h.pointerOnCard(), ui: ac.sidebarRows.useSidebarUi.getState() })`)})`);
    await sleep(40);
  }
};
const onRow = async (id) => {
  const r = await row(id);
  await point(r.x + 60, Math.round(r.y + r.height / 2));
  return r;
};
const shown = (id) => until(`the card for ${id}`, async () => (await hover()) === id && (await card())?.phase === "shown" && (await card()));
const gone = (what) => until(`the card to leave on ${what}`, async () => (await card())?.phase === "hidden" && !(await hover()), 1500);

try {
  await sleep(3000);

  await rep.check("a card waits for the 500 ms hover intent, then shows natively with no RN card", async () => {
    const r = await row("t3");
    const early = await run(`const H = globalThis.expo.modules.SolaraHosted; return ac.shell.devSetPointer("w1", { x: ${r.x + 60}, y: ${Math.round(r.y + r.height / 2)} }).then(() => { const t0 = Date.now(); return new Promise((done) => setTimeout(done, 300)).then(() => H.sidebarHoverCard("w1")).then((c) => ({ ms: Date.now() - t0, hover: ac.sidebarRows.useSidebarUi.getState().hover, phase: JSON.parse(c)?.phase ?? "hidden" })); })`);
    assert.ok(early.ms < 450, `sampled in time (${early.ms} ms)`);
    assert.equal(early.hover, null, "nothing at 300 ms");
    assert.equal(early.phase, "hidden", "no native card at 300 ms");
    await untilSnapshot("native hover phase after the early sample", async (snapshot) => {
      const live = JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1")`));
      return (snapshot.windows[0]?.hoverCard?.phase ?? "hidden") === (live?.phase ?? "hidden");
    });
    const c = await shown("t3");
    rep.say(`shown at ${c.frame.map(Math.round)}`);
    assert.ok(c.inWindow && c.onScreen && c.opacity > 0.99, "on screen and opaque");
    assert.equal(await rnCards(), 0, "RN draws no Dia card of its own");
    assert.deepEqual(Object.keys(c.buttons).sort(), ["Bookmark", "Open in Split View", "Pin"]);
    assert.equal(c.titleShown, "Anker USB-C to USB-C Cable (240W, 6 ft), Nylo", "the long title truncates where RN's does");
  });

  await rep.check("moving from the row onto the card keeps it past the hide delay", async () => {
    const c = await card();
    const [x, y, w, h] = c.frame;
    await point(x + w / 2, y + 12);
    await sleep(600);
    assert.equal(await hover(), "t3");
    assert.equal((await card()).phase, "shown");
  });

  await rep.check("the card's Pin button pins the tab and the card stays", async () => {
    const [x, y, w, h] = (await card()).buttons.Pin;
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("t3 pinned", () => run(`return !!ac.store.getState().tabs.t3.pinned`));
    await until("the card to show Unpin", async () => !!(await card())?.buttons?.Unpin);
    assert.equal((await card()).phase, "shown");
    await run(`ac.store.getState().togglePin("t3"); return true`);
  });

  await rep.check("hovering away hides it after the 160 ms delay and the 100 ms fade", async () => {
    const early = await run(`const H = globalThis.expo.modules.SolaraHosted; return ac.shell.devSetPointer("w1", { x: 900, y: 600 }).then(() => { const t0 = Date.now(); return new Promise((done) => setTimeout(done, 80)).then(() => H.sidebarHoverCard("w1")).then((c) => ({ ms: Date.now() - t0, phase: JSON.parse(c)?.phase })); })`);
    if (early.ms < 150) assert.equal(early.phase, "shown", `still shown inside the delay (${early.ms} ms)`);
    await untilSnapshot("hover away reaches the native fade", (s) => ["leaving", "hidden"].includes(s.windows[0]?.hoverCard?.phase));
    await gone("hover away");
  });

  await rep.check("a tab switch keeps it, as RN's does, and a space switch dismisses it", async () => {
    await onRow("t4");
    await shown("t4");
    await run(`ac.actions.switchToTab("t5"); return true`);
    await sleep(400);
    assert.equal((await card()).phase, "shown", "kept through the tab switch");
    await run(`ac.store.getState().switchProfile("w1", "work"); return true`);
    await gone("a space switch");
    await run(`ac.store.getState().switchProfile("w1", "default"); return true`);
    await sleep(600);
  });

  await rep.check("a click in the sidebar dismisses it", async () => {
    await point(900, 600);
    await gone("hover away");
    const r = await onRow("t6");
    await shown("t6");
    await run(`return ac.shell.devClick("w1", { x: ${r.x + 60}, y: ${Math.round(r.y + r.height / 2)} })`);
    await gone("a click");
  });

  await rep.check("a group's card lists its tabs natively, filters as you type and Return switches to the match", async () => {
    await point(900, 600);
    await gone("hover away");
    const g = await run(`const s = ac.store.getState(); const g = s.createGroup(["t2", "t3", "t4"], { name: "Group" }); ac.store.getState().updateGroup(g, { collapsed: true }); return g`);
    await sleep(600);
    const r = await row(g);
    assert.ok(r, "the group's row is measured");
    await point(r.x + 60, Math.round(r.y + r.height / 2));
    const c = await shown(g);
    assert.equal(c.kind, "group");
    assert.deepEqual([...c.rows].sort(), ["t2", "t3", "t4"]);
    assert.equal(await run(`return acPerf.findFibers("GroupPanel", 5).length`), 0, "RN draws no group panel");
    const [x, y, w] = c.frame;
    await point(x + w / 2, y + 20);
    await until("the search field to take the keys", async () => (await card())?.typingInCard);
    await run(`return ac.shell.devTypeKeys("w1", "Anker", 10)`);
    await until("one match", async () => Object.keys((await card())?.buttons ?? {}).length === 1);
    await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
    await until("t3 active", () => run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId] === "t3"`));
    await gone("choosing a row");
  });

  await rep.check("a live pull request's card shows natively, and its comments line opens the pull request", async () => {
    await point(900, 600);
    await gone("hover away");
    const folder = await run(`
      const { store } = ac.live;
      const pr = { number: 7, repo: "solara/app", author: "octocat", authorAvatar: null, draft: false, headRef: "h7", baseRef: "main", review: "approved",
        mergeable: "mergeable", checks: [{ name: "lint", state: "failure", url: "https://ci.example/lint" }], comments: 2, unresolvedThreads: 0, additions: 4, deletions: 1, changedFiles: 1 };
      return store.createFolder("default", "pullRequests").then((folder) =>
        store.applyFetch(folder, [{ id: "pr7", source: "github", url: "https://example.com/pr/7", title: "Pull request 7", subtitle: "", icon: null, updatedAt: Date.now(), section: "authored", pr }], {})
          .then(() => store.setStatus(folder, { state: "idle", lastFetch: Date.now(), error: null }))
          .then(() => folder));`);
    await sleep(800);
    const key = `live|${folder}|pr7`;
    const r = await row(key);
    assert.ok(r, "the live row is measured");
    await point(r.x + 60, Math.round(r.y + r.height / 2));
    const c = await shown(key);
    assert.equal(c.kind, "live");
    assert.equal(await run(`return acPerf.findFibers("LiveItemCard", 5).length`), 0, "RN draws no live card");
    const before = await run(`return ac.store.getState().windows.w1.tabIds.length`);
    const [x, y, w, h] = c.frame;
    await point(x + 40, y + h - 20);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + 40}, y: ${y + h - 20} })`);
    await until("the pull request to open", async () => (await run(`const s = ac.store.getState(); return s.windows.w1.tabIds.map((id) => s.tabs[id].url)`)).includes("https://example.com/pr/7"));
    await gone("opening the item");
    assert.ok((await run(`return ac.store.getState().windows.w1.tabIds.length`)) >= before);
  });

  await rep.check("a playing pinned tab's player card shows natively, and its artwork goes back to the tab", async () => {
    await point(900, 600);
    await gone("hover away");
    await run(`ac.store.getState().updateSettings({ sidebarMediaControls: true }); ac.store.getState().togglePin("t0");
      ac.media.setState((m) => ({ sessions: { ...m.sessions, t0: { title: "A Song", artist: "An Artist", album: "", artwork: null, playbackState: "playing", position: 30, duration: 200,
        playbackRate: 0, timestamp: Date.now(), hasVideo: false, actions: ["play", "pause"], controllable: true, playedAt: Date.now() } } })); return true`);
    await sleep(800);
    await onRow("t0");
    const c = await shown("t0");
    assert.equal(c.kind, "player");
    assert.deepEqual([c.frame[2], c.frame[3]], [320, 76]);
    assert.equal(await run(`return acPerf.findFibers("HoverPlayer", 5).length`), 0, "RN draws no player card");
    const [x, y, w, h] = c.buttons["Back to Tab"];
    await point(x + w / 2, y + h / 2);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("t0 active", () => run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId] === "t0"`));
    await gone("going back to the tab");
  });

  await rep.check("a pinned calendar tab's card lists today's events natively, and a click on one shows the tab", async () => {
    await point(900, 600);
    await gone("hover away");
    const tab = await run(`return ac.store.getState().newTab("w1", { url: "https://calendar.google.com/calendar/u/0/r", pinned: true, background: true })`);
    await until("the fixture's events", async () => (await run(`return ac.pages.calendar.getState().events.length`)) >= 2, 5000);
    await sleep(800);
    await onRow(tab);
    const c = await shown(tab);
    assert.equal(c.kind, "calendar");
    assert.equal(c.frame[2], 300);
    assert.equal(await run(`return acPerf.findFibers("CalendarPreview", 5).length`), 0, "RN draws no calendar preview");
    const review = await until("the review row", async () => Object.entries((await card())?.events ?? {}).find(([k]) => k.startsWith("event:review"))?.[1]);
    assert.ok(Object.keys((await card()).events).some((k) => k.startsWith("event:standup")), "the standup row");
    const [x, y, w, h] = review;
    await point(x + w / 2, y + h / 2);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("the calendar tab active", async () => (await run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId]`)) === tab);
  });

  await rep.check("the card fades in and out over 100 ms on RN's curve and scales on RN's springs, frame by frame", async () => {
    await point(900, 600);
    await gone("hover away");
    const on = await onRow("t5");
    const [x, y, w, h] = (await shown("t5")).frame;
    const probe = { x: x + 4, y: Math.round(y + h / 2) };
    await point(900, 600);
    await gone("hover away");
    const sample = (phase, to) => run(`
      const want = ${JSON.stringify(phase)};
      let t0 = null;
      const unsub = ac.sidebarRows.useSidebarUi.subscribe((s) => { if (t0 === null && (want === "in" ? !!s.hover : !s.hover)) t0 = performance.now(); });
      const out = [];
      const start = performance.now();
      const loop = () => {
        const at = performance.now();
        return globalThis.expo.modules.SolaraHosted.presentedAt("w1", ${probe.x}, ${probe.y}, [${w * 0.75}, ${w + 1}], [${h * 0.75}, ${h + 1}]).then((j) => {
          out.push([at, JSON.parse(j)]);
          if ((t0 !== null && at - t0 > 400) || at - start > 3000) return;
          return loop();
        });
      };
      return ac.shell.devSetPointer("w1", ${JSON.stringify(to)}).then(loop).then(() => { unsub(); return JSON.stringify(out.map(([at, p]) => [at - t0, p.opacity, p.scale, p.probeSequence, p.rect])); });
    `).then(JSON.parse);
    const bezier = (x1, y1, x2, y2) => (x) => {
      let lo = 0, hi = 1, t = 0.5;
      for (let i = 0; i < 40; i++) {
        t = (lo + hi) / 2;
        const bx = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t * t * x2 + t ** 3;
        if (bx < x) lo = t; else hi = t;
      }
      return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t * t * y2 + t ** 3;
    };
    const ease = bezier(0.25, 0.46, 0.45, 0.94);
    const spring = (response, damping, from, to) => (ms) => {
      const omega = (2 * Math.PI) / response, damped = omega * Math.sqrt(1 - damping * damping), t = Math.max(0, ms) / 1000, x0 = from - to;
      return to + Math.exp(-damping * omega * t) * (x0 * Math.cos(damped * t) + ((damping * omega * x0) / damped) * Math.sin(damped * t));
    };
    const fit = (frames, curve) => {
      let best = { start: 0, error: Infinity };
      for (let start = -30; start <= 80; start += 0.1) {
        const error = Math.max(...frames.map(([t, v]) => Math.abs(curve(t - start) - v)));
        if (error < best.error) best = { start, error };
      }
      return best;
    };
    const frames = (samples, index, keep) => samples.filter((s, i) => i > 0 && s[index] !== samples[i - 1][index] && keep(s)).map((s) => [s[0], s[index]]);
    for (const [phase, to, fade, scale] of [
      ["in", { x: on.x + 60, y: Math.round(on.y + on.height / 2) }, (t) => ease(Math.min(1, Math.max(0, t / 100))), spring(0.25, 0.75, 0.92, 1)],
      ["out", { x: 900, y: 600 }, (t) => 1 - ease(Math.min(1, Math.max(0, t / 100))), spring(0.2, 0.6, 1, 0.92)],
    ]) {
      const samples = await sample(phase, to);
      const nativeSnapshot = await untilSnapshot("native presentation records", (s) => s.windows[0]?.hoverPresentationTrace?.some((p) => p.sequence === samples.at(-1)[3]));
      const records = nativeSnapshot.windows[0].hoverPresentationTrace;
      const bySequence = new Map(records.map((p) => [p.sequence, p]));
      const mirrored = samples.filter((sample) => bySequence.has(sample[3]));
      assert.equal(mirrored.length, Math.min(128, samples.length), "the native ring mirrors the bounded JS tail");
      for (const [, opacity, scale, sequence, rect] of mirrored) {
        const native = bySequence.get(sequence);
        assert.equal(native.opacity, opacity, `presentation ${sequence} opacity`);
        assert.equal(native.scale, scale, `presentation ${sequence} scale`);
        assert.ok(near(native.rect, rect), `presentation ${sequence} frame`);
      }
      const endpoint = await untilSnapshot("native presentation endpoint", (s) => s.windows[0]?.hoverCard?.phase === (phase === "in" ? "shown" : "hidden"), 3000,
        { hoverPresentation: [probe.x, probe.y, w * 0.75, w + 1, h * 0.75, h + 1] });
      if (phase === "in") {
        assert.ok(Math.abs(endpoint.windows[0].hoverPresentation.opacity - samples.at(-1)[1]) <= 0.02);
        assert.ok(Math.abs(endpoint.windows[0].hoverPresentation.scale - samples.at(-1)[2]) <= 0.02);
      }
      const opacity = fit(frames(samples, 1, (s) => s[1] > 0.001 && s[1] < 0.999), fade);
      const size = fit(frames(samples, 2, (s) => s[2] > 0.5 && s[1] > 0.02), scale);
      rep.say(`${phase}: the fade starts ${opacity.start.toFixed(1)} ms after the hover changes, off RN's curve by ${opacity.error.toFixed(3)} at worst; the scale ${size.start.toFixed(1)} ms, off by ${size.error.toFixed(4)}`);
      assert.ok(opacity.error < 0.04, `${phase} fade on RN's curve (${opacity.error})`);
      assert.ok(size.error < 0.004, `${phase} scale on RN's spring (${size.error})`);
      assert.ok(opacity.start < 40 && size.start < 40, `${phase} starts no later than RN's (${opacity.start}, ${size.start} ms)`);
      await sleep(600);
    }
  });

  await rep.check("a pinned folder's peek shows natively with its first eight tabs, and a click on one shows the tab", async () => {
    await point(900, 600);
    await gone("hover away");
    const setup = JSON.parse(await run(`const s = ac.store.getState();
      const ids = Array.from({ length: 10 }, (_, i) => s.newTab("w1", { url: "data:text/html,<title>Peek" + i + "</title>", background: true }));
      s.pinTabs(ids, true);
      return new Promise((r) => setTimeout(r, 800)).then(() => JSON.stringify({ ids, folder: ac.pages.tileFolders.make(ids) }))`));
    assert.ok(setup.folder, "a folder made");
    await sleep(1200);
    const tile = JSON.parse(await run(`return ac.pages.tileFolders.measure("w1", ${JSON.stringify(setup.folder)}).then((a) => JSON.stringify(a))`));
    await point(tile.x + tile.width / 2, tile.y + tile.height / 2);
    const c = await shown(setup.folder);
    assert.equal(c.kind, "folder");
    assert.equal(c.frame[2], 264);
    assert.equal(c.title, "Folder · 10 tabs");
    assert.equal(c.more, "and 2 more");
    assert.equal(await rnCards(), 0, "RN draws no Dia card of its own");
    assert.equal(await run(`return acPerf.findFibers("FolderPeek", 5).length`), 0, "RN draws no folder peek");
    const titles = Object.keys(c.buttons);
    assert.equal(titles.length, 8, `eight rows (${titles})`);
    const row = titles.find((t) => t.includes("Peek2"));
    assert.ok(row, `a row for the third tab (${titles})`);
    const [x, y, w, h] = c.buttons[row];
    await point(x + w / 2, y + h / 2);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("Peek 2 active", async () => (await run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId]`)) === setup.ids[2]);
    await gone("a click on a row");
  });

  await rep.check("scrolling the sidebar dismisses it, as RN's does", async () => {
    await point(900, 600);
    await gone("hover away");
    const extra = JSON.parse(await run(`const ids = []; for (let i = 0; i < 30; i++) ids.push(ac.store.getState().newTab("w1", { url: "data:text/html,<title>More " + i + "</title>", background: true })); return JSON.stringify(ids);`));
    try {
      await run(`return globalThis.expo.modules.SolaraSidebarDrag.scrollTo("w1", 0)`);
      await sleep(600);
      await onRow("t6");
      await shown("t6");
      const after = await run(`const H = globalThis.expo.modules.SolaraHosted; return globalThis.expo.modules.SolaraSidebarDrag.scrollTo("w1", 120).then(() => { const t0 = Date.now(); return new Promise((done) => setTimeout(done, 250)).then(() => H.sidebarHoverCard("w1")).then((c) => ({ ms: Date.now() - t0, hover: ac.sidebarRows.useSidebarUi.getState().hover, phase: JSON.parse(c)?.phase ?? "hidden" })); })`);
      assert.ok(after.ms < 450, `sampled before a new hover intent could show (${after.ms} ms)`);
      assert.equal(after.hover, null, "the hover is dismissed");
      assert.notEqual(after.phase, "shown", "the native card is leaving or gone");
      const afterSnapshot = await untilSnapshot("scroll dismisses native card", (s) => ["leaving", "hidden"].includes(s.windows[0]?.hoverCard?.phase));
      assert.notEqual(afterSnapshot.windows[0].hoverCard.phase, "shown");
    } finally {
      await run(`ac.store.getState().closeTabs(${JSON.stringify(extra)}); return true`);
    }
  });
} finally {
  await app.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);
