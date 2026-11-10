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
  console.error("usage: METRO_PORT=8081 node apps/browser/scripts/bookmarks-bar-test.mjs <Debug Solara.app> [--keep-data]");
  process.exit(2);
}
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
const C = globalThis.expo.modules.SolaraCEF;
const win = (id) => C.chromeWindows().then((windows) => windows.filter((window) => window.hasRoot).find((window) => {
  const frame = window.frame.match(/[-\\d.]+/g).map(Number), stored = S().windows[id]?.frame;
  return !!stored && Math.abs(stored[0] - frame[0]) < 2 && Math.abs(stored[2] - frame[2]) < 2;
}));
const act = (id, action) => win(id).then((window) => C.devWindow(window.window, action));
const postDrag = (id, path) => {
  const points = path.split(";").map((p) => p.split(",").map(Number));
  const steps = [["down", points[0]]];
  for (let i = 1; i < points.length; i++) {
    const [ax, ay] = points[i - 1], [bx, by] = points[i];
    for (let k = 1; k <= 12; k++) steps.push(["dragged", [ax + (bx - ax) * k / 12, ay + (by - ay) * k / 12]]);
  }
  steps.push(["up", points.at(-1)]);
  const start = performance.now();
  steps.reduce((chain, [type, [x, y]], i) => chain
    .then(() => new Promise((r) => setTimeout(r, Math.max(0, start + (i ? 150 + i * 16 : 0) - performance.now()))))
    .then(() => act(id, "mouse:" + type + ":" + Math.round(x * 100) / 100 + "," + Math.round(y * 100) / 100)), Promise.resolve());
  return Promise.resolve(steps.length + " events posted");
};
const settle = (ms) => new Promise((done) => setTimeout(done, ms));
const active = () => S().windows.w1.activeTabIds.default;
const barIds = () => S().bookmarks.nodes[bmbar.bar].children;
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
`;
let app;
const coroutine = `const runSteps = (steps) => new Promise((resolve, reject) => {
  const it = steps();
  const step = (method, value) => {
    let result;
    try { result = it[method](value); } catch (error) { return reject(error); }
    if (result.done) return resolve(result.value);
    Promise.resolve(result.value).then((next) => step("next", next), (error) => step("throw", error));
  };
  step("next");
});`;
const run = (body, timeout = 3000) => app.eval(/\bawait\s/.test(body) ? `${coroutine}\nreturn runSteps(function* () { ${helpers}\n${body.replace(/\bawait\s/g, "yield ")} });` : `${helpers}\n${body}`, { timeout });
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
const layout = (windowId = "w1") => run(`return H.devBookmarksBarLayout(${JSON.stringify(windowId)}).then(JSON.parse);`);
const menu = (trigger, id = null) => run(`return H.devBookmarksBarMenu("w1", ${JSON.stringify(trigger)}, ${JSON.stringify(id)}).then(JSON.parse);`);
const key = (name, id, modifiers = 0, fullKeyboardAccess = true) => run(`return H.devBookmarksBarKey("w1", ${JSON.stringify(name)}, ${JSON.stringify(id)}, ${modifiers}, ${fullKeyboardAccess}).then(JSON.parse);`);
const drop = (payload, x, folderId = null) => run(`return H.devBookmarksBarDrop("w1", ${JSON.stringify(x)}, ${JSON.stringify(folderId)}, ${JSON.stringify(JSON.stringify(payload))}).then(JSON.parse);`);
const accessibility = () => run('return H.devBookmarksBarAccessibility("w1").then(JSON.parse);');
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
  assert.equal(await run(`return H.devBookmarksBarInput("w1", ${JSON.stringify(action)}, ${JSON.stringify(id)}, ${modifiers}, ${JSON.stringify(x)});`), true, `${action} accepted`);
};
const visibleItem = async (id) => {
  const state = await until(`visible bookmark ${id}`, 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.visible?.some((item) => item.id === id));
  return state.visible.find((item) => item.id === id);
};
let ids;
try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, onboarded: true, session: fixture, probe: true,
    keepData: args.includes("--keep-data"), metroPort: Number(process.env.METRO_PORT ?? 8081),
    env: { SOLARA_NATIVE_SHELL: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf && !!globalThis.expo?.modules?.SolaraHosted;",
  });
  await until("Chrome bookmark roots ready", "return S().bookmarksReady.default === true;", undefined, 20000);
  ids = await run(`
    const s = S();
    s.updateSettings({ bookmarksBar: "always", hideBookmarksBarImport: false });
    const roots = S().bookmarks.roots.default;
    await ac.bookmarks.removeBookmarks("default", [...S().bookmarks.nodes[roots.bar].children, ...S().bookmarks.nodes[roots.other].children]);
    const first = await ac.bookmarks.addBookmark({ profileId: "default", title: "A", url: ${JSON.stringify(`${base}/first`)} });
    const second = await ac.bookmarks.addBookmark({ profileId: "default", title: "B", url: ${JSON.stringify(`${base}/second`)} });
    const folder = await ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Folder" });
    const nested = await ac.bookmarks.addBookmark({ profileId: "default", parentId: folder, title: "Nested", url: ${JSON.stringify(`${base}/nested`)} });
    const nestedFolder = await ac.bookmarks.addBookmarkFolder({ profileId: "default", parentId: folder, title: "Nested folder" });
    const deepLink = await ac.bookmarks.addBookmark({ profileId: "default", parentId: nestedFolder, title: "Deep link", url: ${JSON.stringify(`${base}/deep`)} });
    const overflow = await Promise.all(Array.from({ length: 30 }, (_, index) => ac.bookmarks.addBookmark({ profileId: "default", title: "Overflow bookmark " + index, url: ${JSON.stringify(`${base}/overflow/`)} + index })));
    const other = await ac.bookmarks.addBookmark({ profileId: "default", parentId: roots.other, title: "Other entry", url: ${JSON.stringify(`${base}/other`)} });
    globalThis.bmbar = { ...roots, first, second, folder, nested, nestedFolder, deepLink, overflow, other };
    const shell = globalThis.expo.modules.SolaraShell;
    bmbar.showMenu = shell.showMenu;
    bmbar.menus = [];
    shell.showMenu = (items) => { bmbar.menus.push(items); return Promise.resolve(null); };
    return { ...roots, first, second, folder, nested, nestedFolder, deepLink, overflow, other };
  `, 15000);
  await rep.check("launch-switch", async () => {
    const kinds = await run("return H.kinds();");
    assert.ok(kinds.includes("bookmarksBar"), "native bookmarks bar registered by default");
    assert.equal(await run('return typeof H.devBookmarksBarInput === "function" && typeof H.devBookmarksBarLayout === "function" && typeof H.devBookmarksBarMenu === "function" && typeof H.devBookmarksBarChoose === "function" && typeof H.devBookmarksBarKey === "function" && typeof H.devBookmarksBarAccessibility === "function" && typeof H.devBookmarksBarDrop === "function";'), true, "Debug native hooks available");
    assert.equal(await run('return acPerf.findFibers("BookmarksBar", 200).length;'), 0, "no React Native bar");
    return "native";
  });
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
  const destination = `${base}/first`;
  const reset = async () => {
    await run(`for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("a"); S().navigate("a", ${JSON.stringify(`${base}/initial`)}); return true;`);
    await visibleItem(ids.first);
  };
  await rep.check("native-key-focus-order", async () => {
    await reset();
    const state = await layout();
    const ordered = [...state.visible.map((item) => item.id), "overflow", "other"];
    for (const [name, from, expected] of [
      ["Right", ids.first, ids.second],
      ["Left", ids.second, ids.first],
      ["Left", ids.first, ids.first],
      ["Home", ids.folder, ids.first],
      ["End", ids.first, "other"],
      ["Right", state.visible.at(-1).id, "overflow"],
      ["Left", "overflow", state.visible.at(-1).id],
      ["Left", "other", "overflow"],
      ["Right", "overflow", "other"],
      ["Right", "other", "other"],
    ]) {
      const result = await key(name, from);
      assert.equal(result.accepted, true, `${name} accepted from ${from}`);
      assert.equal(result.focusedId, expected, `${name} from ${from}`);
      assert.deepEqual(result.keyViews, ordered, "key views follow visual order");
    }
  });
  await rep.check("native-key-full-keyboard-access-gate", async () => {
    const result = await key("Right", ids.first, 0, false);
    assert.equal(result.accepted, false);
    assert.equal(result.focusedId, null);
    assert.deepEqual(result.keyViews, [], "Tab cannot enter the bar without Full Keyboard Access");
  });
  await rep.check("native-key-return-current-tab", async () => {
    await reset();
    const count = await run("return S().windows.w1.tabIds.length;");
    assert.equal((await key("Return", ids.first)).accepted, true);
    await until("Return navigates current tab", `return active() === "a" && S().tabs.a.url === ${JSON.stringify(destination)};`);
    assert.equal(await run("return S().windows.w1.tabIds.length;"), count);
  });
  await rep.check("native-key-command-return-background-tab", async () => {
    await reset();
    const before = await run("return [...S().windows.w1.tabIds];");
    assert.equal((await key("Return", ids.first, 1 << 20)).accepted, true);
    const after = await until("Command-Return creates background tab", "return { ids: S().windows.w1.tabIds, active: active(), tabs: S().tabs };", (value) => value.ids.length === before.length + 1);
    const created = after.ids.find((id) => !before.includes(id));
    assert.equal(after.tabs[created].url, destination);
    assert.equal(after.active, "a");
  });
  await rep.check("native-key-down-folder-menu", async () => {
    await reset();
    const result = await key("Down", ids.folder);
    assert.equal(result.accepted, true);
    assert.equal(result.focusedId, ids.folder);
    assert.equal(result.menu.trigger, "folder");
    assert.equal(result.menu.id, ids.folder);
    assert.equal(result.menu.highlightedId, `open:${ids.nested}`);
    assert.deepEqual(menuRows(await menu("open")), menuRows(await menu("folder", ids.folder)), "Down opens the 3a folder menu");
  });
  await rep.check("native-key-context-menu", async () => {
    const result = await key("F10", ids.first, 1 << 17);
    assert.equal(result.accepted, true);
    assert.equal(result.menu.trigger, "item");
    assert.equal(result.menu.id, ids.first);
    assert.deepEqual(menuRows(await menu("open")), menuRows(await menu("item", ids.first)), "Shift-F10 opens the 3a item context menu");
  });
  await rep.check("native-key-escape-page", async () => {
    const result = await key("Escape", ids.first);
    assert.equal(result.accepted, true);
    assert.equal(result.focusedId, null);
  });
  await rep.check("native-accessibility-tree", async () => {
    const state = await layout();
    const tree = await accessibility();
    assert.equal(tree.role, "AXToolbar");
    assert.equal(tree.label, "Bookmarks bar");
    assert.deepEqual(tree.children.map((child) => child.id), [...state.visible.map((item) => item.id), "overflow", "other"]);
    for (const child of tree.children) {
      assert.equal(child.role, "AXButton");
      assert.equal(child.subrole, null);
      assert.deepEqual(child.actions, ["AXPress", "AXShowMenu"]);
    }
    const first = tree.children.find((child) => child.id === ids.first);
    assert.equal(first.label, "A");
    assert.equal(first.help, `A\n${destination}`);
    assert.equal(tree.children.find((child) => child.id === ids.second).label, "B");
    const folder = tree.children.find((child) => child.id === ids.folder);
    assert.equal(folder.label, "Folder");
    assert.equal(folder.help, "Folder");
    assert.equal(folder.roleDescription, "folder");
    for (const child of tree.children.slice(3, -2)) {
      const index = ids.overflow.indexOf(child.id);
      assert.ok(index >= 0);
      assert.equal(child.label, `Overflow bookmark ${index}`);
      assert.equal(child.help, `Overflow bookmark ${index}\n${base}/overflow/${index}`);
    }
    assert.equal(tree.children.at(-2).label, "More bookmarks");
    assert.equal(tree.children.at(-2).help, "More bookmarks");
    assert.equal(tree.children.at(-1).label, "Other Bookmarks");
    assert.equal(tree.children.at(-1).roleDescription, "folder");
  });
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
    const empty = await ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Empty folder" });
    const arc = await ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Imported (Arc)" });
    const arcFolder = await ac.bookmarks.addBookmarkFolder({ profileId: "default", parentId: arc, title: "Arc Work" });
    const arcLink = await ac.bookmarks.addBookmark({ profileId: "default", parentId: arcFolder, title: "Arc link", url: ${JSON.stringify(`${base}/arc`)} });
    const sidebar = await ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Menu group" });
    await ac.bookmarks.addBookmark({ profileId: "default", parentId: sidebar, title: "Menu group link", url: ${JSON.stringify(`${base}/menu-group`)} });
    const copy = await ac.bookmarks.addBookmark({ profileId: "default", title: "Tracked", url: ${JSON.stringify(`${base}/copy?keep=yes&utm_source=fixture&fbclid=fixture#section`)} });
    const doomed = await ac.bookmarks.addBookmark({ profileId: "default", title: "Delete me", url: ${JSON.stringify(`${base}/delete`)} });
    const many = await ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Many links" });
    for (let index = 0; index < 16; index++) await ac.bookmarks.addBookmark({ profileId: "default", parentId: many, title: "Many " + index, url: ${JSON.stringify(`${base}/many/`)} + index });
    const shell = globalThis.expo.modules.SolaraShell;
    bmbar.prompt = shell.prompt;
    bmbar.confirm = shell.confirm;
    bmbar.prompts = [];
    bmbar.confirms = [];
    shell.prompt = (options) => { bmbar.prompts.push(options); return Promise.resolve("Menu folder"); };
    shell.confirm = (options) => { bmbar.confirms.push(options); return Promise.resolve({ confirmed: false, suppressed: false }); };
    return { empty, arc, arcFolder, arcLink, sidebar, copy, doomed, many, otherRoot: s.bookmarks.roots.default.other };
  `, 15000);
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
      await run(`await ac.bookmarks.removeBookmark("default", ${JSON.stringify(created)}); return true;`);
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
  await run(`await ac.bookmarks.removeBookmarks("default", ${JSON.stringify([menuFixtures.empty, menuFixtures.sidebar, menuFixtures.copy, menuFixtures.many])}); return true;`);
  await reset();
  assert.equal(await run("return bmbar.menus.length;"), 0, "native menu path never invokes RN showMenu");
  await rep.check("native-drop-link-between-items", async () => {
    const second = await visibleItem(ids.second);
    const before = await run("return barIds();");
    const link = { url: `${base}/dropped-between`, title: "Dropped between" };
    const result = await drop({ items: [link] }, second.frame.x);
    assert.equal(result.accepted, true);
    assert.equal(result.parentId, ids.bar);
    assert.equal(result.index, 1);
    assert.deepEqual(result.items, [link]);
    const created = await until("dropped link inserted at index one", "return barIds().map((id) => S().bookmarks.nodes[id]);", (nodes) => nodes.length === before.length + 1 && nodes[1].url === link.url);
    assert.equal(created[1].title, link.title);
    assert.deepEqual(created.filter((node) => node.id !== created[1].id).map((node) => node.id), before);
    await run(`await ac.bookmarks.removeBookmark("default", ${JSON.stringify(created[1].id)}); return true;`);
  });
  for (const [name, parent] of [["folder", ids.folder], ["other", await run("return S().bookmarks.roots.default.other;")]]) {
    await rep.check(`native-drop-link-into-${name}`, async () => {
      await visibleItem(ids.folder);
      const before = await run(`return [...S().bookmarks.nodes[${JSON.stringify(parent)}].children];`);
      const link = { url: `${base}/dropped-${name}`, title: `Dropped into ${name}` };
      const result = await drop({ items: [link] }, 0, parent);
      assert.equal(result.accepted, true);
      assert.equal(result.parentId, parent);
      assert.equal(result.index, null);
      const children = await until(`dropped link appended to ${name}`, `return S().bookmarks.nodes[${JSON.stringify(parent)}].children.map((id) => S().bookmarks.nodes[id]);`, (nodes) => nodes.length === before.length + 1 && nodes.at(-1).url === link.url);
      assert.equal(children.at(-1).title, link.title);
      assert.deepEqual(children.slice(0, -1).map((node) => node.id), before);
      await run(`await ac.bookmarks.removeBookmark("default", ${JSON.stringify(children.at(-1).id)}); return true;`);
    });
  }
  const tabDropState = () => run(`
    const tab = S().tabs.a;
    return {
      tab: Object.fromEntries(["id", "url", "title", "profileId", "windowId", "pinned", "groupId"].map((key) => [key, tab[key] ?? null])),
      index: S().windows.w1.tabIds.indexOf("a"),
      windows: Object.values(S().windows).map((window) => ({ id: window.id, profileId: window.profileId, incognito: !!window.incognito, tabIds: [...window.tabIds], activeTabIds: { ...window.activeTabIds } })).sort((a, b) => a.id.localeCompare(b.id)),
    };
  `);
  const dragTabToBar = async (windowId, beforeId) => {
    const target = await until("native tab-drop target bar", `return H.devBookmarksBarLayout(${JSON.stringify(windowId)}).then(JSON.parse);`, (value) => value?.frame?.height > 0 && value.visible.some((item) => item.id === beforeId));
    const source = await layout();
    const row = await until("sidebar source row", 'return globalThis.expo.modules.SolaraSidebarDrag.startProbe("w1").then(JSON.parse).then((probe) => probe?.items.find((item) => item.kind === "row" && item.tabIds.length === 1 && item.tabIds[0] === "a") ?? null);', (value) => value?.w > 0 && value.h > 0);
    const frames = await until("native drag window frames", `return Promise.all([win("w1"), win(${JSON.stringify(windowId)})]).then((windows) => windows.every(Boolean) ? windows.map((window) => window.frame.match(/[-\\d.]+/g).map(Number)) : null);`);
    const item = target.visible.find((item) => item.id === beforeId);
    const sx = Math.round(row.x + row.w / 2), sy = Math.round(row.y + row.h / 2 + source.contentOffsetY);
    const tx = frames[1][0] - frames[0][0] + target.frame.x + item.frame.x;
    const ty = frames[0][1] + frames[0][3] - frames[1][1] - frames[1][3] + target.frame.y + item.frame.y + item.frame.height / 2;
    const points = [[sx, sy], [sx + 10, sy + 6], [tx - 4, ty], [tx, ty], [tx, ty], [tx, ty]];
    const seen = [];
    let settled = false, failure;
    const evaluation = run(`return postDrag("w1", "${points.map((point) => point.join(",")).join(";")}").then(() => settle(${points.length * 12 * 16 + 2400}));`, 6000)
      .then(() => { settled = true; }, (error) => { failure = error; settled = true; });
    try {
      while (!settled) {
        if (!app.alive) throw new Error("tab drop: app exited");
        const snapshot = await app.snapshot({ tabDrag: true, fields: ["root.tabDrag"] }, { timeout: 1000 });
        if (snapshot.consistent && snapshot.tabDrag) seen.push(snapshot.tabDrag);
        await sleep(40);
      }
    } finally {
      await evaluation;
    }
    if (failure) throw failure;
    assert.ok(seen.some((drag) => drag.sourceWindow === "w1" && drag.tabIds.length === 1 && drag.tabIds[0] === "a" && drag.target?.kind === "bookmarks" && (windowId === "w1" || drag.overWindow === windowId)), `real tab drag reaches ${windowId} bookmarks bar: ${JSON.stringify(seen)}`);
    await until("native tab drag finishes", 'return globalThis.acTabDrag.getState().tabIds.length === 0;');
  };
  const copiedTab = async (windowId) => {
    await reset();
    await until("source page title ready", `return S().tabs.a.url === ${JSON.stringify(`${base}/initial`)} && S().tabs.a.title === "Bookmark fixture";`);
    const before = await run("return barIds();");
    const source = await tabDropState();
    const profileId = await run(`return S().windows[${JSON.stringify(windowId)}].profileId;`);
    await dragTabToBar(windowId, ids.second);
    const nodes = await until("real tab drop creates bookmark between items", "return barIds().map((id) => S().bookmarks.nodes[id]);", (value) => value.length === before.length + 1 && value[1].url === source.tab.url);
    try {
      assert.equal(nodes[1].title, source.tab.title);
      assert.equal(nodes[1].parentId, await run(`return S().bookmarks.roots[${JSON.stringify(profileId)}].bar;`));
      assert.equal(nodes[1].parentId, ids.bar);
      assert.deepEqual(nodes.filter((node) => node.id !== nodes[1].id).map((node) => node.id), before);
      assert.deepEqual(await tabDropState(), source, "source tab, index, window, active tabs and window count stay unchanged");
    } finally {
      await run(`await ac.bookmarks.removeBookmark("default", ${JSON.stringify(nodes[1].id)}); return true;`);
    }
  };
  await rep.check("native-drop-tab-copies-without-moving", () => copiedTab("w1"));
  await rep.check("native-drop-tab-copies-to-another-window-without-moving", async () => {
    const w2 = await run(`const [x, y, w] = S().windows.w1.frame; return S().createWindow({ profileId: "default", frame: [x + w + 20, y, 560, 600], url: ${JSON.stringify(`${base}/drop-target`)} });`);
    try {
      await until("second regular window bar visible", `return H.devBookmarksBarLayout(${JSON.stringify(w2)}).then(JSON.parse);`, (value) => value?.frame?.height > 0 && value.visible.some((item) => item.id === ids.second));
      await copiedTab(w2);
    } finally {
      await run(`S().closeWindow(${JSON.stringify(w2)}); return true;`);
      await until("second window closes", `return !S().windows[${JSON.stringify(w2)}];`);
      await visibleItem(ids.second);
    }
  });
  await rep.check("native-drop-unsupported-tab-keeps-source-and-opens-no-window", async () => {
    const url = "about:blank";
    try {
      await run(`S().activate("a"); S().navigate("a", ${JSON.stringify(url)}); return true;`);
      await until("unsupported source ready", 'return S().tabs.a.url === "about:blank";');
      const before = await run("return S().bookmarks;");
      const source = await tabDropState();
      await dragTabToBar("w1", ids.second);
      assert.deepEqual(await run("return S().bookmarks;"), before, "unsupported tab creates no bookmark");
      assert.deepEqual(await tabDropState(), source, "rejected real tab drop preserves the tab and opens no window");
    } finally {
      await reset();
    }
  });
  await rep.check("native-drop-refuses-unsafe-and-non-url-payloads", async () => {
    const before = await run("return S().bookmarks;");
    for (const payload of [
      { items: [{ url: "javascript:alert(1)", title: "Unsafe" }] },
      { items: [{ url: "file:///tmp/bookmark.html", title: "File" }] },
      { items: [{ url: "data:text/html,unsafe", title: "Data" }] },
      { text: "plain non-URL text" },
      { tabIds: ["missing-tab"] },
    ]) {
      const result = await drop(payload, 8);
      assert.equal(result.accepted, false, JSON.stringify(payload));
    }
    await sleep(200);
    assert.deepEqual(await run("return S().bookmarks;"), before);
  });
  await rep.check("native-drag-cancel", async () => {
    const before = await run("return barIds();");
    await input("cancelDrag", ids.second, 0, 1);
    assert.deepEqual(await run("return barIds();"), before);
  });
  await rep.check("drag-reorders", async () => {
    await visibleItem(ids.second);
    await input("drag", ids.second, 0, 1);
    await until("bookmark reorder", "return barIds();", (value) => value[0] === ids.second && value[1] === ids.first);
  });
  await rep.check("drag-into-folder", async () => {
    const folder = await visibleItem(ids.folder);
    await input("drag", ids.second, 0, folder.frame.x + folder.frame.width / 2);
    await until("bookmark moves into folder", `return S().bookmarks.nodes[${JSON.stringify(ids.second)}].parentId === ${JSON.stringify(ids.folder)} && !barIds().includes(${JSON.stringify(ids.second)});`);
    assert.ok(await run(`return S().bookmarks.nodes[${JSON.stringify(ids.folder)}].children.includes(${JSON.stringify(ids.second)});`));
  });
  await rep.check("folder-to-sidebar", async () => {
    const before = await run("return Object.keys(S().groups);");
    await visibleItem(ids.folder);
    await input("drag", ids.folder, 0, -1000);
    const group = await until("folder becomes pinned sidebar group", `return Object.values(S().groups).find((group) => group.windowId === "w1" && group.pinned && group.name === "Folder" && !${JSON.stringify(before)}.includes(group.id)) ?? null;`);
    assert.ok(group.tabIds.length >= 2);
    assert.ok(await run(`return barIds().includes(${JSON.stringify(ids.folder)});`));
  });
  await rep.check("empty-import-and-hint", async () => {
    await run("await ac.bookmarks.removeBookmarks('default', [...barIds()]); S().updateSettings({ hideBookmarksBarImport: false }); return true;");
    await until("empty bar root", "return barIds().length === 0;");
    await until("empty import button", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.importShown && !value.hintShown && value.otherShown);
    const tree = await accessibility();
    assert.deepEqual(tree.children.map((child) => child.id), ["import", "other"]);
    assert.equal(tree.children[0].label, "Import bookmarks");
    assert.equal(tree.children[0].role, "AXButton");
    assert.equal(tree.children[0].help, "Add bookmarks from another browser");
    assert.deepEqual(menuRows(await menu("import")), [row("Hide Import Bookmarks Button", "hide")]);
    await choose("import", null, "hide");
    await until("Hide Import choice updates settings", "return S().settings.hideBookmarksBarImport === true;");
    await until("empty hint", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value?.hintShown && !value.importShown && value.otherShown);
    assert.equal(await run("return S().settings.hideBookmarksBarImport;"), true);
  });
  await rep.check("new-tab-only-visibility", async () => {
    await run(`S().activate("a"); S().navigate("a", ${JSON.stringify(`${base}/initial`)}); S().updateSettings({ bookmarksBar: "newTab" }); return true;`);
    await until("native bar hidden on a page", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);', (value) => value === null);
    const newTab = await run('return S().newTab("w1");');
    assert.ok(newTab);
    await until("native bar shown on New Tab", 'return H.devBookmarksBarLayout("w1").then(JSON.parse);');
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
