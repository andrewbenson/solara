import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const react = require("react");
const ts = require("typescript");

function fixture() {
  const mounts = [];
  const views = [];
  const errors = [];
  const renderer = {};
  const native = {
    UIManager: { createView: (tag, name, root, props) => views.push({ tag, props }), setChildren: (tag, children) => mounts.push({ tag, children }), manageChildren() {} },
    ReactNativeViewConfigRegistry: { get: () => ({ uiViewClassName: "RCTView", validAttributes: { pointerEvents: true, style: { position: true, top: true, right: true, bottom: true, left: true } } }) },
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
  let drawn = false;
  const modules = {
    react,
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View: "RCTView", StyleSheet: { absoluteFill: { position: "absolute", top: 0, right: 0, bottom: 0, left: 0 } } },
    "@solara/settings": { windowNativeLayoutGeneration: () => 7 },
    "expo-modules-core": { requireOptionalNativeModule: () => null },
    "../settings/nativeSettings": { addNativeSettingsHandlers() {} },
    "./paneFeed": { usePaneRootDrawn: () => drawn },
    "./nativePaneFallbackFeed": { NativePaneFallbackFeed: class {} },
    "react-native/Libraries/Renderer/shims/ReactNative": { default: renderer },
  };
  const exports = {};
  const source = readFileSync(new URL("./NativePaneFallback.tsx", import.meta.url), "utf8");
  const { outputText } = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } });
  new Function("require", "exports", outputText)((name) => modules[name] ?? require(name), exports);
  return {
    mounts, errors, views,
    draw: (value) => { drawn = value; },
    render: (target) => renderer.render(react.createElement(exports.NativePaneFallback, {
      windowId: "w", tabId: "c", target, children: react.createElement("RCTView"),
    }), 1, null, { onUncaughtError: (error) => errors.push(error) }),
  };
}

test("a refused pane mounts its fallback in the offered native container", () => {
  const f = fixture();
  f.render({ rootTag: 11, targetGeneration: 2, lease: 3, shown: true });
  assert.deepEqual(f.errors, []);
  const into = f.mounts.filter((mount) => mount.tag === 11);
  assert.equal(into.length, 1);
  assert.equal(into[0].children.length, 1);
  const mounted = into[0].children[0];
  const before = f.mounts.slice();
  assert.deepEqual(f.views.find((view) => view.tag === mounted).props, { pointerEvents: "box-none", position: "absolute", top: 0, right: 0, bottom: 0, left: 0 });
  f.render({ rootTag: 11, targetGeneration: 2, lease: 4, shown: true });
  assert.deepEqual(f.errors, []);
  assert.deepEqual(f.mounts, before);
});

test("hidden or already drawn panes mount no fallback controls", () => {
  const f = fixture();
  f.render({ rootTag: 11, targetGeneration: 2, lease: 3, shown: false });
  f.draw(true);
  f.render({ rootTag: 11, targetGeneration: 2, lease: 3, shown: true });
  assert.deepEqual(f.errors, []);
  assert.deepEqual(f.mounts, []);
});
