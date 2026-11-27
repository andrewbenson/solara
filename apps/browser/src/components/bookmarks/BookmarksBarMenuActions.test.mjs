import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";
const { useBrowser } = await import('../../store/browser.ts');
const { shellNativeModules } = await import('../../test-native/shell.ts');
const { useBookmarkEditor } = await import('./edit.ts');

const actionsURL = new URL("../../lib/actions.ts", import.meta.url).href;
const bookmarkActionsURL = new URL("./actions.ts", import.meta.url).href;
const pageURLs = new URL("../pages/urls.ts", import.meta.url).href;
const browserURL = new URL("../../store/browser.ts", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if ((context.parentURL === bookmarkActionsURL || context.parentURL === pageURLs) && specifier === "@solara/settings") return fake(`export const nativeWorkspaceCommand = (...args) => globalThis.bookmarkMenuRequests.push(args);`);
    const resolved = next(specifier, context);
    if (resolved.url === actionsURL) return fake(`import { useBrowser } from ${JSON.stringify(browserURL)}; export const focus = (id) => useBrowser.getState().setFocusedWindow(id); export const openWindow = (options) => useBrowser.getState().createWindow(options);`);
    return resolved;
  },
});
const { handleBookmarksBarMenuChoice } = await import("./bookmarksBarActions.ts");
after(() => { hooks.deregister(); delete globalThis.bookmarkMenuRequests; });
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
  requests = globalThis.bookmarkMenuRequests = [];
});
after(() => Object.assign(shell, original));

const choice = (action, id) => handleBookmarksBarMenuChoice(windowId, "default", action, id);
const barChildren = () => S().bookmarks.nodes[S().bookmarks.roots.default.bar].children;

test("URL choices send bookmark identity and destination to the native owner", async () => {
  const before = structuredClone({ tabs: S().tabs, windows: S().windows });
  for (const [action, mode] of [["open", "current"], ["tab", "foreground"], ["window", "window"], ["incognito", "incognito"], ["split", "split"]]) {
    await choice(action, nested);
    assert.deepEqual(requests.at(-1), ["openBookmarkItems", JSON.stringify({ id: nested, mode }), windowId]);
  }
  assert.deepEqual({ tabs: S().tabs, windows: S().windows }, before);
});

test("folder choices delegate opening and confirmation to the native owner", async () => {
  const before = [...S().windows[windowId].tabIds];
  shell.confirm = () => { throw new Error("JavaScript requested bookmark confirmation"); };
  for (const [action, mode] of [["openAll", "tabs"], ["openAllWindow", "window"], ["openAllIncognito", "incognito"]]) {
    await choice(action, folder);
    assert.deepEqual(requests.at(-1), ["openBookmarkItems", JSON.stringify({ id: folder, mode, folder: true }), windowId]);
  }
  assert.deepEqual(S().windows[windowId].tabIds, before);
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

test("Add Group files the folder and Arc restoration delegates to the native owner", async () => {
  await choice("addGroup", folder);
  assert.ok(Object.values(S().groups).some((group) => group.name === "Folder" && group.pinned && group.windowId === windowId));
  const holder = S().addBookmarkFolder({ profileId: "default", title: "Space (Arc)" });
  const arc = S().addBookmarkFolder({ profileId: "default", parentId: holder, title: "Arc group" });
  S().addBookmark({ profileId: "default", parentId: arc, title: "Arc link", url: "https://arc.example/" });
  await choice("restoreArc", holder);
  assert.deepEqual(requests, [["restoreArcFolders", holder, windowId]]);
  assert.ok(S().bookmarks.nodes[holder]);
});

test("manage, bar modes, hidden import and Copy Link retain their actions", async () => {
  await choice("manage");
  assert.deepEqual(requests.pop(), ["openLibraryPage", JSON.stringify({ page: "bookmarks" }), windowId]);
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
