import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const jsx = require("react/jsx-runtime");
const root = new URL("../../../../../", import.meta.url);

function compile(path, modules) {
  const exports = {};
  const { outputText } = ts.transpileModule(readFileSync(new URL(path, root), "utf8"), {
    fileName: path,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  });
  new Function("require", "exports", outputText)((name) => modules[name] ?? {}, exports);
  return exports;
}

function fixture() {
  const effects = [];
  const state = { tabs: { a: { id: "a", profileId: "p", windowId: "w", zoom: 1.25 } }, history: { p: [] }, settings: {}, windows: {} };
  const f = { effects, state, shell: false, menu: { tabId: "a", direction: -1, items: [{ key: "one", title: "One", url: "https://one.test", offset: -1 }] } };
  const useBrowser = (select) => select(state);
  useBrowser.getState = () => state;
  const hooks = {
    memo: (fn) => fn, useEffect: () => {}, useMemo: (fn) => fn(), useCallback: (fn) => fn,
    useRef: (current) => ({ current }), useState: (value) => [typeof value === "function" ? value() : value, () => {}],
  };
  const page = { zoomStep: (step) => effects.push(["zoom", step]) };
  const theme = { dark: false, textPrimary: "ink", textSecondary: "dim", toolbarHover: "hover", toolbarPressed: "pressed", icon: "icon" };
  f.modules = {
    react: hooks,
    "react/jsx-runtime": jsx,
    "react-native": { View: "View", StyleSheet: { absoluteFill: {}, absoluteFillObject: {}, hairlineWidth: 0.5 }, Image: { resolveAssetSource: () => ({ uri: "mark" }) } },
    "zustand/react/shallow": { useShallow: (fn) => fn },
    "@solara/settings": { nativeToolbarAvailable: () => false, sidebarAddressBarAvailable: () => false, windowShellActive: () => f.shell, windowNativeLayout: () => false, NativePanelView: "NativePanelView" },
    "../../lib/theme": { useTheme: () => theme },
    "../lib/theme": { useTheme: () => theme },
    "../../lib/webviews": { webviews: new Map([["a", page]]) },
    "../../store/browser": { useBrowser },
    "../store/browser": { useBrowser },
    "../../store/hooks": { useTab: (id) => state.tabs[id], useWindowId: () => "w" },
    "./NativeToolbar": { NativeToolbar: "NativeToolbar" },
    "./NativeSiteControls": { NativeSiteControls: "NativeSiteControls", useNativeSiteControlsShown: (open) => ({ shown: open, onClosed: () => {} }) },
    "../primitives": { NEW_TAB_MARK: "mark" },
    "./controls": { PANEL: { inset: 16, iconSlot: 20 }, POPOVER_MARGIN: 8, Popover: "Popover" },
    "../layout/controls": { PANEL: {}, Popover: "Popover" },
    "../bookmarks/actions": {
      openModeFor: (e) => e.middle || e.metaKey ? (e.shiftKey ? "foreground" : "background") : e.altKey ? "split" : "current",
      openUrl: (...args) => effects.push(["url", ...args]),
    },
    "../pages/urls": { openInternalPage: (...args) => effects.push(["page", ...args]) },
    "./history": {
      useHistoryMenu: (select) => select({ menu: f.menu }), closeHistoryMenu: () => effects.push(["dismiss"]),
      goToHistoryItem: (id, item) => effects.push(["history", id, item.key]),
    },
    "./nativePaneOverlays": { usePageFrame: () => ({ frame: null, ref: {}, onLayout: () => {} }), useNativePaneOverlay: (...args) => effects.push(["overlay", ...args]), useNativePaneHandler: () => {} },
    "../layout/nativePaneOverlays": { usePageFrame: () => ({ frame: null, ref: {}, onLayout: () => {} }), useNativePaneOverlay: (...args) => effects.push(["overlay", ...args]) },
    "../layout/pageState": { setPopover: (...args) => effects.push(["popover", ...args]) },
  };
  return f;
}

test("toolbar and site panel keep their native controls when toolbar capability is unavailable", () => {
  const f = fixture();
  const { Toolbar } = compile("apps/browser/src/components/Toolbar.tsx", f.modules);
  const props = { tabId: "a", windowId: "w", geometry: {}, inSplit: false, focused: true };
  assert.equal(Toolbar(props).type, "NativeToolbar");
  const { SiteControls } = compile("apps/browser/src/components/site/SiteControls.tsx", f.modules);
  assert.equal(SiteControls({ tabId: "a", open: true, top: 8 }).type, "NativeSiteControls");
  assert.equal(SiteControls({ tabId: "a", open: false, top: 8 }), null);
});

test("inline zoom supplies theme and placement to the native lifecycle owner", () => {
  const f = fixture();
  const { ZoomPopover } = compile("apps/browser/src/components/site/ZoomHost.tsx", f.modules);
  const view = ZoomPopover({ tabId: "a", top: 8, right: 8 });
  assert.equal(view.type, "NativePanelView");
  assert.deepEqual(JSON.parse(view.props.state).popover, { width: 236, top: 8, left: null, right: 8 });
  f.effects.length = 0;
  assert.equal(view.props.onPanelEvent, undefined);
  assert.equal(JSON.parse(view.props.state).tabId, "a");
  assert.deepEqual(f.effects, []);
});

test("inline history forwards native modifier actions and keeps background opens visible", () => {
  const f = fixture();
  const { HistoryPopover } = compile("apps/browser/src/components/layout/HistoryPopover.tsx", f.modules);
  const element = HistoryPopover({ tabId: "a", windowId: "w", anchors: { back: 80, forward: 100 } });
  const view = element.type(element.props);
  assert.equal(view.type, "NativePanelView");
  assert.equal(JSON.parse(view.props.state).items[0].title, "One");
  f.effects.length = 0;
  view.props.onPanelEvent({ nativeEvent: { kind: "open", index: 0, metaKey: true } });
  assert.deepEqual(f.effects, [["url", "https://one.test", "w", "background"]]);
  f.effects.length = 0;
  view.props.onPanelEvent({ nativeEvent: { kind: "open", index: 0 } });
  assert.deepEqual(f.effects, [["dismiss"], ["history", "a", "one"]]);
  f.effects.length = 0;
  view.props.onPanelEvent({ nativeEvent: { kind: "fullHistory" } });
  assert.deepEqual(f.effects, [["dismiss"], ["page", "history", "w"]]);
  f.effects.length = 0;
  view.props.onPanelEvent({ nativeEvent: { kind: "dismiss" } });
  assert.deepEqual(f.effects, [["dismiss"]]);
});
