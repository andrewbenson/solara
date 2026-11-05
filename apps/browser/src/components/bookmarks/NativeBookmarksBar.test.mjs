import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const barURL = new URL("./NativeBookmarksBar.tsx", import.meta.url).href;
const f = globalThis.nativeBookmarksBarTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `
    const f = globalThis.nativeBookmarksBarTest;
    export const hostedKinds = () => f.kinds;
    export const SolaraHostedView = "HostedView";
    export const onHostedEvent = (kind, windowId, fn) => {
      f.listeners.set(windowId, fn);
      f.subscriptions.push([kind, windowId]);
      return () => f.listeners.delete(windowId);
    };
  `,
  react: `export const memo = (fn) => fn; export const useEffect = (fn) => { globalThis.nativeBookmarksBarTest.cleanups.push(fn()); };`,
  "react-native": `export const View = "View";`,
  "../../lib/bookmarkGroups": `export const addFolderToSidebar = (...args) => globalThis.nativeBookmarksBarTest.actions.push(["sidebar", ...args]);`,
  "../sidebar/tokens": `export const useSidebarWidth = () => globalThis.nativeBookmarksBarTest.sidebarWidth;`,
  "../../lib/theme": `export const useTheme = () => globalThis.nativeBookmarksBarTest.theme;`,
  "../../store/bookmarks": `export const folderChildren = (bookmarks, id) => {
    const node = bookmarks.nodes[id];
    return node?.kind === "folder" ? node.children.map((id) => bookmarks.nodes[id]).filter(Boolean) : [];
  };`,
  "../../store/browser": `const f = globalThis.nativeBookmarksBarTest; export const useBrowser = (fn) => fn(f.state); useBrowser.getState = () => f.state;`,
  "../../store/hooks": `export const useWindowId = () => globalThis.nativeBookmarksBarTest.windowId;`,
  "../../store/model": `export const bookmarkProfileId = (_state, window) => window.profileId;`,
  "../settings/windows": `export const openImport = () => globalThis.nativeBookmarksBarTest.actions.push(["import"]);`,
  "./actions": `
    export const openModeFor = (mods) => mods;
    export const openUrl = (...args) => globalThis.nativeBookmarksBarTest.actions.push(["url", ...args]);
  `,
  "./BookmarksBar": `
    const f = globalThis.nativeBookmarksBarTest;
    export const BOOKMARKS_BAR_HEIGHT = 30;
    export const BookmarksBar = "FallbackBar";
    export const openBarMenu = (...args) => f.actions.push(["context", ...args]);
    export const openFolderMenu = (...args) => f.actions.push(["folder", ...args]);
    export const openImportMenu = () => f.actions.push(["importMenu"]);
    export const handleBookmarksBarMenuChoice = (...args) => f.actions.push(["menuChoice", ...args]);
  `,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === barURL && specifier in sources) return fake(sources[specifier]);
    return next(specifier, context);
  },
});
const { NativeBookmarksBar } = await import("./NativeBookmarksBar.tsx");
after(() => { hooks.deregister(); delete globalThis.nativeBookmarksBarTest; });

const folder = (id, children) => ({ id, kind: "folder", title: id, children });
const url = (id) => ({ id, kind: "url", title: id, url: `https://${id}.example`, favicon: null });
const mount = () => {
  const element = NativeBookmarksBar({});
  return element.type(element.props);
};

beforeEach(() => {
  Object.assign(f, {
    kinds: ["bookmarksBar"], sidebarWidth: 210, windowId: "first", actions: [], subscriptions: [], listeners: new Map(), cleanups: [],
    theme: { toolbarHover: "h", toolbarPressed: "p", textTab: "t", textTertiary: "q", icon: "i", divider: "d", accent: "a", dark: false },
    state: {
      settings: { hideBookmarksBarImport: false, tabLayout: "sidebar", bookmarksBar: "always" },
      windows: { first: { profileId: "one", sidebarOpen: true }, second: { profileId: "two" } },
      moveBookmark: (...args) => f.actions.push(["move", ...args]),
      bookmarks: {
        roots: { one: { bar: "bar", other: "other" }, two: { bar: "secondBar", other: "secondOther" } },
        nodes: { bar: folder("bar", ["a", "folder", "b"]), a: url("a"), b: url("b"), folder: folder("folder", ["child"]), child: url("child"), other: folder("other", ["child"]), secondBar: folder("secondBar", ["second"]), second: url("second"), secondOther: folder("secondOther", []) },
      },
    },
  });
});

test("the off leg retains the React bar and inactive panes reserve height without publishing", () => {
  f.kinds = [];
  const fallback = NativeBookmarksBar({ placeholder: true });
  assert.equal(fallback.type, "FallbackBar");
  assert.equal(fallback.props.placeholder, true);
  f.kinds = ["bookmarksBar"];
  const placeholder = NativeBookmarksBar({ placeholder: true });
  assert.equal(placeholder.type, "View");
  assert.deepEqual(placeholder.props.style, { height: 30 });
  assert.deepEqual(f.subscriptions, []);
});

test("hosted snapshots and action subscriptions retain their window and current profile", () => {
  const first = mount();
  f.windowId = "second";
  const second = mount();
  assert.equal(first.props.windowId, "first");
  assert.equal(second.props.windowId, "second");
  assert.deepEqual(JSON.parse(first.props.state).items.map((n) => n.id), ["a", "folder", "b"]);
  assert.deepEqual(JSON.parse(second.props.state).items.map((n) => n.id), ["second"]);
  assert.deepEqual(f.subscriptions, [["bookmarksBar", "first"], ["bookmarksBar", "second"]]);
  f.listeners.get("second")("press", { id: "second", metaKey: true, shiftKey: true, altKey: false, ctrlKey: true, middle: true });
  assert.deepEqual(f.actions, [["url", "https://second.example", "second", { metaKey: true, shiftKey: true, altKey: false, middle: true }]]);
  f.state.windows.first.profileId = "two";
  f.listeners.get("first")("press", { id: "a" });
  assert.equal(f.actions.length, 1);
  f.listeners.get("first")("menuChoice", { action: "manage" });
  assert.deepEqual(f.actions.at(-1), ["menuChoice", "first", "two", "manage", undefined]);
  f.cleanups.forEach((cleanup) => cleanup());
  assert.equal(f.listeners.size, 0);
});

test("native menu choices replace JS menu requests and retain nested bookmark identity", () => {
  mount();
  const event = f.listeners.get("first");
  for (const [name, payload] of [
    ["press", { id: "folder" }], ["contextMenu", { id: "a" }],
    ["overflowPress", { ids: ["a"] }], ["otherPress", {}], ["importContextMenu", {}],
  ]) event(name, payload);
  assert.deepEqual(f.actions, []);
  event("menuChoice", { action: "open", id: "child" });
  assert.deepEqual(f.actions.at(-1), ["menuChoice", "first", "one", "open", "child"]);
  event("menuChoice", { action: "bar", id: "newTab" });
  assert.deepEqual(f.actions.at(-1), ["menuChoice", "first", "one", "bar", "newTab"]);
  event("menuChoice", { action: "addPage", id: "a" });
  assert.deepEqual(f.actions.at(-1), ["menuChoice", "first", "one", "addPage", "a"]);
  event("importPress", {});
  assert.deepEqual(f.actions.at(-1), ["import"]);
});

test("events drawn for a previous profile cannot act on the newly selected profile", () => {
  mount();
  const event = f.listeners.get("first");
  f.state.windows.first.profileId = "two";
  for (const [name, payload] of [
    ["press", { id: "second" }],
    ["contextMenu", {}],
    ["overflowPress", { ids: ["second"] }],
    ["otherPress", {}],
    ["importPress", {}],
    ["importContextMenu", {}],
    ["menuChoice", { action: "delete", id: "second" }],
  ]) event(name, { ...payload, profileId: "one" });
  assert.deepEqual(f.actions, []);
  event("press", { id: "second", profileId: "two" });
  assert.equal(f.actions.at(-1)[1], "https://second.example");
});


test("sidebar boundaries follow the current window visibility, layout and live width", () => {
  assert.equal(JSON.parse(mount().props.state).sidebarEdge, 210);
  f.sidebarWidth = 84;
  assert.equal(JSON.parse(mount().props.state).sidebarEdge, 84);
  f.state.windows.first.sidebarOpen = false;
  assert.equal(JSON.parse(mount().props.state).sidebarEdge, null);
  f.state.windows.first.sidebarOpen = true;
  f.state.settings.tabLayout = "top";
  assert.equal(JSON.parse(mount().props.state).sidebarEdge, null);
  f.state.windows.first.tabLayout = "sidebar";
  assert.equal(JSON.parse(mount().props.state).sidebarEdge, 84);
});

test("drag events retain native adjusted indexes and reuse the JS bookmark writers", () => {
  mount();
  const event = f.listeners.get("first");
  event("move", { id: "a", index: 2, profileId: "one" });
  assert.deepEqual(f.actions.at(-1), ["move", "a", "bar", 2]);
  event("move", { id: "b", index: 0, profileId: "one" });
  assert.deepEqual(f.actions.at(-1), ["move", "b", "bar", 0]);
  event("move", { id: "a", into: "folder", profileId: "one" });
  assert.deepEqual(f.actions.at(-1), ["move", "a", "folder"]);
  event("folderToSidebar", { id: "folder", profileId: "one" });
  assert.deepEqual(f.actions.at(-1), ["sidebar", "folder", "first"]);
});

test("invalid, removed and stale drag sources and targets cannot write", () => {
  mount();
  const event = f.listeners.get("first");
  for (const payload of [
    { id: "missing", index: 0 },
    { id: "second", index: 0 },
    { id: "a", index: -1 },
    { id: "a", index: 3 },
    { id: "a", index: 1.5 },
    { id: "a", index: NaN },
    { id: "a", index: "1" },
    { id: "a", into: "a" },
    { id: "folder", into: "folder" },
    { id: "a", into: "secondBar" },
    { id: "a", into: "child" },
    { id: "a", into: 2, index: 0 },
  ]) event("move", payload);
  event("folderToSidebar", { id: "a" });
  event("folderToSidebar", { id: "secondBar" });
  f.state.bookmarks.nodes.bar.children = ["folder", "b"];
  event("move", { id: "a", index: 0 });
  f.state.windows.first.profileId = "two";
  event("move", { id: "second", index: 0, profileId: "one" });
  event("folderToSidebar", { id: "folder", profileId: "one" });
  assert.deepEqual(f.actions, []);
});

test("a removed window ignores hosted events", () => {
  mount();
  delete f.state.windows.first;
  const event = f.listeners.get("first");
  event("move", { id: "a", index: 0, profileId: "one" });
  event("press", { id: "a", profileId: "one" });
  assert.deepEqual(f.actions, []);
});

test("menu choices preserve colon-containing IDs and reject unrelated or removed bookmarks", () => {
  const id = "bookmark:with:colons";
  f.state.bookmarks.nodes[id] = url(id);
  f.state.bookmarks.nodes.other.children.push(id);
  mount();
  const event = f.listeners.get("first");
  event("menuChoice", { action: "edit", id, profileId: "one" });
  assert.deepEqual(f.actions, [["menuChoice", "first", "one", "edit", id]]);
  event("menuChoice", { action: "delete", id: "second", profileId: "one" });
  event("menuChoice", { action: "delete", id: "missing", profileId: "one" });
  delete f.state.bookmarks.nodes[id];
  event("menuChoice", { action: "addPage", id, profileId: "one" });
  assert.equal(f.actions.length, 1);
});
