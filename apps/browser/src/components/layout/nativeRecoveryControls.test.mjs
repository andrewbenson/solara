import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");
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
  const listeners = [];
  const replies = [];
  const state = {
    tabs: {}, windows: {}, live: {}, settings: { showSidebarButton: true }, ui: { focusedWindowId: "w" },
    toggleSidebar: (id) => effects.push(["sidebar", id]), openPanel: (...args) => effects.push(["search", ...args]),
    updateSettings: (patch) => { effects.push(["settings", patch]); Object.assign(state.settings, patch); },
    updateTab: (id, patch) => { effects.push(["tab", id, patch]); Object.assign(state.tabs[id], patch); },
  };
  const useBrowser = (select) => select(state);
  useBrowser.getState = () => state;
  const native = {
    available: () => false,
    addListener: (name, listener) => { listeners.push({ name, listener }); return { remove() {} }; },
    reply: async (id, result, error) => { replies.push({ id, result, error }); },
    publish: async () => { effects.push(["publish"]); },
  };
  const settings = compile("packages/settings/src/index.ts", { "expo-modules-core": { requireOptionalNativeModule: () => native } });
  const registration = compile("apps/browser/src/components/settings/nativeSettings.ts", { "@solara/settings": settings });
  const modules = {
    "@solara/settings": { ...settings, NativeSidebarAddressBarView: "NativeSidebarAddressBarView", setSidebarAddressBar: () => {} },
    react: { useEffect: (fn) => fn(), useMemo: (fn) => fn(), useState: (value) => [value, () => {}], useRef: (current) => ({ current }) },
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { StyleSheet: { absoluteFill: {} } },
    "../../lib/theme": { layout: { sidebarInset: 10 }, useTheme: () => ({}) },
    "../../lib/commandShortcuts": { useShortcutHint: () => "", withShortcut: (value) => value },
    "../../store/browser": { useBrowser },
    "../../store/hooks": { useWindowId: () => "w", useActiveTabId: () => null },
    "../extensions/ToolbarExtensionHost": { extensionsFitting: () => 4 },
    "../layout/toolbarColors": { toolbarPalette: () => ({}) },
    "../layout/windowLayout": {
      useNativeWindowPreferences: () => null,
      useWindowReplicaFallback: () => null,
      useAddressBarInSidebar: () => true,
      setUrlAnchor: (...args) => effects.push(["anchor", ...args]),
    },
    "../Toolbar": { GLYPH: 13 },
    "../NativeToolbar": { useNativeToolbarModel: () => ({ tab: null, state: null, onClick: (click) => effects.push(["click", click.id]), onAnchors: (anchors) => effects.push(["extensions", anchors]) }) },
    "../settings/nativeSettings": registration,
  };
  return { registration, modules, state, effects, listeners, replies };
}

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

test("refused native settings keeps the actual Settings callback bridge for native sidebar controls", async () => {
  const f = fixture();
  const { SidebarHeaderTools } = compile("apps/browser/src/components/sidebar/AddressBar.tsx", f.modules);
  assert.equal(SidebarHeaderTools({ width: 240 }).type, "NativeSidebarAddressBarView");
  assert.equal(f.registration.startNativeSettings(), false);
  assert.equal(f.registration.startNativeSettings(), false);
  assert.equal(f.listeners.length, 1);
  assert.equal(f.listeners[0].name, "onSettingsCall");
  const send = async (id, name, args) => {
    f.listeners[0].listener({ id, name, args: JSON.stringify(args) });
    await flush();
    assert.equal(f.replies.at(-1).error, null);
  };
  await send(1, "sidebar.addressClick", ["w", { id: "sidebar", kind: "press" }]);
  await send(2, "sidebar.addressClick", ["w", { id: "url", kind: "press" }]);
  await send(3, "sidebar.addressClick", ["w", { id: "back", kind: "press" }]);
  await send(4, "sidebar.addressAnchors", ["w", { field: [12, 30, 200, 28], "ext:x": [100, 30, 28, 28] }]);
  assert.deepEqual(f.effects, [["sidebar", "w"], ["search", "w", ""], ["click", "back"], ["anchor", "w", { left: 12, top: 30, width: 200, sidebar: { height: 28 } }], ["extensions", { "ext:x": [100, 30, 28, 28] }]]);
});

async function siteFixture() {
  const f = fixture();
  const model = await import("../../store/model.ts");
  const engines = await import("../../store/engines.ts");
  f.state.windows.w = { profileId: "work" };
  f.state.tabs.a = { id: "a", windowId: "w", profileId: "work", url: "https://tv.apple.com/watch", title: "Temporary page", customTitle: null, favicon: "https://tv.apple.com/icon", muted: true, zoom: 1.5 };
  Object.assign(f.state.settings, { developerMode: { work: { on: ["tv.apple.com"], off: [], reload: "reload" } }, sleepInactiveTabs: true, keepAwakeSites: ["other.test"], showFullUrl: true, protectedVideoInWebKit: true, pageEngine: "chromium", websiteEngines: {} });
  Object.assign(f.modules, {
    "@solara/settings": { ...f.modules["@solara/settings"], NativeSitePanelView: "NativeSitePanelView" },
    "@solara/shell": { translation: false },
    "zustand/react/shallow": { useShallow: (fn) => fn },
    "../../store/model": model,
    "../../lib/webviews": { webviewMount: () => null },
    "../../store/nativeStore": { nativeOwnsWorkspace: () => false },
    "../overlayGates": { siteControlsMounted: (open, latched) => open || latched },
    "../../store/engines": engines,
    "../omnibox/nativeBar": { useThemeTokens: () => ({}) },
    "../layout/pageState": { usePage: (id, select) => select({ security: null, blocked: 0, mediaAccess: null }) },
    "../media/state": { useMedia: (select) => select({ sessions: {}, pipOpen: {} }) },
    "./translate": { isNeverTranslated: () => false, useTranslateState: () => ({ status: "idle" }) },
  });
  const site = compile("apps/browser/src/components/site/SitePanelHost.tsx", f.modules);
  return { ...f, site };
}

test("site panel supplies the refused-session workspace to its native renderer", async () => {
  const f = await siteFixture();
  const panel = f.site.SiteControls({ tabId: "a", open: true, top: 8, right: 8, onClosed() {} });
  const { fallbackContext } = JSON.parse(panel.props.request);
  assert.deepEqual(fallbackContext, {
    tabId: "a", windowId: "w", url: "https://tv.apple.com/watch", title: "Temporary page", customTitle: null, label: "tv.apple.com", favicon: "https://tv.apple.com/icon",
    profileId: "work", profile: "work", privatePage: false, navigationSeq: null, mount: null, pageEngine: "webkit", muted: true, playingAudio: false, zoom: 1.5,
    showFullUrl: true, developerMode: f.state.settings.developerMode, sleepInactiveTabs: true, keepAwakeSites: ["other.test"], engineRule: null, streamingSite: true, recommendedEngine: "webkit",
  });
});

test("refused-session native site setting and sound callbacks update only their current page", async () => {
  const f = await siteFixture();
  f.registration.startNativeSettings();
  const send = async (id, name, args) => {
    f.listeners[0].listener({ id, name, args: JSON.stringify(args) });
    await flush();
    assert.equal(f.replies.at(-1).error, null);
  };
  const source = { url: f.state.tabs.a.url, windowId: "w", profileId: "work", navigationSeq: null };
  const developerMode = { work: { on: [], off: [], reload: "reload" } };
  for (const [id, patch] of [[1, { showFullUrl: false }], [2, { developerMode }], [3, { keepAwakeSites: ["tv.apple.com"] }]]) await send(id, "site.settings", ["a", source, patch]);
  await send(4, "site.muted", ["a", source, false]);
  assert.deepEqual(f.effects, [["settings", { showFullUrl: false }], ["settings", { developerMode }], ["settings", { keepAwakeSites: ["tv.apple.com"] }], ["tab", "a", { muted: false }]]);
  f.effects.length = 0;
  f.state.tabs.a.url = "https://new.test";
  await send(5, "site.settings", ["a", source, { showFullUrl: true }]);
  await send(6, "site.muted", ["a", source, true]);
  await send(7, "site.settings", ["missing", source, { showFullUrl: true }]);
  assert.deepEqual(f.effects, []);
});
