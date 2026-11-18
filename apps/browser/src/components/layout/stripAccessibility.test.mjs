import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const hover = () => ({ hovered: false, hoverProps: {} });
const react = {
  memo: (component) => component,
  createContext: (value) => ({ value }),
  useContext: (context) => context.value,
  useState: (initial) => [typeof initial === "function" ? initial() : initial, () => {}],
};

function load(path, modules, suffix = "") {
  const source = readFileSync(new URL(path, import.meta.url), "utf8") + suffix;
  const code = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  }).outputText;
  const exports = {};
  const common = {
    react,
    "react/jsx-runtime": require("react/jsx-runtime"),
    "react-native": { View: "View", Text: "Text", Pressable: "Pressable", StyleSheet: { absoluteFill: {} } },
  };
  new Function("require", "exports", "__DEV__", code)((name) => modules[name] ?? common[name] ?? {}, exports, false);
  return exports;
}

for (const [tab, title] of [
  [{ customTitle: "My tab", title: "Page", url: "https://example.com/" }, "My tab"],
  [{ title: "Page", url: "https://example.com/" }, "Page"],
  [{ url: "https://example.com/" }, "https://example.com/"],
  [{}, "New Tab"],
]) {
  for (const selected of [false, true]) {
    test(`strip tab announces ${title} with selected=${selected}`, () => {
      const { TabChip } = load("./TopTabStrip.tsx", {
        "@solara/shell": { ContextMenuArea: "ContextMenuArea" },
        zustand: { create: (initial) => (select) => select(initial()) },
        "../../store/hooks": {
          useWindowId: () => "w1",
          useTab: () => ({ id: "t1", ...tab }),
          useIsActiveTab: () => selected,
          useTabLive: () => false,
        },
        "../../lib/theme": { useTheme: () => ({ windowTint: ["#000000"] }) },
        "../primitives": { useHover: hover },
        "../sidebar/closeControl": { useTabCloseControl: () => ({}) },
        "./toolbarColors": { toolbarPalette: () => ({}), useEasedColor: () => null },
        "../site/developerMode": { useToolbarSiteColor: () => null },
        "./stripGroups": { dragGeometry: () => ({}) },
      }, "\nexport { TabChip };\n");
      const view = TabChip({ tabId: "t1", width: 120, dragged: false });
      const pressable = view.props.children.at(-1).props.children;
      assert.equal(pressable.type, "Pressable");
      assert.equal(pressable.props.accessible, true);
      assert.equal(pressable.props.accessibilityRole, "radio");
      assert.equal(pressable.props.accessibilityLabel, title);
      assert.deepEqual(pressable.props.accessibilityState, { selected });
    });
  }
}

for (const incognito of [false, true]) {
  test(`profile control announces its button name with incognito=${incognito}`, () => {
    const { ProfileIndicator } = load("../ProfileIndicator.tsx", {
      "../store/hooks": {
        useWindowId: () => "w1",
        useIsIncognito: () => incognito,
        useProfiles: () => [{}, {}],
        useWindowProfile: () => ({ name: "Personal" }),
      },
      "../lib/theme": { useTheme: () => ({}), profileNameColor: () => "#000000" },
      "./layout/measuredWidths": { useMeasuredWidth: () => 50 },
      "./primitives": { useHover: hover },
    });
    const pressable = ProfileIndicator({ room: 140 }).props.children[1];
    assert.equal(pressable.type, "Pressable");
    assert.equal(pressable.props.accessible, true);
    assert.equal(pressable.props.accessibilityRole, "button");
    assert.equal(pressable.props.accessibilityLabel, incognito ? "Incognito" : "Personal");
    assert.equal(pressable.props.disabled, incognito);
  });
}

for (const disabled of [false, true]) {
  test(`icon control announces its tooltip as a button with disabled=${disabled}`, () => {
    const { IconButton } = load("../primitives.tsx", {
      "../lib/theme": { useTheme: () => ({}) },
      "../lib/hoverShift": { markHoverProps: (props) => props },
    });
    const pressable = IconButton({ icon: "xmark", tooltip: "Close Group", disabled }).props.children;
    assert.equal(pressable.type, "Pressable");
    assert.equal(pressable.props.accessible, true);
    assert.equal(pressable.props.accessibilityRole, "button");
    assert.equal(pressable.props.accessibilityLabel, "Close Group");
    assert.equal(pressable.props.disabled, disabled);
  });
}
