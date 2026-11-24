#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/fallback-refused-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug build");
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const rep = reporter(join(output, "fallback-refused-test.log"), { name: "fallback-refused-test" });
const evidence = [];
const q = JSON.stringify;
const CALENDAR = "https://calendar.google.com/calendar/u/0/r";
const fixture = (layout, calendar) => session({
  windows: [{ id: "w1", frame: [80, 80, 1200, 800], activeTabIds: { default: "a" } }],
  tabs: [...["a", "b", "c"].map((id) => ({
    id, title: id.toUpperCase(), url: `data:text/html,<title>${id.toUpperCase()}</title>${id}`,
    ...(id === "c" ? {} : { pinned: true, pinnedUrl: `data:text/html,<title>${id.toUpperCase()}</title>${id}`, tileFolder: { id: "tf", name: "Tiles" } }),
  })), ...(calendar ? [{ id: "cal", title: "Calendar", url: CALENDAR, pinned: true, pinnedUrl: CALENDAR, sleeping: true }] : [])],
  groups: [{ id: "g", windowId: "w1", profileId: "default", name: "Group", collapsed: false, pinned: false, tabIds: ["c"], createdAt: 1 }],
  settings: { tabLayout: layout, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabGroup: false },
});

async function exercise(layout, chosen) {
  const app = await launch(appPath, {
    data: join(output, chosen.replaceAll(" ", "-")), fresh: true, onboarded: true, probe: true, session: fixture(layout, chosen === "pinned calendar tab menu"),
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_NATIVE_WINDOW_LAYOUT: layout === "top" ? "1" : "0" },
    ready: "return !!ac.sidebarRows && !!ac.pages.tileFolders && !!expo.modules.SolaraStoreAdapter.freeze && !!expo.modules.SolaraShell.devContextMenu;",
  });
  const run = (body) => app.eval(body, { timeout: 3000 });
  const until = async (label, read, ms = 5000) => {
    const deadline = Date.now() + ms;
    let last;
    while (Date.now() + 300 < deadline) {
      assert.ok(app.alive, `${label}: owned instance exited`);
      last = await read();
      if (last) return last;
      await sleep(80);
    }
    throw new Error(`${label}: deadline exceeded (${q(last)})`);
  };
  try {
    await sleep(1800);
    const win = await run('return expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);');
    const dev = (action) => run(`return expo.modules.SolaraCEF.devWindow(${win}, ${q(action)});`);
    await dev("fakeActiveClicks");
    const point = async (x, y) => {
      await run(`return ac.shell.devSetPointer("w1", {x:${x},y:${y}});`);
      await sleep(120);
    };
    const press = async (x, y) => {
      await point(x, y);
      await dev(`mouse:down:${x},${y},1`);
      await sleep(50);
      await dev(`mouse:up:${x},${y},1`);
    };
    const row = (id) => until(`sidebar row ${id}`, () => run(`return ac.sidebarRows.measureRow("w1", ${q(id)});`));
    const state = () => run(`const keys = ["tabs","windows","groups","splits","windowOrder","selection","selectionAnchors","closedTabs","closedGroups","closedWindows","parkedPins"];
      const pick = (s) => Object.fromEntries(keys.filter((k) => s[k] !== undefined).map((k) => [k,s[k]]));
      return { native: pick(JSON.parse(expo.modules.SolaraStoreAdapter.snapshot()).data), js: pick(ac.store.getState()) };`);
    const frozen = () => run('return expo.modules.SolaraStoreAdapter.status().frozen === true;');
    const leg = async (name, action, perform) => {
      if (name !== chosen) return;
      return rep.check(name, async () => {
        await run('return expo.modules.SolaraShell.devContextMenu("arm", null);');
        const before = await state();
        const offset = app.output().length;
        await perform();
        await sleep(400);
        const after = await state();
        const log = app.output().slice(offset);
        evidence.push({ name, before, after, log });
        writeFileSync(join(output, "evidence.json"), q(evidence));
        assert.deepEqual(after, before, `${name} changes neither the Swift store nor its JS replica`);
        if (action) assert.ok(log.includes(`${action} refused:`), `${name} logs its refusal: ${log}`);
        const open = await run('return ac.pages.tileFolders.panel.getState().open;');
        assert.equal(open, null, "no JS or mirrored folder panel");
        const snapshot = await app.snapshot({ windowId: "w1", topStrip: true }, { timeout: 3000 });
        assert.ok(snapshot.consistent, "native snapshot is consistent");
        assert.ok(snapshot.windows.every((w) => !w.folderPanel?.visible && !w.topStrip?.panelOpen), "no native panel");
        const menu = await run('return expo.modules.SolaraShell.devContextMenu("read", null);');
        assert.ok(!Array.isArray(menu.items), `no JS menu appeared: ${q(menu)}`);
        const info = JSON.parse(await dev("winfo"));
        assert.ok(!info.sheet, "no sheet appeared");
        evidence.at(-1).snapshot = snapshot;
        writeFileSync(join(output, "evidence.json"), q(evidence));
      });
    };
    if (layout === "top") {
      const target = await until("native strip tab c", async () => {
        const items = JSON.parse(await run('return expo.modules.SolaraTopStrip.items("w1");'));
        return items?.items.find((item) => item.kind === "tab" && item.id === "c" && item.width > 0);
      });
      assert.equal(await run('return expo.modules.SolaraStoreAdapter.freeze();'), true);
      await until("strip store frozen", frozen);
      await leg("strip click after freeze", "[strip] click", () => press(target.windowX + Math.min(target.width / 2, 55), target.windowY + target.height / 2));
      return;
    }
    if (chosen === "pinned calendar tab menu") {
      await rep.check(chosen, async () => {
        const tile = await row("cal");
        const x = Math.round(tile.x + tile.width / 2), y = Math.round(tile.y + tile.height / 2);
        await run('return expo.modules.SolaraShell.devContextMenu("arm", null);');
        const offset = app.output().length;
        await point(x, y);
        await dev(`click:${x},${y},right`);
        const menu = await until("a menu for the pinned calendar tab", async () => {
          const read = await run('return expo.modules.SolaraShell.devContextMenu("read", null);');
          return Array.isArray(read?.items) && read.items.length ? read : null;
        }, 4000);
        evidence.push({ name: chosen, menu, log: app.output().slice(offset) });
        writeFileSync(join(output, "evidence.json"), q(evidence));
        const titles = JSON.stringify(menu.items);
        assert.ok(titles.includes("Calendar"), `the menu has the Calendar submenu: ${titles}`);
        assert.ok(!app.output().slice(offset).includes("tabMenu refused"), "no refusal for an owned pinned calendar tab");
      });
      return;
    }
    const tab = await row("c");
    const folder = await until("folder tile", () => run('return ac.pages.tileFolders.measure("w1", "tf");'));
    const probe = JSON.parse(await run('return expo.modules.SolaraSidebarDrag.startProbe("w1");'));
    const group = probe.items.find((item) => item.kind === "group" && (item.groupId === "g" || String(item.key).includes("g")));
    assert.ok(group?.w > 0, "group is laid out");
    const groupX = Math.round(group.x + Math.min(60, group.w / 3));
    let groupY;
    for (let y = Math.round(group.y); y < group.y + Math.min(group.h, 60); y += 2) {
      if (/GroupHeaderView/.test(await dev(`hit:${groupX},${y}`))) { groupY = y + 2; break; }
    }
    assert.ok(Number.isFinite(groupY), "native group header found");
    const tabX = Math.round(tab.x + Math.min(tab.width / 2, 60));
    const tabY = Math.round(tab.y + tab.height / 2);
    await point(tabX, tabY);
    let closeX;
    for (let x = Math.round(tab.x + tab.width - 1); x > tab.x + tab.width / 2; x -= 2) {
      if (/SidebarIconButton/.test(await dev(`hit:${x},${tabY}`))) { closeX = x; break; }
    }
    assert.ok(Number.isFinite(closeX), "native close button found");
    const freeze = async () => {
      assert.equal(await run('return expo.modules.SolaraStoreAdapter.freeze();'), true);
      await until("sidebar store frozen", frozen);
    };
    const renaming = () => run('return ac.sidebarRows.useSidebarUi.getState().renaming?.id ?? null;');
    if (chosen === "rename open at freeze") {
      for (const n of [1, 2]) {
        await point(tabX, tabY);
        await dev(`mouse:down:${tabX},${tabY},${n}`);
        await sleep(40);
        await dev(`mouse:up:${tabX},${tabY},${n}`);
        await sleep(60);
      }
      await until("the native rename field on c", async () => (await renaming()) === "c");
      await sleep(200);
    } else await freeze();
    await leg("sidebar click after freeze", "[sidebar] click", () => press(tabX, tabY));
    await leg("sidebar close after freeze", "[sidebar] close", () => press(closeX, tabY));
    await leg("group toggle after freeze", "[sidebar] toggleGroup", () => press(groupX, groupY));
    await leg("folder click after freeze", "[sidebar] folder", () => press(folder.x + folder.width / 2, folder.y + folder.height / 2));
    await leg("rename open at freeze", null, async () => {
      await freeze();
      await until("the freeze closes the rename field", async () => (await renaming()) === null);
      await run('return ac.shell.devTypeKeys("w1", "Refused title", 10);');
      await run('return ac.shell.devTypeKeys("w1", "\\r", 10);');
    });
    await leg("external drop after freeze", "[sidebar] drop", async () => {
      await run(`return ac.shell.devFileDrag.drag("w1", "move", ${tabX}, ${tabY}, {urls:["https://example.com/refused-drop"]});`);
      await sleep(200);
      await run(`return ac.shell.devFileDrag.drag("w1", "drop", ${tabX}, ${tabY});`);
    });
  } finally {
    await app.quit();
  }
}

for (const [layout, name] of [
  ["sidebar", "sidebar click after freeze"],
  ["top", "strip click after freeze"],
  ["sidebar", "sidebar close after freeze"],
  ["sidebar", "group toggle after freeze"],
  ["sidebar", "folder click after freeze"],
  ["sidebar", "rename open at freeze"],
  ["sidebar", "pinned calendar tab menu"],
  ["sidebar", "external drop after freeze"],
]) {
  await rep.check(`${name} fixture`, () => exercise(layout, name));
}
process.exit(rep.summary() ? 0 : 1);
