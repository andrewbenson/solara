#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: SOLARA_NATIVE_BOOKMARKS_BAR=1 METRO_PORT=8081 node apps/browser/scripts/bookmarks-bar-test.mjs <Debug Solara.app> [--keep-data]");
  process.exit(2);
}
const native = process.env.SOLARA_NATIVE_BOOKMARKS_BAR === "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-bookmarks-bar-"));
const rep = reporter(join(scratch, "bookmarks-bar-test.log"), { name: "bookmarks-bar-test" });
const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end(`<title>Bookmark fixture</title><p>${request.url.replace(/[<>&]/g, "")}</p>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1200, 800], sidebarOpen: true, tabLayout: "sidebar", activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/initial`, title: "Initial" }],
  settings: { tabLayout: "sidebar", bookmarksBar: "always", hideBookmarksBarImport: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});
const helpers = `
const S = () => ac.store.getState();
const H = globalThis.expo.modules.SolaraHosted;
const active = () => S().windows.w1.activeTabIds.default;
const barIds = () => S().bookmarks.nodes[bmbar.bar].children;
const rnBar = () => acPerf.findFibers("BookmarksBar", 200).some((fiber) => !fiber.memoizedProps?.placeholder);
const inBar = (fiber) => {
  for (let parent = fiber; parent; parent = parent.return) if (acPerf.nameOf(parent.type) === "Bar" && parent.memoizedProps?.windowId === "w1") return true;
  return false;
};
const itemId = (fiber) => {
  for (let parent = fiber; parent; parent = parent.return) if (acPerf.nameOf(parent.type) === "BarItem") return parent.memoizedProps?.id;
  return null;
};
const rnButtons = () => acPerf.findFibers("BarButton", 2000).filter(inBar);
const rnText = (text) => acPerf.findFibers("Text", 2000).some((fiber) => inBar(fiber) && fiber.memoizedProps?.children === text);
const rnInput = (action, id, modifiers) => {
  const buttons = rnButtons();
  if (action === "contextMenu") {
    const area = acPerf.findFibers("ContextMenuArea", 2000).find((fiber) => inBar(fiber) && itemId(fiber) === id);
    if (!area?.memoizedProps?.onContextMenu) return false;
    area.memoizedProps.onContextMenu();
    return true;
  }
  const button = action === "press" ? buttons.find((fiber) => itemId(fiber) === id)
    : action === "overflowPress" ? buttons.find((fiber) => fiber.memoizedProps.tooltip === "More bookmarks")
    : action === "otherPress" ? buttons.find((fiber) => fiber.memoizedProps.title === "Other Bookmarks") : null;
  if (!button?.memoizedProps?.onPress) return false;
  button.memoizedProps.onPress({ metaKey: !!(modifiers & (1 << 20)), shiftKey: !!(modifiers & (1 << 17)), altKey: !!(modifiers & (1 << 19)) });
  return true;
};
`;
let app;
const run = (body) => app.eval(`${helpers}\n${body}`, { timeout: 3000 });
const until = async (what, body, accept = (value) => !!value, timeout = 8000) => {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`${what}: app exited`);
    last = await run(body);
    if (accept(last)) return last;
    await sleep(80);
  }
  throw new Error(`${what}: timed out (${JSON.stringify(last)})`);
};
const layout = () => run('return H.devBookmarksBarLayout("w1").then(JSON.parse);');
const input = async (action, id = null, modifiers = 0, x = null) => {
  const body = native ? `return H.devBookmarksBarInput("w1", ${JSON.stringify(action)}, ${JSON.stringify(id)}, ${modifiers}, ${JSON.stringify(x)});`
    : `return rnInput(${JSON.stringify(action)}, ${JSON.stringify(id)}, ${modifiers});`;
  assert.equal(await run(body), true, `${action} accepted`);
};
const visibleItem = async (id) => {
  const state = await until(`visible bookmark ${id}`, 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.visible?.some((item) => item.id === id));
  return state.visible.find((item) => item.id === id);
};
const skip = (name) => rep.record(name, { skip: "native input/layout hook disabled; React Native store checks run below" });
let ids;
try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, onboarded: true, session: fixture, probe: true,
    keepData: args.includes("--keep-data"), metroPort: Number(process.env.METRO_PORT ?? 8081),
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_BOOKMARKS_BAR: native ? "1" : "0" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf && !!globalThis.expo?.modules?.SolaraHosted;",
  });
  await until("Chrome bookmark roots ready", "return S().bookmarksReady.default === true;", undefined, 20000);
  ids = await run(`
    const s = S();
    s.updateSettings({ bookmarksBar: "always", hideBookmarksBarImport: false });
    const roots = S().bookmarks.roots.default;
    s.removeBookmarks([...S().bookmarks.nodes[roots.bar].children, ...S().bookmarks.nodes[roots.other].children]);
    const first = s.addBookmark({ profileId: "default", title: "A", url: ${JSON.stringify(`${base}/first`)} });
    const second = s.addBookmark({ profileId: "default", title: "B", url: ${JSON.stringify(`${base}/second`)} });
    const folder = s.addBookmarkFolder({ profileId: "default", title: "Folder" });
    const nested = s.addBookmark({ profileId: "default", parentId: folder, title: "Nested", url: ${JSON.stringify(`${base}/nested`)} });
    const nestedFolder = s.addBookmarkFolder({ profileId: "default", parentId: folder, title: "Nested folder" });
    const deepLink = s.addBookmark({ profileId: "default", parentId: nestedFolder, title: "Deep link", url: ${JSON.stringify(`${base}/deep`)} });
    const overflow = Array.from({ length: 30 }, (_, index) => s.addBookmark({ profileId: "default", title: "Overflow bookmark " + index, url: ${JSON.stringify(`${base}/overflow/`)} + index }));
    const other = s.addBookmark({ profileId: "default", parentId: roots.other, title: "Other entry", url: ${JSON.stringify(`${base}/other`)} });
    globalThis.bmbar = { ...roots, first, second, folder, nested, nestedFolder, deepLink, overflow, other };
    const shell = globalThis.expo.modules.SolaraShell;
    bmbar.showMenu = shell.showMenu;
    bmbar.menus = [];
    shell.showMenu = (items) => { bmbar.menus.push(items); return Promise.resolve(null); };
    return { ...roots, first, second, folder, nested, nestedFolder, deepLink, overflow, other };
  `);
  await rep.check("launch-switch", async () => {
    const kinds = await run("return H.kinds();");
    assert.equal(kinds.includes("bookmarksBar"), native);
    if (native) assert.equal(await run('return typeof H.devBookmarksBarInput === "function" && typeof H.devBookmarksBarLayout === "function";'), true, "Debug native hooks available");
    else await until("React Native bar mounted", "return rnBar();");
    return native ? "native" : "React Native";
  });
  if (native) {
    await rep.check("native-layout", async () => {
      const state = await until("overflow and Other layout", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.overflowShown && value.otherShown);
      const visible = state.visible.map((item) => item.id);
      assert.ok(visible.includes(ids.first) && visible.includes(ids.second) && visible.includes(ids.folder));
      assert.deepEqual([...visible, ...state.overflowIds], [ids.first, ids.second, ids.folder, ...ids.overflow]);
      assert.ok(state.overflowIds.length > 0);
      assert.equal(state.importShown, false);
      assert.equal(state.hintShown, false);
      for (const item of state.visible) assert.ok(item.frame.width > 0 && item.frame.height === 24);
      return state;
    });
  } else skip("native-layout");
  const destination = `${base}/first`;
  const reset = async () => {
    await run(`for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("a"); S().navigate("a", ${JSON.stringify(`${base}/initial`)}); return true;`);
    if (native) await visibleItem(ids.first);
    else await until("RN bookmark button", `return rnButtons().some((fiber) => itemId(fiber) === ${JSON.stringify(ids.first)});`);
  };
  await rep.check("plain-press-current-tab", async () => {
    await reset();
    const count = await run("return S().windows.w1.tabIds.length;");
    await input("press", ids.first);
    await until("current tab navigation", `return active() === "a" && S().tabs.a.url === ${JSON.stringify(destination)};`);
    assert.equal(await run("return S().windows.w1.tabIds.length;"), count);
  });
  for (const [name, flags, foreground] of [["command-background-tab", 1 << 20, false], ["shift-command-foreground-tab", (1 << 20) | (1 << 17), true]]) {
    await rep.check(name, async () => {
      await reset();
      const before = await run("return [...S().windows.w1.tabIds];");
      await input("press", ids.first, flags);
      const after = await until(name, "return { ids: S().windows.w1.tabIds, active: active(), tabs: S().tabs };", (value) => value.ids.length === before.length + 1);
      const created = after.ids.find((id) => !before.includes(id));
      assert.equal(after.tabs[created].url, destination);
      assert.equal(after.active, foreground ? created : "a");
    });
  }
  await rep.check("shift-new-window", async () => {
    await reset();
    const before = await run("return Object.keys(S().windows);");
    await input("press", ids.first, 1 << 17);
    const created = await until("new bookmark window", "return Object.values(S().windows).map((window) => ({ id: window.id, url: S().tabs[window.activeTabIds[window.profileId]]?.url }));", (value) => value.some((window) => !before.includes(window.id) && window.url === destination));
    const window = created.find((window) => !before.includes(window.id));
    assert.equal(window.url, destination);
    await run(`S().closeWindow(${JSON.stringify(window.id)}); return true;`);
    await until("bookmark window closes", `return !S().windows[${JSON.stringify(window.id)}];`);
  });
  await rep.check("option-split", async () => {
    await reset();
    await input("press", ids.first, 1 << 19);
    const splits = await until("bookmark split", "return Object.values(S().splits).map((split) => split.tabIds.map((id) => ({ id, url: S().tabs[id]?.url })));", (value) => value.some((tabs) => tabs.some((tab) => tab.id === "a") && tabs.some((tab) => tab.url === destination && tab.id !== "a")));
    assert.ok(splits.length > 0);
    await reset();
  });
  for (const [name, action, id, expected] of [
    ["folder-menu", "press", ids.folder, `open:${ids.nested}`],
    ["overflow-menu", "overflowPress", null, null],
    ["other-menu", "otherPress", null, `open:${ids.other}`],
    ["context-menu", "contextMenu", ids.first, "edit"],
  ]) {
    await rep.check(name, async () => {
      const before = await run("return bmbar.menus.length;");
      const overflow = native && action === "overflowPress" ? (await layout()).overflowIds : null;
      await input(action, id);
      const menus = await until(name, "return bmbar.menus;", (value) => value.length > before);
      const menu = menus.at(-1);
      if (expected) assert.ok(menu.some((item) => item.id === expected), `menu contains ${expected}`);
      if (name === "folder-menu") assert.ok(menu.find((item) => item.id === `folder:${ids.nestedFolder}`)?.children?.some((item) => item.id === `open:${ids.deepLink}`));
      if (action === "overflowPress" && !native) assert.ok(menu.length > 0 && menu.every((item) => item.id?.startsWith("open:") && ids.overflow.includes(item.id.slice(5))));
      if (overflow) assert.deepEqual(menu.filter((item) => item.id?.startsWith("open:")).map((item) => item.id.slice(5)), overflow);
      return menu.map((item) => item.id ?? "separator");
    });
  }
  if (native) {
    await rep.check("native-drag-cancel", async () => {
      const before = await run("return barIds();");
      await input("cancelDrag", ids.second, 0, 1);
      assert.deepEqual(await run("return barIds();"), before);
    });
  } else {
    for (const name of ["native-drag-cancel", "folder-to-sidebar"]) skip(name);
  }
  await rep.check(native ? "drag-reorders" : "store-reorders", async () => {
    if (native) {
      await visibleItem(ids.second);
      await input("drag", ids.second, 0, 1);
    } else await run(`S().moveBookmark(${JSON.stringify(ids.second)}, bmbar.bar, 0); return true;`);
    await until("bookmark reorder", "return barIds();", (value) => value[0] === ids.second && value[1] === ids.first);
  });
  await rep.check(native ? "drag-into-folder" : "store-moves-into-folder", async () => {
    if (native) {
      const folder = await visibleItem(ids.folder);
      await input("drag", ids.second, 0, folder.frame.x + folder.frame.width / 2);
    } else await run(`S().moveBookmark(${JSON.stringify(ids.second)}, ${JSON.stringify(ids.folder)}); return true;`);
    await until("bookmark moves into folder", `return S().bookmarks.nodes[${JSON.stringify(ids.second)}].parentId === ${JSON.stringify(ids.folder)} && !barIds().includes(${JSON.stringify(ids.second)});`);
    assert.ok(await run(`return S().bookmarks.nodes[${JSON.stringify(ids.folder)}].children.includes(${JSON.stringify(ids.second)});`));
  });
  if (native) await rep.check("folder-to-sidebar", async () => {
    const before = await run("return Object.keys(S().groups);");
    await visibleItem(ids.folder);
    await input("drag", ids.folder, 0, -1000);
    const group = await until("folder becomes pinned sidebar group", `return Object.values(S().groups).find((group) => group.windowId === "w1" && group.pinned && group.name === "Folder" && !${JSON.stringify(before)}.includes(group.id)) ?? null;`);
    assert.ok(group.tabIds.length >= 2);
    assert.ok(await run(`return barIds().includes(${JSON.stringify(ids.folder)});`));
  });
  await rep.check("empty-import-and-hint", async () => {
    await run("S().removeBookmarks([...barIds()]); S().updateSettings({ hideBookmarksBarImport: false }); return true;");
    await until("empty bar root", "return barIds().length === 0;");
    if (native) {
      await until("empty import button", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.importShown && !value.hintShown && value.otherShown);
      const count = await run("return bmbar.menus.length;");
      await input("importContextMenu");
      await until("import context menu", "return bmbar.menus;", (value) => value.length > count && value.at(-1).some((item) => item.id === "hide"));
    } else await until("RN import button", 'return acPerf.findFibers("ImportButton", 200).length > 0;');
    await run("S().updateSettings({ hideBookmarksBarImport: true }); return true;");
    if (native) await until("empty hint", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.hintShown && !value.importShown && value.otherShown);
    else await until("RN empty hint", 'return rnText("For quick access, place your bookmarks here on the bookmarks bar.");');
    assert.equal(await run("return S().settings.hideBookmarksBarImport;"), true);
  });
  await rep.check("new-tab-only-visibility", async () => {
    await run(`S().activate("a"); S().navigate("a", ${JSON.stringify(`${base}/initial`)}); S().updateSettings({ bookmarksBar: "newTab" }); return true;`);
    if (native) await until("native bar hidden on a page", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value === null);
    else await until("RN bar hidden on a page", "return !rnBar();");
    const newTab = await run('return S().newTab("w1");');
    assert.ok(newTab);
    if (native) await until("native bar shown on New Tab", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);');
    else await until("RN bar shown on New Tab", "return rnBar();");
    assert.equal(await run("return S().tabs[active()].url;"), "");
  });
} catch (error) {
  rep.record("run", { error });
} finally {
  if (app) {
    await run("if (globalThis.bmbar?.showMenu) globalThis.expo.modules.SolaraShell.showMenu = bmbar.showMenu; return true;").catch(() => {});
    await app.quit();
  }
  await new Promise((done) => server.close(done));
}
process.exitCode = rep.summary() ? 0 : 1;
