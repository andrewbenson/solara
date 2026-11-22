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
  console.error("usage: node sidebar-rename-test.mjs <Debug Solara.app under apps/browser/build-*> [--no-sheets] [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-rename-"));
const rep = reporter(join(scratch, "sidebar-rename-test.log"), { name: "sidebar-rename-test" });
const ids = ["t0", "t1", "t2"];
const tabs = ids.map((id) => ({ id, url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }));

let app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  session: session(sidebarSession({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t0" }, frame: [60, 60, 1200, 800] }], tabs })),
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
const renaming = () => run(`return ac.sidebarRows.useSidebarUi.getState().renaming?.id ?? null`);
const tabCount = () => run(`return ac.store.getState().windows.w1.tabIds.length`);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await test()) return;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(40);
  }
};
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    if (!app.alive) throw new Error(`${what}: the owned app exited`);
    if (end - Date.now() < 1000) break;
    last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    nativePollDeadline = end;
    try {
      if (!last.error && last.consistent && Date.now() < end && await accept(last) && Date.now() < end) return last;
    } finally {
      nativePollDeadline = 0;
    }
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const assertNativeRename = async (id, title, count) => {
  const snapshot = await untilSnapshot(`native rename of ${id}`, (state) => state.tabs.some((tab) => tab.id === id && tab.customTitle === title) &&
    state.windows.some((window) => window.id === "w1" && window.tabIds.length === count));
  assert.equal(snapshot.tabs.find((tab) => tab.id === id)?.customTitle, title);
  assert.equal(snapshot.windows.find((window) => window.id === "w1")?.tabIds.length, count);
};
const devWindow = (action) => run(`const C = globalThis.expo.modules.SolaraCEF; return C.chromeWindows().then((ws) => C.devWindow((ws.find((w) => w.hasRoot && w.frame.includes("{1200, ")) ?? ws.find((w) => w.hasRoot)).window, ${JSON.stringify(action)}));`);
const nativeGroup = (id) => run(`const m = globalThis.expo.modules.SolaraStoreAdapter; if (!m || typeof m.snapshot !== "function" || !(m.status().active && m.status().frozen === false)) return null; const g = JSON.parse(m.snapshot()).data.groups?.[${JSON.stringify(id)}]; return g ? { name: g.name, collapsed: !!g.collapsed } : null;`, 1000);
const doubleClick = async (id) => {
  const row = await run(`return ac.sidebarRows.measureRow("w1", ${JSON.stringify(id)})`);
  assert.ok(row, `row ${id} measured`);
  const x = Math.round(row.x + Math.min(row.width / 2, 70)), y = Math.round(row.y + row.height / 2);
  await run(`return ac.shell.devSetPointer("w1", { x: ${x}, y: ${y} })`);
  for (const n of [1, 2]) {
    await devWindow(`mouse:down:${x},${y},${n}`);
    await sleep(40);
    await devWindow(`mouse:up:${x},${y},${n}`);
    await sleep(60);
  }
};
const startRename = async (id) => {
  await doubleClick(id);
  await until(`the field on ${id}`, async () => (await renaming()) === id);
  await sleep(200);
};

try {
  await sleep(2500);
  await assertSidebarPosition(app);
  const last = await run(`return ac.sidebarRows.measureRow("w1", "t2")`);
  const blank = { x: last.x + 60, y: Math.round(last.y + last.height + 160) };

  await rep.check("a click on the empty sidebar keeps the typed name, closes the field and opens no tab", async () => {
    const before = await tabCount();
    await startRename("t1");
    await run(`return ac.shell.devTypeKeys("w1", "Renamed", 10)`);
    await sleep(200);
    const click = await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    rep.say(`clicked ${JSON.stringify(click)}`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t1.customTitle`), "Renamed");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t1", "Renamed", before);
  });

  await rep.check("a second click there right after opens no tab either", async () => {
    const before = await tabCount();
    await startRename("t2");
    await run(`return ac.shell.devTypeKeys("w1", "Second", 10)`);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t2.customTitle`), "Second");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t2", "Second", before);
  });

  await rep.check("a click on another row keeps the typed name and selects that row", async () => {
    const before = await tabCount();
    const row = await run(`return ac.sidebarRows.measureRow("w1", "t2")`);
    await startRename("t1");
    await run(`return ac.shell.devTypeKeys("w1", "Away", 10)`);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${Math.round(row.x + row.width / 2)}, y: ${Math.round(row.y + row.height / 2)} })`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t1.customTitle`), "Away");
    await until("t2 to be the active tab", async () => await run(`return Object.values(ac.store.getState().windows.w1.activeTabIds).includes("t2")`));
    assert.equal(await tabCount(), before, "no new tab");
    await assertNativeRename("t1", "Away", before);
  });

  await rep.check("Esc still cancels", async () => {
    await startRename("t0");
    await run(`return ac.shell.devTypeKeys("w1", "Nope", 10)`);
    await sleep(200);
    await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t0.customTitle ?? null`), null);
    await assertNativeRename("t0", null, await tabCount());
  });
  await rep.check("Return commits the typed name, trimmed", async () => {
    const before = await tabCount();
    await startRename("t2");
    await run(`return ac.shell.devTypeKeys("w1", "  Ret  ", 10)`);
    await sleep(150);
    await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t2.customTitle`), "Ret");
    await assertNativeRename("t2", "Ret", before);
  });
} finally {
  await app.quit();
}

{
  const fixture3 = sidebarSession({
    profiles: ["Personal"],
    windows: [
      { id: "w1", tabIds: ["a1", "a2", "a3"], activeTabIds: { default: "a1" }, frame: [60, 60, 1200, 800] },
      { id: "w2", tabIds: ["b1", "b2"], activeTabIds: { default: "b1" }, frame: [300, 120, 1000, 700] },
    ],
    tabs: [...["a1", "a2", "a3"].map((id) => ({ id, windowId: "w1", url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` })), ...["b1", "b2"].map((id) => ({ id, windowId: "w2", url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }))],
  });
  fixture3.groups = { g: { id: "g", windowId: "w1", profileId: "default", name: "Grp", icon: null, color: null, collapsed: false, pinned: false, tabIds: ["a3"] } };
  app = await launch(resolve(appArg), { data: join(scratch, "data3"), session: session(fixture3), ready: "return !!ac.store && !!ac.store.getState().windows.w2" });
  try {
    await sleep(2500);
    const owned = await run(`return !!globalThis.expo.modules.SolaraHosted?.beginRename`);
    const windowNumber = (width) => run(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot && w.frame.includes("{${width}, "))?.window ?? null)`);
    const numbers = { w1: await windowNumber(1200), w2: await windowNumber(1000) };
    rep.log(`window numbers ${JSON.stringify(numbers)}`);
    const doubleClickIn = async (windowId, id) => {
      const row = await run(`return ac.sidebarRows.measureRow(${JSON.stringify(windowId)}, ${JSON.stringify(id)})`);
      assert.ok(row, `row ${id} in ${windowId}`);
      const x = Math.round(row.x + Math.min(row.width / 2, 70)), y = Math.round(row.y + row.height / 2);
      await run(`return ac.shell.devSetPointer(${JSON.stringify(windowId)}, { x: ${x}, y: ${y} })`);
      for (const n of [1, 2]) {
        await run(`return globalThis.expo.modules.SolaraCEF.devWindow(${numbers[windowId]}, "mouse:down:${x},${y},${n}")`);
        await sleep(40);
        await run(`return globalThis.expo.modules.SolaraCEF.devWindow(${numbers[windowId]}, "mouse:up:${x},${y},${n}")`);
        await sleep(60);
      }
    };
    const mirror = () => run(`const r = ac.sidebarRows.useSidebarUi.getState().renaming; return r ? r.windowId + ":" + r.id : null`);

    await rep.check("a double-click on a group's header starts its rename, and Escape ends it", async () => {
      await doubleClickIn("w1", "g");
      await until("the group's field", async () => (await mirror()) === "w1:g");
      await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
      await until("the field to close", async () => (await mirror()) === null);
      assert.equal(await run(`return ac.store.getState().groups.g.name`), "Grp");
    });

    await rep.check("quick begin and end several times leaves no field, and the next begin opens one", async () => {
      for (let i = 0; i < 4; i++) {
        await doubleClickIn("w1", "a2");
        await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
      }
      await sleep(800);
      assert.equal(await mirror(), null);
      await doubleClickIn("w1", "a2");
      await until("a2's field", async () => (await mirror()) === "w1:a2");
      await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
      await until("the field to close", async () => (await mirror()) === null);
    });

    if (owned) await rep.check("renames in two windows at once: ending one keeps the other's", async () => {
      await doubleClickIn("w1", "a1");
      await until("a1's field", async () => (await mirror()) === "w1:a1");
      await doubleClickIn("w2", "b1");
      await until("b1's field", async () => (await mirror()) === "w2:b1");
      await run(`return ac.shell.devTypeKeys("w2", "\\u001b", 10)`);
      await until("w1's rename mirrored again", async () => (await mirror()) === "w1:a1");
      await run(`return ac.shell.devTypeKeys("w1", "Both", 10)`);
      await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
      await until("the field to close", async () => (await mirror()) === null);
      assert.equal(await run(`return ac.store.getState().tabs.a1.customTitle`), "Both");
      assert.equal(await run(`return ac.store.getState().tabs.b1.customTitle ?? null`), null);
    });
  } finally {
    await app.quit();
  }
}

const sheets = !args.includes("--no-sheets");
if (sheets) {
  const group = (id, name, tabIds, extra = {}) => ({ id, name, tabIds, collapsed: true, ...extra });
  const fixture2 = sidebarSession({
    profiles: ["Personal"],
    windows: [
      { id: "w1", tabIds: ["tile", "a", "b", "c"], activeTabIds: { default: "a" }, frame: [60, 60, 1200, 800] },
      { id: "w9", tabIds: ["z"], activeTabIds: { default: "z" }, frame: [400, 200, 900, 640] },
    ],
    tabs: [{ id: "tile", windowId: "w1", url: "data:text/html,<title>Tile</title>", title: "Tile", pinned: true }, ...["a", "b", "c"].map((id) => ({ id, windowId: "w1", url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` })), { id: "z", windowId: "w9", url: "data:text/html,<title>Z</title>", title: "Z" }],
  });
  fixture2.groups = { outer: { id: "outer", windowId: "w1", profileId: "default", name: "Outer", icon: null, color: null, collapsed: true, pinned: false, tabIds: ["b"] }, inner: { id: "inner", windowId: "w1", profileId: "default", name: "Inner", icon: null, color: null, collapsed: true, pinned: false, parentId: "outer", tabIds: ["c"] } };
  app = await launch(resolve(appArg), { data: join(scratch, "data2"), session: session(fixture2), ready: "return !!ac.store && !!ac.store.getState().windows.w9" });
  try {
    await sleep(2500);
    assert.equal(await devWindow("alertSheets:1"), "1", "real sheets in this test instance");
    const begin = (kind, id) => run(`return globalThis.expo.modules.SolaraHosted.beginRename("w1", ${JSON.stringify(kind)}, ${JSON.stringify(id)})`);
    const sheet = async () => JSON.parse(await devWindow("winfo"));
    const untilSheet = async (what, want) => {
      const end = Date.now() + 6000;
      for (;;) {
        const info = await sheet();
        if (want(info)) return info;
        if (Date.now() > end) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(info.sheetText ?? null)}`);
        await sleep(100);
      }
    };
    const sheetKey = (info, chars, code) => run(`return globalThis.expo.modules.SolaraCEF.devWindow(${info.sheetWindow}, "keys:0:${chars}:${code}")`);
    const groups = () => run(`const g = ac.store.getState().groups; return { outer: g.outer?.collapsed ?? null, inner: g.inner?.collapsed ?? null, innerName: g.inner?.name ?? null }`);

    await rep.check("renaming a tab inside collapsed nested groups expands them and opens its field", async () => {
      assert.deepEqual(await groups(), { outer: true, inner: true, innerName: "Inner" });
      assert.equal(await begin("tab", "c"), true);
      await until("c's field", async () => (await renaming()) === "c");
      assert.deepEqual(await groups(), { outer: false, inner: false, innerName: "Inner" });
      await until("native groups expanded", async () => { const o = await nativeGroup("outer"), i = await nativeGroup("inner"); return o && i && !o.collapsed && !i.collapsed; });
      await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
      await until("the field to close", async () => (await renaming()) === null);
    });

    await rep.check("a group's inline rename trims the name", async () => {
      assert.equal(await begin("group", "inner"), true);
      await until("the group's field", async () => (await renaming()) === "inner");
      await run(`return ac.shell.devTypeKeys("w1", "  Work  ", 10)`);
      await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
      await until("the field to close", async () => (await renaming()) === null);
      assert.equal((await groups()).innerName, "Work");
      await until("the native group name", async () => (await nativeGroup("inner"))?.name === "Work");
    });

    await rep.check("a pinned tile renames in a sheet: Escape keeps it, Update applies the field", async () => {
      assert.equal(await begin("tab", "tile"), true);
      let info = await untilSheet("the Rename Tab sheet", (i) => i.sheet);
      rep.log(`tile sheet ${JSON.stringify(info.sheetText)}`);
      for (const t of ["Rename Tab", "Update", "Cancel"]) assert.ok(info.sheetText.includes(t), `${t}: ${JSON.stringify(info.sheetText)}`);
      assert.equal(await renaming(), null, "no inline field for a tile");
      await sheetKey(info, "\\u001b", 53);
      await untilSheet("the sheet gone", (i) => !i.sheet);
      assert.equal(await run(`return ac.store.getState().tabs.tile.customTitle ?? null`), null);
      assert.equal(await begin("tab", "tile"), true);
      info = await untilSheet("the Rename Tab sheet again", (i) => i.sheet);
      assert.equal(await begin("tab", "tile"), true);
      await sleep(400);
      assert.equal((await sheet()).sheetWindow, info.sheetWindow, "one sheet at a time");
      await sheetKey(info, "\\r", 36);
      await untilSheet("the sheet gone", (i) => !i.sheet);
      await until("the tile renamed", async () => (await run(`return ac.store.getState().tabs.tile.customTitle ?? null`)) === "Tile");
    });

    await rep.check("a rename while a close sheet is up opens nothing", async () => {
      await run(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: true }); return true`);
      await sleep(300);
      await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeWindow", null)`);
      const info = await untilSheet("the close sheet", (i) => i.sheet);
      rep.log(`close sheet ${JSON.stringify(info.sheetText)}`);
      assert.ok(info.sheetText.some((t) => /^Close \d+ tabs?\?$/.test(t)), JSON.stringify(info.sheetText));
      assert.equal(await begin("tab", "tile"), true);
      await sleep(500);
      const during = await sheet();
      assert.equal(during.sheetWindow, info.sheetWindow, "still only the close sheet");
      assert.ok(!during.sheetText.includes("Rename Tab"), JSON.stringify(during.sheetText));
      await sheetKey(info, "\\u001b", 53);
      await untilSheet("the sheet gone", (i) => !i.sheet);
      await sleep(800);
      assert.equal((await sheet()).sheet, "", "no rename sheet afterwards");
      assert.ok(await run(`return !!ac.store.getState().windows.w1`), "Cancel kept the window");
      await run(`ac.store.getState().updateSettings({ warnBeforeClosingWindow: false }); return true`);
    });

    await rep.check("the palette's Rename Tab opens the inline field and commits", async () => {
      await run(`ac.store.getState().activate("b"); return true`);
      await sleep(400);
      await run(`ac.runCommand({ command: "renameTab", arg: null, windowId: "w1" }); return true`);
      await until("b's field from the palette", async () => (await renaming()) === "b", 4000);
      await run(`return ac.shell.devTypeKeys("w1", "Paletted", 10)`);
      await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
      await until("the field to close", async () => (await renaming()) === null);
      assert.ok((await run(`return ac.store.getState().tabs.b.customTitle ?? ""`)).endsWith("Paletted"));
    });

    await rep.check("with top tabs, a group renames in a Rename Group sheet", async () => {
      await run(`ac.store.getState().toggleTabLayout("w1"); return true`);
      await sleep(1500);
      assert.equal(await begin("group", "outer"), true);
      const info = await untilSheet("the Rename Group sheet", (i) => i.sheet);
      rep.log(`group sheet ${JSON.stringify(info.sheetText)}`);
      for (const t of ["Rename Group", "Update", "Cancel"]) assert.ok(info.sheetText.includes(t), `${t}: ${JSON.stringify(info.sheetText)}`);
      await sheetKey(info, "\\u001b", 53);
      await untilSheet("the sheet gone", (i) => !i.sheet);
      assert.equal(await run(`return ac.store.getState().groups.outer.name`), "Outer");
      await run(`ac.store.getState().toggleTabLayout("w1"); return true`);
      await sleep(1200);
    });

    await rep.check("the Rename menu command goes through the same path", async () => {
      await run(`ac.store.getState().activate("a"); return true`);
      await until("a active", async () => await run(`return Object.values(ac.store.getState().windows.w1.activeTabIds).includes("a")`));
      await sleep(300);
      await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "renameTab", null)`);
      await until("the active tab's field", async () => (await renaming()) === "a", 4000);
      await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
      await until("the field to close", async () => (await renaming()) === null);
    });
  } finally {
    await app.quit();
  }
}
const passed = rep.summary();
if (!keep && passed) rmSync(scratch, { recursive: true, force: true });
else console.log(`data: ${scratch}`);
process.exit(passed ? 0 : 1);
