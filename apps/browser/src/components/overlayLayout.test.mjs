import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const react = require("react");
const ts = require("typescript");

async function fixture(kind) {
  const renders = {};
  const props = {};
  const errors = [];
  let onLayout;
  const leaf = (name) => (value) => {
    renders[name] = (renders[name] ?? 0) + 1;
    props[name] = value;
    return null;
  };
  const View = ({ children, onLayout: layout }) => {
    if (layout) {
      onLayout = layout;
    }
    return react.createElement("RCTView", null, children);
  };
  const state = { windows: { w: { sidebarOpen: true } }, settings: {}, downloads: [], ui: {}, profileOrder: ["default"] };
  const useBrowser = Object.assign((select) => select(state), { getState: () => state, subscribe: () => () => {} });
  const modules = {
    react,
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View, StyleSheet: { absoluteFill: {}, hairlineWidth: 0.5 } },
    "@solara/settings": { SolaraHostedView: leaf("SolaraHostedView"), windowShellActive: () => true },
    "../store/browser": { useBrowser },
    "../store/hooks": { useWindowId: () => "w", useSidebarOpen: () => true },
    "../../store/hooks": { useWindowId: () => "w" },
    "../store/sidebarRail": { sidebarWidthOf: () => 220, SIDEBAR_RAIL_WIDTH: 52 },
    "../lib/theme": { layout: { sidebarInset: 6 } },
    "./sidebar/sidebarShell": { nativeSidebarShell: () => true },
    "./sidebar/tokens": { useSidebarWidth: () => 220 },
    "./tokens": { useSidebarWidth: () => 220 },
    "./layout/windowLayout": { useTabLayout: () => "sidebar", useAddressBarInSidebar: () => false, SIDEBAR_FOOTER_DOWNLOADS: { bottom: 6, size: 34 } },
    "./profiles/ProfileDots": { useProfileDotsShown: () => false, PROFILE_DOTS_HEIGHT: 20 },
    "./layout/controls": { PANEL: { inset: 8, separatorGap: 4, rowHeight: 24 } },
    "./effects": { startSidebarEffects() {} },
  };
  for (const [path, name] of [
    ["./HoverCard", "HoverCard"], ["../live/MeetingAlert", "MeetingAlert"],
    ["./SearchTabs", "SearchTabs"], ["./TabSwitcher", "TabSwitcher"],
  ]) modules[path] = { [name]: leaf(name) };
  const NativeIconPicker = leaf("NativeIconPicker");
  modules["./IconPicker"] = { IconPicker: (value) => {
    leaf("IconPicker")(value);
    return react.createElement(NativeIconPicker, value);
  } };
  const exports = {};
  const source = readFileSync(new URL(kind === "sidebar" ? "./sidebar/Overlays.tsx" : "./Downloads.tsx", import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  new Function("require", "exports", code)((name) => modules[name] ?? {}, exports);
  const Component = kind === "sidebar" ? exports.SidebarOverlays : exports.DownloadMagnet;
  const previousHook = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__;
  globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    supportsFiber: true,
    inject: () => 1,
    onCommitFiberUnmount() {},
    onPostCommitFiberRoot() {},
    onCommitFiberRoot(_id, root) {
      const walk = (fiber) => {
        for (let current = fiber; current; current = current.sibling) {
          if (current.type === Component && (!current.alternate || current.flags & 1)) renders[Component.name] = (renders[Component.name] ?? 0) + 1;
          if (!current.alternate || current.child !== current.alternate.child) walk(current.child);
        }
      };
      walk(root.current);
    },
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
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  renderer.render(react.createElement(Component, { windowWidth: 1000 }), 1, null, { onUncaughtError: (error) => errors.push(error) });
  await settle();
  assert.deepEqual(errors, []);
  return {
    renders, props,
    async layout(width, height, x = 0, y = 0) {
      onLayout({ nativeEvent: { layout: { width, height, x, y } } });
      await settle();
      assert.deepEqual(errors, []);
    },
    stop() {
      renderer.unmountComponentAtNode(1);
      globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = previousHook;
    },
  };
}

for (const kind of ["sidebar", "download"]) {
  test(`${kind} overlay ignores repeated bounds and origin-only layouts`, async () => {
    const f = await fixture(kind);
    try {
      await f.layout(1000, 700);
      const before = { ...f.renders };
      for (const name of kind === "sidebar" ? ["SidebarOverlays", "HoverCard", "MeetingAlert", "IconPicker", "NativeIconPicker", "SearchTabs", "TabSwitcher"] : ["DownloadMagnet"]) assert.equal(before[name], 2);
      for (const [x, y] of [[0, 0], [12, 8], [0, 0]]) await f.layout(1000, 700, x, y);
      assert.deepEqual(f.renders, before);
      await f.layout(1024, 720);
      for (const [name, count] of Object.entries(before)) assert.equal(f.renders[name], count + 1);
      if (kind === "sidebar") {
        assert.equal(f.props.HoverCard.width, 1024);
        assert.equal(f.props.HoverCard.height, 720);
      }
    } finally { f.stop(); }
  });
}
