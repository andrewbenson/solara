import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { dropNativeMeasuredWidth, setMeasuredWidth, useWidths } from "./layout/measuredWidths.ts";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL("./ProfileIndicator.tsx", import.meta.url), "utf8");
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
}).outputText;

function component(nativeLayout, anchorsAvailable) {
  const modules = {
    "@solara/settings": { windowNativeLayout: () => nativeLayout, windowLayoutAnchorsAvailable: () => anchorsAvailable },
    react: { useState: (initial) => [initial()] },
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View: "View", Text: "Text", Pressable: "Pressable" },
    "./primitives": { useHover: () => ({ hovered: false, hoverProps: {} }) },
    "../store/hooks": {
      useWindowId: () => "w",
      useIsIncognito: () => false,
      useProfiles: () => [{ name: "Personal" }, { name: "Work" }],
      useWindowProfile: () => ({ name: "Work" }),
    },
    "../lib/theme": { useTheme: () => ({ dark: false }), profileNameColor: () => "#000000" },
    "./layout/measuredWidths": { setMeasuredWidth, useMeasuredWidth: (key) => useWidths.getState()[key] },
  };
  const exports = {};
  new Function("require", "exports", code)((name) => modules[name] ?? {}, exports);
  return exports;
}

for (const [name, nativeLayout, anchorsAvailable] of [
  ["legacy layout with native anchor capability", false, true],
  ["legacy layout without native anchors", false, false],
  ["native layout without native anchors", true, false],
]) {
  test(`${name} measures the profile before reserving the trailing controls`, () => {
    dropNativeMeasuredWidth("profile-name|Work");
    try {
      const view = component(nativeLayout, anchorsAvailable);
      assert.equal(view.useProfileIndicatorWidth(140), 32);
      const measurement = view.ProfileNameMeasure({ title: "Work" });
      assert.ok(measurement, "React must measure when no native layout reader supplies the name width");
      const label = measurement.props.children;
      assert.equal(label.props.children, "Work");
      label.props.onLayout({ nativeEvent: { layout: { width: 33.4 } } });
      assert.equal(view.useProfileIndicatorWidth(140), 52, "the strip reserves the measured label plus its padding");
    } finally {
      dropNativeMeasuredWidth("profile-name|Work");
    }
  });
}

test("native layout with native anchors leaves profile measurement to its reader", () => {
  assert.equal(component(true, true).ProfileNameMeasure({ title: "Work" }), null);
});

for (const [captionAligned, marginTop] of [[false, 0.5], [true, 0]]) {
  test(`profile indicator uses ${marginTop} pt inset with caption alignment ${captionAligned}`, () => {
    setMeasuredWidth("profile-name|Work", 34);
    try {
      const view = component(false, false).ProfileIndicator({ room: 140, captionAligned });
      assert.equal(view.props.style.marginTop, marginTop);
    } finally {
      dropNativeMeasuredWidth("profile-name|Work");
    }
  });
}
