import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const react = require("react");
const ts = require("typescript");

function load(path, modules) {
  const exports = {};
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  new Function("require", "exports", code)((name) => modules[name] ?? {}, exports);
  return exports;
}

test("opening and closing a native modal updates shell ownership without redrawing page guests", async () => {
  const listeners = new Set();
  const calls = [];
  const renders = {};
  const errors = [];
  let state = { windows: { w: {} }, windowUi: { w: { panel: { open: false } } } };
  const useBrowser = (select) => react.useSyncExternalStore((listener) => { listeners.add(listener); return () => listeners.delete(listener); }, () => select(state));
  const modules = {
    react,
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View: "RCTView", StyleSheet: { absoluteFill: {} } },
    "@solara/settings": { windowNativeLayout: () => true, windowShellActive: () => true, setWindowShellModal: (...args) => calls.push(args) },
    "../../store/browser": { useBrowser },
    "../onboarding/state": { useOnboarding: (select) => select({}) },
    "../profiles/CreateProfile": { useCreateProfileOpen: () => false },
    "./components/settings/windows": { isUtilityWindowId: () => false },
    "./store/browser": { useBrowser },
    "./store/hooks": { useWindowId: () => "w", useWindowProfileId: () => "default", WindowContext: react.createContext("w") },
    "./lib/theme": { ThemeScope: ({ children }) => children },
    "./components/layout/windowLayout": { useNativeWindowBounds: () => 800, useTabLayout: () => "sidebar", useAddressBarInSidebar: () => false },
    "./components/layout/nativeWindowAnchors": { useNativeWindowAnchors() {} },
  };
  modules["./components/layout/shellModal"] = load("./components/layout/shellModal.ts", modules);
  for (const [module, names] of [
    ["./components/CommandPanel", ["CommandPanel"]], ["./components/ContentCard", ["ContentCard"]],
    ["./components/Downloads", ["DownloadMagnet", "DownloadsPopover"]], ["./components/onboarding", ["OnboardingOverlay"]],
    ["./components/profiles/CreateProfile", ["CreateProfileHost"]], ["./components/layout/WindowProfile", ["WindowProfile"]],
    ["./components/sidebar/NativeSidebar", ["NativeSidebar"]],
    ["./components/layout/ShellBackdrop", ["ShellBackdrop"]], ["./components/sidebar/Overlays", ["SidebarOverlays"]],
  ]) modules[module] = Object.fromEntries(names.map((name) => [name, () => { renders[name] = (renders[name] ?? 0) + 1; return null; }]));
  const { WindowRoot } = load("./App.tsx", modules);
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
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  renderer.render(react.createElement(WindowRoot, { windowId: "w" }), 1, null, { onUncaughtError: (error) => errors.push(error) });
  await settle();
  try {
    assert.deepEqual(errors, []);
    assert.equal(renders.ContentCard, 1);
    assert.equal(renders.NativeSidebar, 1);
    for (const open of [true, false]) {
      state = { ...state, windowUi: { w: { panel: { open } } } };
      for (const listener of [...listeners]) listener();
      await settle();
      assert.deepEqual(errors, []);
      assert.equal(renders.ContentCard, 1);
      assert.equal(renders.NativeSidebar, 1);
    }
    assert.deepEqual(calls, [["w", "mainRoot", true], ["w", "mainRoot", false]]);
  } finally { renderer.unmountComponentAtNode(1); }
});
