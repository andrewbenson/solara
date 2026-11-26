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

test("a dispatched extension menu action keeps its logical and engine profile across the JS bridge", () => {
  const f = fixture();
  let engine = "shared";
  const handlers = compile("../settings/native/extensions.ts", {
    "../../../store/browser": { useBrowser: f.useBrowser },
    "../../extensions/state": {
      extensionProfile: () => engine,
      toggleSidePanel: (...args) => f.calls.push(["panel", ...args]),
    },
    "../../extensions/bridge": { openExtensionFromMenu: (...args) => f.calls.push(["open", ...args]) },
  }).extensionsHandlers;
  const select = () => {
    handlers["extensions.activate"]("w", "fixture", "a", null, "work", "shared");
    handlers["extensions.togglePanel"]("w", "fixture", "work", "shared");
  };
  f.state.windows.w.profileId = "personal";
  select();
  f.state.windows.w.profileId = "work";
  engine = "different";
  select();
  assert.deepEqual(f.calls, []);
  engine = "shared";
  select();
  assert.deepEqual(f.calls, [["open", "w", "fixture", "a"], ["panel", "w", "fixture"]]);
});
