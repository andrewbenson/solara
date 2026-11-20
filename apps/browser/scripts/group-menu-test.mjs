#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session } from "../../../scripts/lib/instance.mjs";
import { sidebarSession } from "./sidebar-position-test.mjs";

const HELP = "usage: node apps/browser/scripts/group-menu-test.mjs <Debug Solara.app> [--keep-data]\n\nA group's context menu, opened with a real right click on a sidebar header and a strip chip in hidden windows, answered through the menu's Debug hook: the rows and their order, colour, collapse, pin, duplicate, new tab, nested group, ungroup, delete and Move to Bookmark Bar each change the store as the JavaScript menu did, and while a menu is up the peek is held (native layout: the reveal hold; JS layout: menuShown) and released after. In a build where Swift owns the menu, its Debug counter rises by one per menu and the test requires it.";
const args = process.argv.slice(2);
if (args.includes("--help") || !args.find((a) => !a.startsWith("--"))) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const appPath = resolve(args.find((a) => !a.startsWith("--")));
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-group-menu-"));
const rep = reporter(join(scratch, "group-menu-test.log"), { name: "group-menu-test" });
const page = (id) => `data:text/html,<title>${id}</title>${id}`;
const fixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [80, 80, 1100, 760], activeTabIds: { default: "f" } }],
  tabs: ["a", "b", "c", "d", "e", "f", "g", "h"].map((id) => ({ id, url: page(id), title: id.toUpperCase() })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabGroup: true, newTabOpens: "newTab" },
}));
const ROWS = ["rename", "icon", "Color", "-", "newTab", "nest", "pin", "duplicate", "collapse", "-", "copy", "copyMd", "-", "ungroup", "bookmarkBar", "close", "delete"];

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const D = globalThis.expo.modules.SolaraSidebarDrag;
const M = globalThis.expo.modules.SolaraShell;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const hits = (id, xs, ys) => win(id).then((n) => Promise.all(xs.flatMap((x) => ys.map((y) => C.devWindow(n, "hit:" + x + "," + y).then((h) => [x, y, h])))));
const menus = () => typeof D.devGroupMenus === "function" ? D.devGroupMenus() : Promise.resolve(null);
const revealHeld = (id) => typeof D.devRevealHeld === "function" ? D.devRevealHeld(id) : Promise.resolve(null);
const rightClick = (id, x, y) => win(id).then((n) => C.devWindow(n, "click:" + x + "," + y + ",right")).then(() => settle(350));
`;

let app;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const range = (from, count) => Array.from({ length: Math.max(0, Math.ceil(count)) }, (_, i) => Math.round(from) + i);
let swiftOwned = null;

const header = async (windowId, groupId) => {
  const probe = JSON.parse(await run(`return D.startProbe(${JSON.stringify(windowId)});`));
  const item = probe?.items.find((i) => i.kind === "group" && (i.groupId === groupId || String(i.key).includes(groupId)));
  assert.ok(item && item.w > 0, `a header for ${groupId}: ${JSON.stringify(probe?.items.map((i) => [i.kind, i.groupId, i.key]))}`);
  const x = Math.round(item.x + Math.min(60, item.w / 3));
  const column = await run(`return hits(${JSON.stringify(windowId)}, [${x}], ${JSON.stringify(range(item.y, Math.min(item.h, 60)))});`);
  const ys = column.filter(([, , h]) => /GroupHeaderView/.test(h)).map(([, y]) => y);
  assert.ok(ys.length, `the header row of ${groupId}`);
  return [x, Math.round((ys[0] + ys.at(-1)) / 2)];
};

const menuRead = () => run(`return M.devContextMenu("read", null);`);
const opened = async (what, open, choice, delayMs = 0) => {
  const before = await run(`return menus();`);
  const arm = delayMs ? `M.devContextMenu("arm", ${JSON.stringify(choice)}, ${delayMs})` : `M.devContextMenu("arm", ${JSON.stringify(choice)})`;
  assert.equal(typeof (await run(`return ${arm};`)), "object");
  await open();
  const deadline = Date.now() + 4000 + delayMs;
  let model;
  while (Date.now() < deadline) {
    model = await menuRead();
    if (Array.isArray(model.items)) break;
    await new Promise((r) => setTimeout(r, 80));
  }
  assert.ok(Array.isArray(model?.items), `${what}: a menu was built (${JSON.stringify(model)})`);
  if (choice) assert.equal(model.accepted, true, `${what}: the menu took ${choice}`);
  const after = await run(`return menus();`);
  if (swiftOwned === null) swiftOwned = typeof before === "number";
  if (swiftOwned) assert.equal(after - before, 1, `${what}: Swift opened the menu (${before} -> ${after})`);
  console.log(`${what}: Swift-opened menus ${before} -> ${after}`);
  rep.log(`${what}: Swift-opened menus ${before} -> ${after}`);
  await run(`return settle(500);`);
  return model;
};
const onHeader = (groupId, choice, delayMs) => opened(`${choice ?? "read"} on ${groupId}`, async () => {
  const [x, y] = await header("w1", groupId);
  await run(`return rightClick("w1", ${x}, ${y});`);
}, choice, delayMs);
const group = (ids, name) => run(`const id = st().createGroup(${JSON.stringify(ids)}, { name: ${JSON.stringify(name)} }); return settle(1300).then(() => id);`);
const g = (id) => run(`return st().groups[${JSON.stringify(id)}] ?? null;`);

try {
  app = await launch(appPath, { data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_DRAW_WINDOWS: "1" }, ready: "return !!ac.store.getState().windows.w1" });
  rep.log(`instance: pid ${app.pid}, data ${join(scratch, "data")}`);
  const work = await group(["a", "b"], "Work");

  await rep.check("a right click on a header shows the JavaScript menu's rows in order", async () => {
    const model = await onHeader(work, null);
    const ids = model.items.map((r) => (r.separator ? "-" : r.id ?? r.title));
    assert.deepEqual(ids, ROWS);
    const colour = model.items.find((r) => r.title === "Color" && r.children);
    assert.deepEqual(colour.children.map((r) => (r.separator ? "-" : r.id)), ["color:none", "color:", "color:", "-", "color:grey", "color:blue", "color:red", "color:yellow", "color:green", "color:pink", "color:purple", "color:cyan", "color:orange"]);
    assert.equal(model.items.find((r) => r.id === "newTab").title, "New Tab in Group");
  });

  await rep.check("Color › Red, Collapse, Expand, Pin and Unpin change the group as JavaScript did", async () => {
    await onHeader(work, "color:red");
    assert.equal((await g(work)).color, "red");
    await onHeader(work, "color:");
    assert.equal((await g(work)).color ?? null, null);
    await onHeader(work, "collapse");
    assert.equal((await g(work)).collapsed, true);
    await onHeader(work, "collapse");
    assert.equal((await g(work)).collapsed, false);
    await onHeader(work, "pin");
    assert.equal((await g(work)).pinned, true);
    await onHeader(work, "pin");
    assert.equal((await g(work)).pinned, false);
  });

  await rep.check("Duplicate Group adds a copy; New Tab in Group opens and selects a member", async () => {
    const before = await run(`return Object.keys(st().groups).length;`);
    await onHeader(work, "duplicate");
    assert.equal(await run(`return Object.keys(st().groups).length;`), before + 1);
    const tabs = (await g(work)).tabIds.length;
    await onHeader(work, "newTab");
    const now = await g(work);
    assert.equal(now.tabIds.length, tabs + 1);
    const active = await run(`const w = st().windows.w1; return w.activeTabIds[w.profileId];`);
    assert.ok(now.tabIds.includes(active), `the new member is active (${active})`);
  });

  await rep.check("New Nested Group makes a child and selects its tab", async () => {
    const before = new Set(Object.keys(await run(`return st().groups;`)));
    await onHeader(work, "nest");
    const child = (await run(`return Object.values(st().groups).filter((x) => x.parentId === ${JSON.stringify(work)}).map((x) => x.id);`)).find((id) => !before.has(id));
    assert.ok(child, "a nested group");
    const active = await run(`const w = st().windows.w1; return w.activeTabIds[w.profileId];`);
    assert.ok((await g(child)).tabIds.includes(active), "its tab is active");
    await run(`return settle(400);`);
  });

  await rep.check("Ungroup keeps the tabs; Delete Group removes group and tabs", async () => {
    const loose = await group(["c"], "Loose");
    await onHeader(loose, "ungroup");
    assert.equal(await g(loose), null);
    assert.ok(await run(`return !!st().tabs.c;`));
    const doomed = await group(["d"], "Doomed");
    await onHeader(doomed, "delete");
    assert.equal(await g(doomed), null);
    assert.equal(await run(`return !!st().tabs.d;`), false);
  });

  await rep.check("Move to Bookmark Bar still runs the JavaScript path and removes the group", async () => {
    const marked = await group(["e"], "Marked");
    await onHeader(marked, "bookmarkBar");
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline && (await g(marked))) await new Promise((r) => setTimeout(r, 150));
    assert.equal(await g(marked), null);
  });

  await rep.check("while the menu is up the peek is held, and released after", async () => {
    const held = async () => {
      const native = await run(`return revealHeld("w1");`);
      const js = await run(`return ac.shell.menuShown();`);
      return { native, js };
    };
    if (!swiftOwned) return "the delay hook is Swift-only: skipped on this build";
    const idle = await held();
    const opening = onHeader(work, null, 1500);
    await new Promise((r) => setTimeout(r, 900));
    const during = await held();
    await opening;
    await run(`return settle(300);`);
    const after = await held();
    rep.log(`peek holds idle ${JSON.stringify(idle)} during ${JSON.stringify(during)} after ${JSON.stringify(after)}`);
    console.log(`peek holds idle ${JSON.stringify(idle)} during ${JSON.stringify(during)} after ${JSON.stringify(after)}`);
    if (during.native === null) {
      assert.equal(during.js, true, "JS layout: menuShown while the menu is up");
      assert.equal(after.js, false, "JS layout: released after");
    } else {
      assert.equal(during.native, true, "native layout: reveal hold while the menu is up");
      assert.equal(after.native, false, "native layout: released after");
    }
  });

  await rep.check("a right click on a strip chip opens the same menu, and Color › Blue applies", async () => {
    const strip = await group(["g", "h"], "Strip");
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1800);`);
    const items = await run(`return globalThis.expo.modules.SolaraTopStrip.items("w1").then(JSON.parse).then((s) => s.items);`);
    const chip = items.find((i) => i.kind === "group" && i.id === strip);
    assert.ok(chip?.width > 0, JSON.stringify(items.map((i) => [i.kind, i.id])));
    await opened("strip color:blue", () => run(`return rightClick("w1", ${Math.round(chip.windowX + Math.min(20, chip.width / 2))}, 20);`), "color:blue");
    assert.equal((await g(strip)).color, "blue");
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1200);`);
  });

  console.log(`Swift owned the group menu in this build: ${swiftOwned}`);
  rep.log(`Swift owned the group menu in this build: ${swiftOwned}`);
} finally {
  await app?.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);
