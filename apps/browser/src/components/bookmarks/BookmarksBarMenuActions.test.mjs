import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";
import { useBrowser } from "../../store/browser.ts";
import { shellNativeModules } from "../../test-native/shell.ts";
import { useBookmarkEditor } from "./edit.ts";

const barURL = new URL("./BookmarksBar.tsx", import.meta.url).href;
const actionsURL = new URL("../../lib/actions.ts", import.meta.url).href;
const browserURL = new URL("../../store/browser.ts", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === barURL) {
      if (specifier === "react-native") return fake('export const Animated = {}; export const PanResponder = {}; export const Pressable = () => null; export const StyleSheet = {}; export const Text = () => null; export const View = () => null;');
      if (specifier === "../primitives") return fake('export const Favicon = () => null; export const useHover = () => ({});');
      if (specifier === "../settings/windows") return fake('export const openImport = () => {};');
      if (specifier === "../sidebar/tokens") return fake('export const useSidebarWidth = () => 0;');
    }
    const resolved = next(specifier, context);
    if (resolved.url === actionsURL) return fake(`import { useBrowser } from ${JSON.stringify(browserURL)}; export const focus = (id) => useBrowser.getState().setFocusedWindow(id); export const openWindow = (options) => useBrowser.getState().createWindow(options);`);
    return resolved;
  },
});
const { handleBookmarksBarMenuChoice, openBarMenu, openFolderMenu, openImportMenu } = await import("./BookmarksBar.tsx");
after(() => hooks.deregister());
const S = () => useBrowser.getState();
const shell = shellNativeModules.SolaraShell;
const original = { prompt: shell.prompt, showMenu: shell.showMenu, confirm: shell.confirm, copyText: shell.copyText };
let windowId;
let first;
let folder;
let nested;
let requests;

beforeEach(() => {
  Object.assign(shell, original);
  S().hydrate({ bookmarks: { nodes: {}, roots: {} }, groups: {}, windows: {}, tabs: {}, splits: {} });
  windowId = S().createWindow();
  first = S().addBookmark({ profileId: "default", title: "First", url: "https://example.com/?utm_source=fixture&keep=1" });
  folder = S().addBookmarkFolder({ profileId: "default", title: "Folder" });
  nested = S().addBookmark({ profileId: "default", parentId: folder, title: "Nested", url: "https://nested.example/" });
  useBookmarkEditor.getState().set(null);
  requests = [];
});
after(() => Object.assign(shell, original));

const choice = (action, id) => handleBookmarksBarMenuChoice(windowId, "default", action, id);
const barChildren = () => S().bookmarks.nodes[S().bookmarks.roots.default.bar].children;

test("URL choices preserve current, foreground, window, private and split destinations", async () => {
  const source = S().windows[windowId].activeTabIds.default;
  await choice("open", nested);
  assert.equal(S().tabs[source].url, "https://nested.example/");
  await choice("tab", first);
  const foreground = S().windows[windowId].activeTabIds.default;
  assert.notEqual(foreground, source);
  assert.equal(S().tabs[foreground].url, S().bookmarks.nodes[first].url);
  for (const [action, incognito] of [["window", false], ["incognito", true]]) {
    const before = Object.keys(S().windows);
    await choice(action, first);
    const created = Object.values(S().windows).find((window) => !before.includes(window.id));
    assert.equal(created.incognito, incognito);
    assert.equal(S().tabs[created.activeTabIds[created.profileId]].url, S().bookmarks.nodes[first].url);
  }
  await choice("split", first);
  assert.ok(Object.values(S().splits).some((split) => split.windowId === windowId && split.tabIds.some((id) => S().tabs[id].url === S().bookmarks.nodes[first].url)));
});

test("folder choices open all in order and retain the greater-than-fifteen confirmation", async () => {
  S().addBookmark({ profileId: "default", parentId: folder, title: "Second", url: "https://second.example/" });
  const before = [...S().windows[windowId].tabIds];
  await choice("openAll", folder);
  const created = S().windows[windowId].tabIds.filter((id) => !before.includes(id));
  assert.deepEqual(created.map((id) => S().tabs[id].url), ["https://nested.example/", "https://second.example/"]);
  for (let i = 0; i < 14; i++) S().addBookmark({ profileId: "default", parentId: folder, title: String(i), url: `https://many.example/${i}` });
  shell.confirm = (request) => { requests.push(request); return Promise.resolve({ confirmed: false, suppressed: false }); };
  const count = S().windows[windowId].tabIds.length;
  await choice("openAll", folder);
  assert.equal(requests[0].title, "Open 16 tabs?");
  assert.equal(S().windows[windowId].tabIds.length, count);
});

test("shared Add Page and prompted Add Folder flows insert after their context node", async () => {
  await choice("addPage", first);
  assert.deepEqual(useBookmarkEditor.getState().open, { windowId, bookmarkId: null, folder: false, profileId: "default", parentId: S().bookmarks.roots.default.bar, index: 1 });
  shell.prompt = (request) => { requests.push(request); return Promise.resolve("Created"); };
  await choice("addFolder", first);
  const made = S().bookmarks.nodes[barChildren()[1]];
  assert.equal(made.title, "Created");
  assert.equal(made.kind, "folder");
  assert.equal(requests[0].title, "New Folder");
  assert.equal(requests[0].windowId, windowId);
  await choice("addPage");
  assert.equal(useBookmarkEditor.getState().open.parentId, S().bookmarks.roots.default.bar);
  assert.equal(useBookmarkEditor.getState().open.index, undefined);
});

test("edit, rename and delete use the real editor and bookmark store", async () => {
  await choice("edit", first);
  assert.equal(useBookmarkEditor.getState().open.bookmarkId, first);
  assert.equal(useBookmarkEditor.getState().open.folder, false);
  await choice("rename", folder);
  assert.equal(useBookmarkEditor.getState().open.bookmarkId, folder);
  assert.equal(useBookmarkEditor.getState().open.folder, true);
  await choice("delete", first);
  assert.equal(S().bookmarks.nodes[first], undefined);
  assert.ok(!barChildren().includes(first));
});

test("group and Arc restoration choices keep their existing store transformations", async () => {
  await choice("addGroup", folder);
  assert.ok(Object.values(S().groups).some((group) => group.name === "Folder" && group.pinned && group.windowId === windowId));
  const holder = S().addBookmarkFolder({ profileId: "default", title: "Space (Arc)" });
  const arc = S().addBookmarkFolder({ profileId: "default", parentId: holder, title: "Arc group" });
  S().addBookmark({ profileId: "default", parentId: arc, title: "Arc link", url: "https://arc.example/" });
  await choice("restoreArc", holder);
  assert.ok(Object.values(S().groups).some((group) => group.name === "Arc group" && group.pinned));
  assert.equal(S().bookmarks.nodes[holder], undefined);
});

test("manage, bar modes, hidden import and RN Copy Link retain their actions", async () => {
  await choice("manage");
  assert.ok(Object.values(S().tabs).some((tab) => tab.url === "solara://bookmarks"));
  for (const mode of ["always", "newTab", "never"]) {
    await choice("bar", mode);
    assert.equal(S().settings.bookmarksBar, mode);
  }
  await choice("bar", "invalid");
  assert.equal(S().settings.bookmarksBar, "never");
  await choice("hide");
  assert.equal(S().settings.hideBookmarksBarImport, true);
  shell.copyText = (text) => requests.push(text);
  await choice("copy", first);
  assert.deepEqual(requests, ["https://example.com/?keep=1"]);
});

test("RN menus still dispatch selections through the shared action implementation", async () => {
  shell.showMenu = () => Promise.resolve("edit");
  await openBarMenu(windowId, "default", S().bookmarks.nodes[first]);
  assert.equal(useBookmarkEditor.getState().open.bookmarkId, first);
  shell.showMenu = () => Promise.resolve(`open:${nested}`);
  await openFolderMenu(windowId, [nested], undefined, folder);
  assert.equal(S().tabs[S().windows[windowId].activeTabIds.default].url, "https://nested.example/");
  shell.showMenu = () => Promise.resolve("hide");
  await openImportMenu();
  assert.equal(S().settings.hideBookmarksBarImport, true);
});
