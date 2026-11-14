import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");

function compile(file, modules) {
  const exports = {};
  const { outputText } = ts.transpileModule(readFileSync(new URL(file, import.meta.url), "utf8"), {
    fileName: file,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  });
  new Function("require", "exports", outputText)((name) => modules[name] ?? {}, exports);
  return exports;
}

function fixture() {
  const calls = [];
  const menus = [];
  let choice = null;
  const ext = { id: "fixture", name: "Fixture", pinned: true, enabled: true, hasAction: true, optionsUrl: "chrome-extension://fixture/options.html", sidePanel: "panel.html", mayModify: false };
  const state = { windows: { w: { profileId: "work" } }, tabs: { a: { windowId: "w" } }, newTab: (...args) => calls.push(["tab", ...args]) };
  const extensions = { lists: { work: [ext] }, sidePanels: {}, actions: {}, popup: null };
  const useBrowser = { getState: () => state, subscribe: () => () => {} };
  const useExtensions = (select) => select(extensions);
  useExtensions.getState = () => extensions;
  useExtensions.setState = (patch) => Object.assign(extensions, typeof patch === "function" ? patch(extensions) : patch);
  const modules = {
    "@solara/shell": { showMenu: async (items) => { menus.push(items); return choice; } },
    "@solara/solaracore": { configureExtension: async (...args) => calls.push(["configure", ...args]), setExtensionEnabled: async (...args) => calls.push(["enabled", ...args]), extensionActionStates: async () => ({ fixture: { popup: "chrome-extension://fixture/popup.html" } }) },
    "@solara/settings": { showNativeExtensionPopup: async (intent) => { calls.push(["popup", intent]); return true; }, closeNativeExtensionPopup: async () => {} },
    "../../lib/webviews": { webviews: new Map() },
    "../../store/peek": { shownPageId: () => "a" },
    "../layout/pageState": { tabForBrowser: () => "a" },
    "../../store/browser": { useBrowser },
    "../../store/model": { engineProfile: (id) => id },
    "./store": { useExtensions, windowExtensions: () => [ext], extensionProfile: () => "work", extensionsProfileId: () => "work", shownIn: () => true, browserIdOf: () => 1, pageProfile: () => "work" },
    "./sidePanels": { toggleSidePanel: (...args) => calls.push(["sidePanel", ...args]) },
    "../settings/windows": { openSettings: (...args) => calls.push(["settings", ...args]) },
  };
  const api = compile("./state.ts", modules);
  return { api, modules, calls, menus, ext, extensions, state, useExtensions, useBrowser, choose: (value) => { choice = value; } };
}

const settle = async () => { for (let n = 0; n < 6; n++) await Promise.resolve(); };

test("extension context menu preserves labels, option availability, side panel state and managed removal", async () => {
  const f = fixture();
  await f.api.showExtensionMenu("w", f.ext);
  assert.deepEqual(f.menus[0], [
    { id: "name", title: "Fixture", enabled: false }, { separator: true },
    { id: "options", title: "Options", enabled: true }, { id: "sidePanel", title: "Open Side Panel" },
    { id: "pin", title: "Unpin from Toolbar", symbol: "pin.slash" }, { id: "enable", title: "Turn Off" },
    { separator: true }, { id: "remove", title: "Remove Extension…", enabled: false }, { id: "manage", title: "Manage Extensions…" },
  ]);
  f.extensions.sidePanels.w = { extensionId: "fixture" };
  await f.api.showExtensionMenu("w", f.ext);
  assert.equal(f.menus[1].find((item) => item.id === "sidePanel").title, "Close Side Panel");
  await f.api.showExtensionMenu("w", { ...f.ext, enabled: false, pinned: false });
  const disabled = f.menus[2];
  assert.equal(disabled.find((item) => item.id === "options").enabled, false);
  assert.equal(disabled.find((item) => item.id === "sidePanel"), undefined);
  assert.equal(disabled.find((item) => item.id === "pin").title, "Pin to Toolbar");
  assert.equal(disabled.find((item) => item.id === "enable").title, "Turn On");
});

test("extension context menu dispatches options, pin, panel and cancellation to their adapters", async () => {
  const f = fixture();
  for (const choice of ["options", "pin", "sidePanel", "manage", null]) {
    f.choose(choice);
    await f.api.showExtensionMenu("w", f.ext);
    await settle();
  }
  assert.deepEqual(f.calls, [["tab", "w", { url: f.ext.optionsUrl }], ["configure", "fixture", "work", { pinned: false }], ["sidePanel", "w", "fixture"], ["settings", "extensions", "work"]]);
});

test("native toolbar overflow keeps extension order and routes selection with its tab anchor", async () => {
  const f = fixture();
  const anchor = { x: 90, y: 5, width: 28, height: 28 };
  const { useNativeToolbarExtensions } = compile("./ToolbarExtensions.tsx", {
    "@solara/shell": f.modules["@solara/shell"],
    react: { useMemo: (fn) => fn(), useRef: (current) => ({ current }), useEffect: () => {} },
    "../../lib/theme": { useTheme: () => ({}) },
    "../../store/browser": { useBrowser: f.useBrowser },
    "../media/cast": { useCastRoutes: () => [] },
    "../layout/pageState": { usePages: (select) => select({ browsers: { 1: "a" } }) },
    "./bridge": { setToolbarAnchor: () => {}, dropToolbarAnchor: () => {} },
    "./state": {
      useExtensions: f.useExtensions, useWindowExtensions: () => [f.ext], windowExtensions: () => [f.ext],
      activateExtension: (...args) => f.calls.push(["activate", ...args]), openPinDialog: (...args) => f.calls.push(["pins", ...args]),
      openManageExtensions: (...args) => f.calls.push(["manage", ...args]), openWebStore: (...args) => f.calls.push(["store", ...args]),
    },
  });
  const toolbar = useNativeToolbarExtensions("w", "a", 0);
  toolbar.onAnchors({ "*": [90, 5, 28, 28] });
  for (const choice of ["open:fixture", "pin", "manage", "add", null]) {
    f.choose(choice);
    toolbar.onClick("ext-overflow", "press");
    await settle();
  }
  assert.deepEqual(f.menus[0], [
    { id: "open:fixture", title: "Fixture", symbol: "pin.fill" }, { separator: true },
    { id: "pin", title: "Pin Extensions…", symbol: "pin" }, { id: "manage", title: "Manage Extensions…", symbol: "puzzlepiece.extension" },
    { id: "add", title: "Add Extension…", symbol: "plus" },
  ]);
  assert.deepEqual(f.calls, [["activate", "w", f.ext, anchor, undefined, "a"], ["pins", "w"], ["manage", "w"], ["store", "w"]]);
});


test("Little Solara toolbar and action.openPopup use the existing native popup intent", async () => {
  const f = fixture();
  f.state.windows.w.kind = "small";
  const anchor = { x: 90, y: 5, width: 28, height: 28 };
  const popup = "chrome-extension://fixture/popup.html";
  await f.api.activateExtension("w", f.ext, anchor, { popup }, "a");
  await f.api.openActionPopup("w", "fixture", anchor, 1);
  assert.deepEqual(f.calls, [
    ["popup", { extensionId: "fixture", popupUrl: popup, profile: "work", tabId: "a", windowId: "w", anchor, requiresActive: false }],
    ["popup", { extensionId: "fixture", popupUrl: popup, profile: "work", tabId: "a", windowId: "w", anchor, requiresActive: true }],
  ]);
});
