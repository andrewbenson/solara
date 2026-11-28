import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const react = require("react");
const ts = require("typescript");

async function fixture() {
  const renders = {};
  const errors = [];
  const listeners = new Set();
  let state = { tabs: { a: { url: "https://one.invalid" } }, focused: "a", fullscreen: null, pages: {}, settings: {}, windows: { w: {} }, peeks: {} };
  const leaf = (name) => () => { renders[name] = (renders[name] ?? 0) + 1; return null; };
  const useStore = (select, same = Object.is) => {
    const selected = react.useRef();
    const read = () => {
      const next = select(state);
      if (!same(selected.current, next)) selected.current = next;
      return selected.current;
    };
    return react.useSyncExternalStore((listener) => { listeners.add(listener); return () => listeners.delete(listener); }, read);
  };
  const useBrowser = Object.assign(useStore, { getState: () => state });
  const View = ({ onLayout, children }) => {
    react.useLayoutEffect(() => onLayout?.({ nativeEvent: { layout: { width: 800 } } }), []);
    return react.createElement("RCTView", null, children);
  };
  const renderer = {};
  const native = {
    UIManager: { createView() {}, setChildren() {}, manageChildren() {}, updateView() {} },
    ReactNativeViewConfigRegistry: { get: () => ({ uiViewClassName: "RCTView", validAttributes: {} }) },
    RCTEventEmitter: { register() {} },
    ReactFiberErrorDialog: { showErrorDialog: () => false },
    deepFreezeAndThrowOnMutationInDev: (value) => value,
    createPublicInstance: (tag) => ({ tag }),
  };
  const rendererSource = readFileSync(require.resolve("react-native/Libraries/Renderer/implementations/ReactNativeRenderer-dev"), "utf8");
  new Function("require", "exports", "__DEV__", rendererSource)((name) => {
    if (name.endsWith("ReactNativePrivateInitializeCore")) return {};
    if (name.endsWith("ReactNativePrivateInterface")) return native;
    return require(name);
  }, renderer, true);
  const modules = {
    react,
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View, Animated: { View }, StyleSheet: { absoluteFill: {} } },
    "@solara/settings": { SolaraHostedView: leaf("CastHost"), tabPool: {}, windowNativeLayout: () => true, windowShellActive: () => false },
    "../lib/pagesPool": { panePromptsNativeIn: () => true },
    "../lib/engines": { useEngineOffers: () => null },
    "../store/browser": { useBrowser },
    "../store/tabWatch": { useTabValue: (tabId, select, same) => useStore((s) => select(s.tabs[tabId]), same), shallowEqual: (a, b) => !!a && !!b && Object.keys(a).length === Object.keys(b).length && Object.keys(a).every((key) => a[key] === b[key]) },
    "../store/hooks": { useActiveTabId: () => useStore((s) => s.focused) },
    "../store/splits": { splitOf: () => null },
    "../store/small": { isSmallWindow: () => false },
    "./layout/pageState": { useFullscreenTab: () => useStore((s) => s.fullscreen), usePages: (select) => useStore(select), patchPage() {} },
    "./layout/windowLayout": { useTabLayout: () => "sidebar", useAddressBarInSidebar: () => false },
    "./layout/geometry": { NO_TOOLBAR: {}, toolbarGeometry: () => ({ urlLeft: 100 }) },
    "./layout/paneFeed": { usePaneStatusStyle() {}, usePopoversOverCard() {}, markPaneRootDrawn() {} },
    "./layout/nativePaneOverlays": { useNativePaneHint() {}, useNativePanePopups() {}, useNativePanePromptsPane() {} },
    "./layout/controls": { POPOVER_MARGIN: 8 },
  };
  state.popover = {};
  for (const [module, names] of [
    ["./PooledPageProps", ["PooledPageProps"]], ["./media/ShareBar", ["ShareBar"]],
    ["./NewTabPage", ["NewTabPage"]], ["./EmptyCard", ["EmptyCard"]], ["./FindBar", ["FindBar"]],
    ["./layout/PaneOverlays", ["StatusBubble", "SadTab"]], ["./site/SitePanelHost", ["SiteControls"]],
    ["./media/SharePicker", ["SharePicker"]], ["./layout/SwipeOverlay", ["NavigationOverlays"]],
  ]) modules[module] = Object.fromEntries(names.map((name) => [name, leaf(name)]));
  const exports = {};
  const source = readFileSync(new URL("./PaneContent.tsx", import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  new Function("require", "exports", code)((name) => modules[name] ?? {}, exports);
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  const render = async (shown = true) => {
    renderer.render(react.createElement(exports.PaneContent, { windowId: "w", tabId: "a", shown }), 1, null, { onUncaughtError: (error) => errors.push(error) });
    await settle();
    assert.deepEqual(errors, []);
  };
  const update = async (patch) => {
    state = { ...state, ...patch };
    for (const listener of [...listeners]) listener();
    await settle();
    assert.deepEqual(errors, []);
  };
  await render();
  return { renders, render, update, stop: () => renderer.unmountComponentAtNode(1) };
}

test("navigation updates the native page guest without redrawing sibling overlays", async () => {
  const f = await fixture();
  try {
    const overlays = ["StatusBubble", "SiteControls", "SharePicker", "CastHost"];
    const before = Object.fromEntries(overlays.map((name) => [name, f.renders[name]]));
    for (const count of Object.values(before)) assert.ok(count > 0);
    await f.update({ tabs: { a: { url: "https://two.invalid" } } });
    assert.deepEqual(Object.fromEntries(overlays.map((name) => [name, f.renders[name]])), before);
    await f.update({ tabs: { a: { url: "" } } });
    assert.equal(f.renders.NewTabPage, 1);
  } finally { f.stop(); }
});

test("focus and layout parent renders do not redraw unchanged native page guests", async () => {
  const f = await fixture();
  try {
    const guests = ["PooledPageProps", "ShareBar"];
    const before = Object.fromEntries(guests.map((name) => [name, f.renders[name]]));
    for (const count of Object.values(before)) assert.ok(count > 0);
    await f.update({ focused: "b" });
    await f.render();
    assert.deepEqual(Object.fromEntries(guests.map((name) => [name, f.renders[name]])), before);
    await f.update({ fullscreen: "a" });
    assert.equal(f.renders.PooledPageProps, before.PooledPageProps + 1);
    assert.equal(f.renders.ShareBar, before.ShareBar);
    await f.update({ fullscreen: null });
    assert.equal(f.renders.ShareBar, before.ShareBar + 1);
  } finally { f.stop(); }
});
