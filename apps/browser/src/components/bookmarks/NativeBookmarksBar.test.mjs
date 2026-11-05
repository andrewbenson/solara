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
    kinds: ["bookmarksBar"], windowId: "first", actions: [], subscriptions: [], listeners: new Map(), cleanups: [],
    theme: { toolbarHover: "h", toolbarPressed: "p", textTab: "t", textTertiary: "q", icon: "i", divider: "d", dark: false },
    state: {
      settings: { hideBookmarksBarImport: false },
      windows: { first: { profileId: "one" }, second: { profileId: "two" } },
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
  f.listeners.get("first")("contextMenu", {});
  assert.deepEqual(f.actions.at(-1), ["context", "first", "two", null]);
  f.cleanups.forEach((cleanup) => cleanup());
  assert.equal(f.listeners.size, 0);
});

test("folder, overflow, Other Bookmarks and import events reuse the existing actions", () => {
  mount();
  const event = f.listeners.get("first");
  event("press", { id: "folder" });
  assert.deepEqual(f.actions.at(-1), ["folder", "first", ["child"], undefined, "folder"]);
  event("contextMenu", { id: "a" });
  assert.deepEqual(f.actions.at(-1), ["context", "first", "one", f.state.bookmarks.nodes.a]);
  event("overflowPress", { ids: ["b", "second", "a", 5] });
  assert.deepEqual(f.actions.at(-1), ["folder", "first", ["a", "b"]]);
  event("otherPress", {});
  assert.deepEqual(f.actions.at(-1), ["folder", "first", ["child"], undefined, "other"]);
  event("importPress", {});
  assert.deepEqual(f.actions.at(-1), ["import"]);
  event("importContextMenu", {});
  assert.deepEqual(f.actions.at(-1), ["importMenu"]);
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
  ]) event(name, { ...payload, profileId: "one" });
  assert.deepEqual(f.actions, []);
  event("press", { id: "second", profileId: "two" });
  assert.equal(f.actions.at(-1)[1], "https://second.example");
});
