import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const jsx = require("react/jsx-runtime");

function compile(file, modules) {
  const exports = {};
  const { outputText } = ts.transpileModule(readFileSync(new URL(file, import.meta.url), "utf8"), {
    fileName: file,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  });
  new Function("require", "exports", outputText)((name) => modules[name] ?? {}, exports);
  return exports;
}

function strip({ width = 1000, nameWidth = 34, shown = true, fullscreen = false, floating = false, controls = true } = {}) {
  const modules = {
    react: { createContext: () => ({ Provider: "Provider" }), useEffect: () => {} },
    "react/jsx-runtime": jsx,
    "react-native": { View: "View", StyleSheet: { absoluteFill: {} } },
    zustand: { create: () => () => null },
    "../../lib/theme": { layout: { trafficLightsWidth: 78 } },
    "../../store/browser": { useBrowser: (select) => select({ windows: { w: { fullScreen: fullscreen ? 1 : undefined } } }) },
    "../../store/hooks": { useWindowId: () => "w", useWindowProfileId: () => "p" },
    "../ProfileIndicator": {
      ProfileIndicator: "ProfileIndicator", ProfileNameMeasure: "ProfileNameMeasure", useProfileTitle: () => "Work",
      useProfileIndicatorWidth: (room) => shown ? Math.min(room, nameWidth + 18) : 0,
    },
    "../Downloads": { DownloadsButton: "DownloadsButton" },
    "./profilePager": { usePagerPages: () => ({ pages: [] }) },
    "./measuredWidths": { useMeasuredWidth: () => undefined },
    "./NativeStripControls": { NativeStripControls: "NativeStripControls", NativeStripDropGlow: "NativeStripDropGlow", nativeStripControlsEnabled: () => controls },
    "./NativeTopStrip": { NativeTopStrip: "NativeTopStrip", nativeTopStripEnabled: () => true },
    "./stripGroups": { dragGeometry: () => ({ slots: [], lefts: [] }) },
  };
  const { TopTabStrip } = compile("./TopTabStrip.tsx", modules);
  const tree = TopTabStrip({ width, floating, swipe: false });
  const children = tree.props.children.props.children;
  const viewport = children[1];
  return { viewport: viewport.props, controls: children[2].props.children, page: viewport.props.children.props };
}

test("windowed profile sits after the lights and reserves an island-wide slot before tabs", () => {
  for (const nameWidth of [8, 34]) {
    const view = strip({ nameWidth });
    assert.equal(view.controls[1].props.leadingInset, 86);
    assert.equal(view.viewport.style.left, 155);
    assert.equal(view.page.pageWidth, 746);
    assert.equal(view.controls[1].props.style.right, 8);
    assert.equal(view.viewport.style.right, 69);
  }
});

test("full-screen and floating profile slots protect the first tab from the island", () => {
  for (const state of [{ fullscreen: true }, { floating: true }]) {
    const view = strip({ ...state, nameWidth: 8 });
    assert.equal(view.controls[1].props.leadingInset, 8);
    assert.equal(view.page.pageWidth, 824);
    assert.equal(view.viewport.style.left, state.floating ? 92 : 77);
  }
});

test("hidden profile names reserve no slot", () => {
  const windowed = strip({ shown: false });
  assert.equal(windowed.viewport.style.left, 71);
  assert.equal(windowed.page.pageWidth, 830);
  const fullscreen = strip({ shown: false, fullscreen: true });
  assert.equal(fullscreen.viewport.style.left, -7);
  assert.equal(fullscreen.page.pageWidth, 908);
});

test("long names yield room before a tab reaches its 96 point minimum", () => {
  const native = strip({ width: 360, nameWidth: 300 });
  assert.equal(native.viewport.style.left, 165);
  assert.equal(native.page.pageWidth, 96);
  const fallback = strip({ width: 360, nameWidth: 300, controls: false });
  assert.equal(fallback.controls[0].props.style.left, 86);
  assert.equal(fallback.controls[0].props.children.props.room, 86);
  assert.equal(fallback.controls[1].props.style.right, 8);
});

test("native controls forward their leading position and pass through the tabs", () => {
  const { NativeStripControls } = compile("./NativeStripControls.tsx", {
    react: { memo: (fn) => fn, useEffect: () => {}, useMemo: (fn) => fn(), useRef: () => ({ current: null }) },
    "react/jsx-runtime": jsx,
    "react-native": { View: "View" },
    "@solara/settings": { SolaraHostedView: "SolaraHostedView" },
    "../../lib/theme": { useTheme: () => ({ dark: false }), profileNameColor: () => "#000000" },
    "../../lib/commandShortcuts": { useShortcutHint: () => "", withShortcut: (label) => label },
    "../../store/hooks": { useIsIncognito: () => false, useProfiles: () => [{}, {}], useWindowProfile: () => ({ name: "Work" }) },
    "../../store/browser": { useBrowser: (select) => select({ windowUi: {} }) },
  });
  const view = NativeStripControls({ windowId: "w", indicator: true, leadingInset: 86, style: { left: 0, right: 8 } });
  assert.equal(view.props.pointerEvents, "box-none");
  assert.equal(JSON.parse(view.props.children.props.state).leadingInset, 86);
});
