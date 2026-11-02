import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
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
  console.error("usage: node sidebar-bulk-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--keep-data]\n\nMany tabs duplicated, opened or closed at once leave the sidebar's rows at an even pitch, in store order, with no slide left part way and the row under the pointer the one hovered (pending while the screen is locked, when the window shell's display link doesn't resolve the pointer).");
  process.exit(2);
}
const appPath = resolve(appArg);
const port = args.find((a) => a.startsWith("--port="))?.slice(7);
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-bulk-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "sidebar-bulk-test.log"), { name: "sidebar-bulk-test" });
const ids = Array.from({ length: 15 }, (_, i) => `t${i}`);
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1200, 800], tabIds: ids, activeTabIds: { default: "t0" } }],
  tabs: ids.map((id) => ({ id, url: `https://example.com/?${id}`, title: `Tab ${id}` })),
});

const SETTLED = `
  const s = ac.store.getState();
  const w = s.windows.w1;
  const list = w.tabIds.filter((id) => !s.tabs[id].pinned);
  return globalThis.expo.modules.SolaraHosted.sidebarMotion("w1").then(JSON.parse).then((motion) => {
    if (!motion) throw new Error("native sidebar motion unavailable");
    const moving = motion.rows.filter((row) => !row.box && (!Number.isFinite(row.shownY) || !Number.isFinite(row.y) || row.shownY !== row.y || row.alpha !== 1 || row.retired)).map((row) => row.key);
    const clipped = motion.rows.filter((row) => !row.box && row.clip !== null).map((row) => row.key);
    return Promise.all(list.map((id) => ac.sidebarRows.measureRow("w1", id).then((f) => ({ id, f })))).then((rows) => ({ list, rows, moving, clipped }));
  });`;

let app = null;
try {
  app = await launch(appPath, { data, port, session: fixture, onboarded: true });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  const run = (body) => evaluate(body, { timeout: 60000 });
  await sleep(1500);

  const untilSnapshot = async (what, accept, ms = 5000) => {
    const deadline = Date.now() + ms;
    let last;
    while (Date.now() < deadline) {
      if (!app.alive) throw new Error(`${what}: app exited`);
      if (Math.min(deadline, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
      last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
      if (Date.now() < deadline && !last.error && last.consistent && await acceptSnapshot(deadline, accept, last) && Date.now() < deadline) return last;
      await sleep(100);
    }
    throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
  };

  const locked = screenLocked();
  const settled = async (what) => {
    await sleep(1200);
    let list, rows;
    const native = await untilSnapshot(`${what} native tab order`, async (state) => {
      const sample = await run(SETTLED);
      ({ list, rows } = sample);
      assert.deepEqual(sample.moving, [], `${what}: rows left part way through their slide`);
      assert.deepEqual(sample.clipped, [], `${what}: rows left clipped`);
      return isDeepStrictEqual(state.windows[0]?.tabIds, list);
    });
    assert.deepEqual(native.windows[0].tabIds, list, `${what}: native store order differs from the measured rows`);
    assert.deepEqual(native.tabs.map((tab) => tab.id).sort(), [...list].sort(), `${what}: native tab IDs differ from JS`);
    const shown = rows.filter((r) => r.f);
    const placed = [...shown].sort((a, b) => a.f.y - b.f.y);
    assert.deepEqual(placed.map((r) => r.id), shown.map((r) => r.id), `${what}: rows out of store order`);
    for (let i = 1; i < placed.length; i++) {
      const pitch = placed[i].f.y - placed[i - 1].f.y;
      assert.ok(Math.abs(pitch - 37) < 0.6, `${what}: ${placed[i - 1].id} -> ${placed[i].id} is ${pitch} apart, not 37`);
    }
    const visible = placed.filter((r) => r.f.y > 40 && r.f.y + r.f.height < 700);
    if (locked) {
      rep.record(`${what}: the row under the pointer is the one hovered`, { skip: screenLockedPending });
      rep.log(`${what}: ${list.length} rows`);
      return;
    }
    for (const row of [visible[1], visible[Math.floor(visible.length / 2)], visible.at(-2)]) {
      await run(`return ac.shell.devSetPointer("w1", { x: 700, y: 500 });`);
      await sleep(300);
      await run(`return ac.shell.devSetPointer("w1", { x: ${row.f.x + 40}, y: ${row.f.y + row.f.height / 2} });`);
      await sleep(800);
      const hovered = await run(`return ac.sidebarRows.sidebarUi().hover?.id ?? null;`);
      assert.equal(hovered, row.id, `${what}: the pointer over ${row.id} hovers ${hovered}`);
    }
    await run(`return ac.shell.devSetPointer("w1", { x: 700, y: 500 });`);
    rep.log(`${what}: ${list.length} rows`);
  };

  await rep.check("eight tabs duplicated at once settle at an even pitch", async () => {
    await run(`const s = ac.store.getState(); s.windows.w1.tabIds.slice(2, 10).forEach((id) => ac.store.getState().duplicateTab(id)); return true;`);
    await settled("duplicate");
  });
  await rep.check("eight tabs opened at once settle at an even pitch", async () => {
    await run(`for (let i = 0; i < 8; i++) ac.store.getState().newTab("w1", { url: "https://example.com/?new" + i, background: true }); return true;`);
    await settled("open");
  });
  await rep.check("six tabs closed at once settle at an even pitch", async () => {
    await run(`const s = ac.store.getState(); s.windows.w1.tabIds.slice(3, 15).filter((_, i) => i % 2 === 0).forEach((id) => ac.store.getState().closeTab(id)); return true;`);
    await settled("close");
  });
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);
