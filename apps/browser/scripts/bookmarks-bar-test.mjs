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
const editorState = () => acPerf.findFibers("NativeBookmarkEditor", 200).map((fiber) => fiber.memoizedProps?.state).find((state) => state?.windowId === "w1") ?? null;
const cancelEditor = () => {
  const form = acPerf.findFibers("NativePage", 2000).find((fiber) => {
    for (let parent = fiber.return; parent; parent = parent.return) if (acPerf.nameOf(parent.type) === "NativeBookmarkEditor" && parent.memoizedProps?.state?.windowId === "w1") return true;
    return false;
  });
  if (!form?.memoizedProps?.onPageEvent) return false;
  form.memoizedProps.onPageEvent({ nativeEvent: { kind: "cancel" } });
  return true;
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
const menu = (trigger, id = null) => run(`return H.devBookmarksBarMenu("w1", ${JSON.stringify(trigger)}, ${JSON.stringify(id)}).then(JSON.parse);`);
const choose = async (trigger, id, choiceId) => {
  const result = await run(`return H.devBookmarksBarChoose("w1", ${JSON.stringify(trigger)}, ${JSON.stringify(id)}, ${JSON.stringify(choiceId)}).then(JSON.parse);`);
  assert.equal(result.accepted, true, `${trigger} accepts ${choiceId}`);
  return result;
};
const menuRows = (items) => items.map((item) => item.separator ? { separator: true } : {
  title: item.title,
  choiceId: item.choiceId ?? item.id ?? null,
  symbol: item.symbol ?? null,
  enabled: item.enabled !== false,
  checked: item.checked === true,
  children: item.children == null ? [] : menuRows(item.children),
});
const row = (title, choiceId, options = {}) => ({ title, choiceId, symbol: null, enabled: true, checked: false, children: [], ...options });
const separator = { separator: true };
const barRows = (id = null, mode = "always") => [
  row("Add Page…", id ? `addPage:${id}` : "addPage"),
  row("Add Folder…", id ? `addFolder:${id}` : "addFolder"),
  separator,
  row("Manage Bookmarks", "manage"),
  row("Show Bookmarks Bar", "show", { children: [
    row("Always", "bar:always", { checked: mode === "always" }),
    row("On New Tab Only", "bar:newTab", { checked: mode === "newTab" }),
    row("Never", "bar:never", { checked: mode === "never" }),
  ] }),
];
const footerRows = (id, count, enabled = true) => [
  separator,
  row(`Open All (${count})`, `openAll:${id}`),
  row("Open All in New Window", `openAllWindow:${id}`),
  row("Open All in Incognito Window", `openAllIncognito:${id}`),
  row("Add to Sidebar as Group", `addGroup:${id}`, { enabled }),
];
const folderContextRows = (id, count, arc = false) => [
  row(`Open All (${count})`, `openAll:${id}`, { enabled: count > 0 }),
  row("Open All in New Window", `openAllWindow:${id}`, { enabled: count > 0 }),
  row("Open All in Incognito Window", `openAllIncognito:${id}`, { enabled: count > 0 }),
  row("Add to Sidebar as Group", `addGroup:${id}`, { enabled: count > 0 }),
  ...(arc ? [row("Restore Arc Folders as Groups", `restoreArc:${id}`)] : []),
  separator,
  row("Rename…", `rename:${id}`),
  row("Delete", `delete:${id}`),
  separator,
  ...barRows(id),
];
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
    if (native) assert.equal(await run('return typeof H.devBookmarksBarInput === "function" && typeof H.devBookmarksBarLayout === "function" && typeof H.devBookmarksBarMenu === "function" && typeof H.devBookmarksBarChoose === "function";'), true, "Debug native hooks available");
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
  if (!native) for (const [name, action, id, expected] of [
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
    await rep.check("native-url-context-menu", async () => {
      assert.deepEqual(menuRows(await menu("item", ids.first)), [
        row("Open in New Tab", `tab:${ids.first}`),
        row("Open in New Window", `window:${ids.first}`),
        row("Open in Incognito Window", `incognito:${ids.first}`),
        row("Open in Split View", `split:${ids.first}`),
        separator,
        row("Edit…", `edit:${ids.first}`),
        row("Copy Link", `copy:${ids.first}`),
        row("Delete", `delete:${ids.first}`),
        separator,
        ...barRows(ids.first),
      ]);
    });
    await rep.check("native-folder-context-menu", async () => {
      assert.deepEqual(menuRows(await menu("item", ids.folder)), folderContextRows(ids.folder, 2));
    });
    await rep.check("native-blank-context-menu", async () => {
      assert.deepEqual(menuRows(await menu("blank")), barRows());
    });
    await rep.check("native-folder-tree-menu", async () => {
      assert.deepEqual(menuRows(await menu("folder", ids.folder)), [
        row("Nested", `open:${ids.nested}`, { symbol: "globe" }),
        row("Nested folder", `folder:${ids.nestedFolder}`, { symbol: "folder", children: [
          row("Deep link", `open:${ids.deepLink}`, { symbol: "globe" }),
          ...footerRows(ids.nestedFolder, 1),
        ] }),
        ...footerRows(ids.folder, 2),
      ]);
    });
    await rep.check("native-overflow-menu", async () => {
      const overflow = (await layout()).overflowIds;
      const titles = await run(`return ${JSON.stringify(overflow)}.map((id) => S().bookmarks.nodes[id].title);`);
      assert.deepEqual(menuRows(await menu("overflow")), overflow.map((id, index) => row(titles[index], `open:${id}`, { symbol: "globe" })));
    });
    await rep.check("native-other-menu", async () => {
      assert.deepEqual(menuRows(await menu("other")), [
        row("Other entry", `open:${ids.other}`, { symbol: "globe" }),
        ...footerRows(await run("return S().bookmarks.roots.default.other;"), 1),
      ]);
    });
    const menuFixtures = await run(`
      const s = S();
      const empty = s.addBookmarkFolder({ profileId: "default", title: "Empty folder" });
      const arc = s.addBookmarkFolder({ profileId: "default", title: "Imported (Arc)" });
      const arcFolder = s.addBookmarkFolder({ profileId: "default", parentId: arc, title: "Arc Work" });
      const arcLink = s.addBookmark({ profileId: "default", parentId: arcFolder, title: "Arc link", url: ${JSON.stringify(`${base}/arc`)} });
      const sidebar = s.addBookmarkFolder({ profileId: "default", title: "Menu group" });
      s.addBookmark({ profileId: "default", parentId: sidebar, title: "Menu group link", url: ${JSON.stringify(`${base}/menu-group`)} });
      const copy = s.addBookmark({ profileId: "default", title: "Tracked", url: ${JSON.stringify(`${base}/copy?keep=yes&utm_source=fixture&fbclid=fixture#section`)} });
      const doomed = s.addBookmark({ profileId: "default", title: "Delete me", url: ${JSON.stringify(`${base}/delete`)} });
      const many = s.addBookmarkFolder({ profileId: "default", title: "Many links" });
      for (let index = 0; index < 16; index++) s.addBookmark({ profileId: "default", parentId: many, title: "Many " + index, url: ${JSON.stringify(`${base}/many/`)} + index });
      const shell = globalThis.expo.modules.SolaraShell;
      bmbar.prompt = shell.prompt;
      bmbar.confirm = shell.confirm;
      bmbar.prompts = [];
      bmbar.confirms = [];
      shell.prompt = (options) => { bmbar.prompts.push(options); return Promise.resolve("Menu folder"); };
      shell.confirm = (options) => { bmbar.confirms.push(options); return Promise.resolve({ confirmed: false, suppressed: false }); };
      return { empty, arc, arcFolder, arcLink, sidebar, copy, doomed, many, otherRoot: s.bookmarks.roots.default.other };
    `);
    await until("native menu fixture snapshot", `return H.devBookmarksBarMenu("w1", "item", ${JSON.stringify(menuFixtures.many)}).then(JSON.parse);`, (value) => Array.isArray(value) && value.some((item) => item.title === "Open All (16)"));
    await rep.check("native-empty-folder-menus", async () => {
      assert.deepEqual(menuRows(await menu("item", menuFixtures.empty)), folderContextRows(menuFixtures.empty, 0));
      assert.deepEqual(menuRows(await menu("folder", menuFixtures.empty)), [row("Empty", "empty", { enabled: false })]);
      const result = await run(`return H.devBookmarksBarChoose("w1", "item", ${JSON.stringify(menuFixtures.empty)}, ${JSON.stringify(`openAll:${menuFixtures.empty}`)}).then(JSON.parse);`);
      assert.equal(result.accepted, false, "disabled Open All cannot be chosen");
    });
    await rep.check("native-arc-folder-menu", async () => {
      assert.deepEqual(menuRows(await menu("item", menuFixtures.arc)), folderContextRows(menuFixtures.arc, 1, true));
    });
    await rep.check("native-copy-clean-link-without-clipboard", async () => {
      const count = await run("return bmbar.menus.length;");
      assert.equal((await choose("item", menuFixtures.copy, `copy:${menuFixtures.copy}`)).copyText, `${base}/copy?keep=yes#section`);
      assert.equal(await run("return bmbar.menus.length;"), count, "native menu choices do not show a JS menu");
    });
    await rep.check("native-menu-open-current", async () => {
      await reset();
      await choose("folder", ids.folder, `open:${ids.nested}`);
      await until("tree choice navigates current tab", `return S().tabs.a.url === ${JSON.stringify(`${base}/nested`)};`);
    });
    await rep.check("native-menu-open-new-tab", async () => {
      await reset();
      const before = await run("return [...S().windows.w1.tabIds];");
      await choose("item", ids.first, `tab:${ids.first}`);
      const created = await until("context choice opens foreground tab", "return { ids: S().windows.w1.tabIds, active: active(), tabs: S().tabs };", (value) => value.ids.length === before.length + 1);
      const added = created.ids.find((id) => !before.includes(id));
      assert.equal(created.active, added);
      assert.equal(created.tabs[added].url, destination);
    });
    for (const [action, incognito] of [["window", false], ["incognito", true]]) {
      await rep.check(`native-menu-open-${action}`, async () => {
        await reset();
        const before = await run("return Object.keys(S().windows);");
        await choose("item", ids.first, `${action}:${ids.first}`);
        const created = await until("context choice creates window", "return Object.values(S().windows).map((window) => ({ id: window.id, incognito: !!window.incognito, urls: window.tabIds.map((id) => S().tabs[id]?.url) }));", (value) => value.some((window) => !before.includes(window.id) && window.urls.includes(destination)));
        const window = created.find((window) => !before.includes(window.id) && window.urls.includes(destination));
        assert.equal(window.incognito, incognito);
        await run(`S().closeWindow(${JSON.stringify(window.id)}); return true;`);
        await until("menu window closes", `return !S().windows[${JSON.stringify(window.id)}];`);
      });
    }
    await rep.check("native-menu-open-split", async () => {
      await reset();
      await choose("item", ids.first, `split:${ids.first}`);
      await until("context choice opens split", `return Object.values(S().splits).some((split) => split.tabIds.includes("a") && split.tabIds.some((id) => id !== "a" && S().tabs[id]?.url === ${JSON.stringify(destination)}));`);
      await reset();
    });
    for (const [trigger, action, incognito] of [["folder", "openAll", false], ["item", "openAllWindow", false], ["other", "openAllIncognito", true]]) {
      await rep.check(`native-menu-${action}`, async () => {
        await reset();
        const folder = trigger === "other" ? menuFixtures.otherRoot : ids.folder;
        const urls = trigger === "other" ? [`${base}/other`] : [`${base}/nested`, `${base}/deep`];
        const before = await run("return { windows: Object.keys(S().windows), tabs: [...S().windows.w1.tabIds], confirms: bmbar.confirms.length }; ");
        await choose(trigger, trigger === "other" ? null : folder, `${action}:${folder}`);
        if (action === "openAll") {
          const tabs = await until("Open All appends links", "return S().windows.w1.tabIds.map((id) => ({ id, url: S().tabs[id]?.url }));", (value) => value.length === before.tabs.length + urls.length);
          assert.deepEqual(tabs.filter((tab) => !before.tabs.includes(tab.id)).map((tab) => tab.url), urls);
        } else {
          const created = await until("Open All creates target window", "return Object.values(S().windows).map((window) => ({ id: window.id, incognito: !!window.incognito, urls: window.tabIds.map((id) => S().tabs[id]?.url) }));", (value) => value.some((window) => !before.windows.includes(window.id) && window.urls.length === urls.length && window.urls[0] === urls[0]));
          const window = created.find((window) => !before.windows.includes(window.id) && window.urls[0] === urls[0]);
          assert.deepEqual(window.urls, urls);
          assert.equal(window.incognito, incognito);
          await run(`S().closeWindow(${JSON.stringify(window.id)}); return true;`);
          await until("Open All window closes", `return !S().windows[${JSON.stringify(window.id)}];`);
        }
        assert.equal(await run("return bmbar.confirms.length;"), before.confirms, "up to 15 links bypass confirmation");
      });
    }
    await rep.check("native-menu-open-all-confirmation", async () => {
      const before = await run("return { tabs: [...S().windows.w1.tabIds], confirms: bmbar.confirms.length }; ");
      await choose("item", menuFixtures.many, `openAll:${menuFixtures.many}`);
      const prompts = await until("large-folder confirmation", "return bmbar.confirms;", (value) => value.length > before.confirms);
      assert.deepEqual(prompts.at(-1), { title: "Open 16 tabs?", message: "This folder has a lot of bookmarks.", confirmTitle: "Open All", windowId: "w1" });
      assert.deepEqual(await run("return S().windows.w1.tabIds;"), before.tabs, "cancelled confirmation opens nothing");
    });
    await rep.check("native-menu-add-sidebar-group", async () => {
      const before = await run("return Object.keys(S().groups);");
      await choose("folder", menuFixtures.sidebar, `addGroup:${menuFixtures.sidebar}`);
      const group = await until("menu creates sidebar group", `return Object.values(S().groups).find((group) => group.windowId === "w1" && group.pinned && group.name === "Menu group" && !${JSON.stringify(before)}.includes(group.id)) ?? null;`);
      assert.equal(group.tabIds.length, 1);
      assert.equal(await run(`return !!S().bookmarks.nodes[${JSON.stringify(menuFixtures.sidebar)}];`), true);
    });
    await rep.check("native-menu-restore-arc-folders", async () => {
      const before = await run("return Object.keys(S().groups);");
      await choose("item", menuFixtures.arc, `restoreArc:${menuFixtures.arc}`);
      const group = await until("Arc folder restored as group", `return Object.values(S().groups).find((group) => group.pinned && group.name === "Arc Work" && !${JSON.stringify(before)}.includes(group.id)) ?? null;`);
      assert.equal(group.tabIds.length, 1);
      await until("restored Arc bookmarks removed", `return !S().bookmarks.nodes[${JSON.stringify(menuFixtures.arc)}] && !S().bookmarks.nodes[${JSON.stringify(menuFixtures.arcFolder)}] && !S().bookmarks.nodes[${JSON.stringify(menuFixtures.arcLink)}];`);
    });
    for (const [action, id, folder] of [["edit", ids.first, false], ["rename", ids.folder, true]]) {
      await rep.check(`native-menu-${action}-editor`, async () => {
        await choose("item", id, `${action}:${id}`);
        const state = await until("bookmark editor request", "return editorState();");
        assert.equal(state.bookmarkId, id);
        assert.equal(state.folder, folder);
        assert.equal(state.windowId, "w1");
        assert.equal(await run("return cancelEditor();"), true);
        await until("bookmark editor closes", "return editorState() === null;");
      });
    }
    for (const [trigger, context] of [["item", ids.first], ["blank", null]]) {
      await rep.check(`native-menu-add-page-${trigger}`, async () => {
        const expectedIndex = context ? await run(`return barIds().indexOf(${JSON.stringify(context)}) + 1;`) : null;
        await choose(trigger, context, context ? `addPage:${context}` : "addPage");
        const state = await until("Add Page editor request", "return editorState();");
        assert.equal(state.bookmarkId, null);
        assert.equal(state.profileId, "default");
        assert.equal(state.parentId, ids.bar);
        assert.equal(state.index ?? null, expectedIndex);
        assert.equal(await run("return cancelEditor();"), true);
        await until("Add Page editor closes", "return editorState() === null;");
      });
      await rep.check(`native-menu-add-folder-${trigger}`, async () => {
        const before = await run("return { children: [...barIds()], prompts: bmbar.prompts.length }; ");
        await choose(trigger, context, context ? `addFolder:${context}` : "addFolder");
        const children = await until("Add Folder prompt creates bookmark", "return barIds();", (value) => value.length === before.children.length + 1);
        const created = children.find((id) => !before.children.includes(id));
        const node = await run(`return S().bookmarks.nodes[${JSON.stringify(created)}];`);
        assert.equal(node.kind, "folder");
        assert.equal(node.title, "Menu folder");
        assert.equal(node.parentId, ids.bar);
        assert.equal(children.indexOf(created), context ? before.children.indexOf(context) + 1 : before.children.length);
        assert.deepEqual(await run("return bmbar.prompts.at(-1);"), { title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId: "w1" });
        assert.equal(await run("return bmbar.prompts.length;"), before.prompts + 1);
        await run(`S().removeBookmark(${JSON.stringify(created)}); return true;`);
      });
    }
    await rep.check("native-menu-delete", async () => {
      await choose("item", menuFixtures.doomed, `delete:${menuFixtures.doomed}`);
      await until("Delete removes bookmark", `return !S().bookmarks.nodes[${JSON.stringify(menuFixtures.doomed)}];`);
    });
    await rep.check("native-menu-manage-bookmarks", async () => {
      await choose("blank", null, "manage");
      await until("Manage opens internal page", 'return S().tabs[active()]?.url === "solara://bookmarks";');
    });
    await rep.check("native-menu-bar-modes", async () => {
      await run('S().newTab("w1"); return true;');
      for (const mode of ["newTab", "always", "never"]) {
        await choose("blank", null, `bar:${mode}`);
        await until("bar mode stored", `return S().settings.bookmarksBar === ${JSON.stringify(mode)};`);
        if (mode === "never") await until("Never hides bar", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value === null);
        else await until("mode submenu checkmarks", 'return H.devBookmarksBarMenu("w1", "blank", null).then(JSON.parse);', (value) => Array.isArray(value) && value.at(-1)?.children?.find((item) => item.choiceId === `bar:${mode}`)?.checked);
        if (mode !== "never") assert.deepEqual(menuRows(await menu("blank")), barRows(null, mode));
      }
      await run('S().updateSettings({ bookmarksBar: "always" }); return true;');
      await until("bar visible again", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);');
      assert.deepEqual(menuRows(await menu("blank")), barRows());
    });
    await run(`S().removeBookmarks(${JSON.stringify([menuFixtures.empty, menuFixtures.sidebar, menuFixtures.copy, menuFixtures.many])}); return true;`);
    await reset();
    assert.equal(await run("return bmbar.menus.length;"), 0, "native menu path never invokes RN showMenu");
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
      assert.deepEqual(menuRows(await menu("import")), [row("Hide Import Bookmarks Button", "hide")]);
      await choose("import", null, "hide");
      await until("Hide Import choice updates settings", "return S().settings.hideBookmarksBarImport === true;");
    } else await until("RN import button", 'return acPerf.findFibers("ImportButton", 200).length > 0;');
    if (!native) await run("S().updateSettings({ hideBookmarksBarImport: true }); return true;");
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
    await run(`
      const shell = globalThis.expo.modules.SolaraShell;
      if (globalThis.bmbar?.showMenu) shell.showMenu = bmbar.showMenu;
      if (globalThis.bmbar?.prompt) shell.prompt = bmbar.prompt;
      if (globalThis.bmbar?.confirm) shell.confirm = bmbar.confirm;
      return true;
    `).catch(() => {});
    await app.quit();
  }
  await new Promise((done) => server.close(done));
}
process.exitCode = rep.summary() ? 0 : 1;
