#!/usr/bin/env node
import assert from "node:assert/strict";
import { sidebarSession, assertSidebarPosition } from "./sidebar-position-test.mjs";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node pin-rows-test.mjs <Debug Solara.app under apps/browser/build-*> [--native] [--keep-data]");
  console.error("  --native  also require that JavaScript decides nothing: its command handlers are switched off");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const nativeOnly = args.includes("--native");
const scratch = mkdtempSync(join(tmpdir(), "ac-pin-rows-"));
const rep = reporter(join(scratch, "pin-rows-test.log"), { name: "pin-rows-test" });
const ids = ["a", "b", "c", "d"];
const tabs = ids.map((id) => ({ id, url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }));
const fixture = sidebarSession({
  profiles: ["Personal"],
  windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "a" }, frame: [60, 60, 1200, 800] }],
  tabs,
});
fixture.groups = { g: { id: "g", windowId: "w1", profileId: "default", name: "Grp", icon: null, color: null, collapsed: false, pinned: false, tabIds: ["b", "c"] } };

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  session: session(fixture),
  ready: "return !!ac.store && !!ac.commandHandlers && !!expo.modules.SolaraApp.devWorkspaceMenuCommand",
});
const run = (body, timeout = 30000) => app.eval(body, { timeout });
const store = (body) => run(`const s = ac.store.getState(); ${body}`);

const jsView = () => store(`const w = s.windows.w1; return {
  rows: w.tabIds.filter((id) => s.tabs[id]?.pinned && s.tabs[id]?.pinnedAsRow),
  list: w.tabIds.filter((id) => !s.tabs[id]?.pinned),
  pinned: w.tabIds.filter((id) => s.tabs[id]?.pinned),
  group: s.groups.g?.tabIds ?? null };`);
const nativeView = () => run(`const m = globalThis.expo.modules.SolaraStoreAdapter;
  if (!m || typeof m.snapshot !== "function" || m.status().scope !== "everything") return null;
  const d = JSON.parse(m.snapshot()).data; const w = d.windows?.w1; if (!w) return null;
  return {
    rows: w.tabIds.filter((id) => d.tabs[id]?.pinned && d.tabs[id]?.pinnedAsRow),
    list: w.tabIds.filter((id) => !d.tabs[id]?.pinned),
    pinned: w.tabIds.filter((id) => d.tabs[id]?.pinned),
    group: d.groups?.g?.tabIds ?? null };`, 2000);

const until = async (what, read, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: the owned app exited`);
    last = await read().catch((error) => ({ error: error.message }));
    if (last && !last.error && accept(last)) return last;
    await sleep(80);
  }
  throw new Error(`${what}: never matched (${JSON.stringify(last)})`);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const expectView = async (what, want) => {
  const matches = (view) => Object.entries(want).every(([key, value]) => same(view[key], value));
  await until(`${what} (JS mirror)`, jsView, matches);
  const native = await nativeView();
  if (native) await until(`${what} (native store)`, nativeView, matches);
  else rep.say(`${what}: native store not owning everything; JS only`);
};

let handlerBaseline = null;
const checkHandlers = async (what) => {
  if (!nativeOnly) return;
  const stats = await run(`return ac.commandHandlers.stats()`);
  assert.equal(stats.enabled, false, `${what}: JS handlers unexpectedly enabled`);
  assert.equal(stats.calls, handlerBaseline.calls, `${what}: a JS handler made a decision`);
  assert.equal(stats.blocked, handlerBaseline.blocked, `${what}: the command fell through to disabled JS`);
};
const select = async (active, selection) => {
  await store(`s.activate(${JSON.stringify(active)}); s.setSelection("w1", ${JSON.stringify(selection)}); return true`);
  await until(`${active} active`, () => store(`return { active: Object.values(s.windows.w1.activeTabIds), selection: s.selection.w1 ?? [] }`),
    (v) => v.active.includes(active) && same(v.selection, selection));
  await sleep(150);
};
const viaPalette = () => run(`ac.runCommand({ command: "togglePinnedRow", arg: null, windowId: "w1" }); return true`);
const viaMenu = () => run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "togglePinnedRow", null)`);

try {
  await sleep(2500);
  await assertSidebarPosition(app);
  await expectView("the fixture", { rows: [], list: ["a", "b", "c", "d"], group: ["b", "c"] });
  if (nativeOnly) handlerBaseline = await run(`const baseline = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(false); return baseline;`);

  await rep.check("the palette's Move to Pinned takes a grouped tab to the rows, and Move out of Pinned puts it back in its group", async () => {
    await select("c", []);
    await viaPalette();
    await expectView("c in the rows", { rows: ["c"], list: ["a", "b", "d"] });
    await select("c", []);
    await viaPalette();
    await expectView("c back in its group", { rows: [], list: ["a", "b", "c", "d"], group: ["b", "c"] });
    await checkHandlers("palette");
  });

  await rep.check("the menu's Move to Pinned on a selection, and back in order", async () => {
    await select("a", ["a", "d"]);
    await viaMenu();
    await expectView("a and d in the rows", { rows: ["a", "d"], list: ["b", "c"] });
    await select("a", ["a", "d"]);
    await viaMenu();
    await expectView("a and d back", { rows: [], list: ["a", "b", "c", "d"], group: ["b", "c"] });
    await checkHandlers("menu");
  });

  await rep.check("neighbours pinned one at a time come back in their order", async () => {
    for (const id of ["d", "c"]) {
      await select(id, [id]);
      await viaPalette();
      await until(`${id} in the rows`, jsView, (v) => v.rows.includes(id));
    }
    await select("c", ["c", "d"]);
    await viaMenu();
    await expectView("c and d back", { rows: [], list: ["a", "b", "c", "d"], group: ["b", "c"] });
    await checkHandlers("neighbours");
  });

  await rep.check("on a tile, Move out of Pinned unpins it rather than making it a row", async () => {
    if (nativeOnly) await run(`ac.commandHandlers.setEnabled(true); return true`);
    await store(`s.pinTabs(["d"], true); return true`);
    await expectView("d a tile", { pinned: ["d"], rows: [] });
    if (nativeOnly) handlerBaseline = await run(`const baseline = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(false); return baseline;`);
    await select("d", []);
    await viaPalette();
    await expectView("d unpinned", { pinned: [], rows: [] });
    await checkHandlers("tile");
  });
} finally {
  if (nativeOnly) await run(`ac.commandHandlers.setEnabled(true); return true`).catch(() => {});
  await app.quit();
}
const passed = rep.summary();
if (!keep && passed) rmSync(scratch, { recursive: true, force: true });
else console.log(`data: ${scratch}`);
process.exit(passed ? 0 : 1);
