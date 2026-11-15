import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const jsx = require("react/jsx-runtime");
const source = readFileSync(new URL("./FindBar.tsx", import.meta.url), "utf8");

function fixture() {
  const effects = [];
  const states = [];
  const refs = [];
  let index = 0;
  let refIndex = 0;
  const f = { effects, now: 1000, find: { open: true, query: "needle", count: 3, active: 2, focusRequest: 12 }, tabs: { a: { url: "https://find.test", windowId: "w" } }, replacement: { field: true, count: 2 } };
  const state = { tabs: f.tabs, setFind: (id, patch) => { effects.push(["setFind", id, patch]); Object.assign(f.find, patch); } };
  const useBrowser = Object.assign((select) => select(state), { getState: () => state });
  const theme = { dark: true, textPrimary: "ink", textSecondary: "dim", placeholder: "placeholder", selection: "selection", toolbarHover: "hover", toolbarPressed: "pressed", icon: "icon", iconDisabled: "disabled", rowHover: "row", panel: "panel", panelBorder: "border", panelShadowOpacity: 0.4 };
  const page = Object.fromEntries(["find", "stopFinding", "focus"].map((name) => [name, (...args) => effects.push([name, ...args])]));
  const modules = {
    react: { memo: (fn) => fn, useEffect: () => {}, useRef: (current) => { const slot = refIndex++; refs[slot] ??= { current }; return refs[slot]; }, useState: (initial) => { const slot = index++; if (!(slot in states)) states[slot] = initial; return [states[slot], (value) => { states[slot] = value; }]; } },
    "react/jsx-runtime": jsx,
    "react-native": { Animated: { Value: class { interpolate() { return "motion"; } }, View: "AnimatedView", timing: () => ({ start() {} }) }, Easing: { out: (value) => value, cubic: "cubic" }, View: "View", TextInput: "TextInput", Text: "Text", Pressable: "Pressable", StyleSheet: { absoluteFill: { position: "absolute" } }, findNodeHandle: () => 42 },
    "@solara/settings": { nativeToolbarAvailable: () => false, NativeFindBarView: "NativeFindBarView" },
    "@solara/shell": { Surface: "Surface", Symbol: "Symbol" },
    "../lib/commandShortcuts": { useShortcutHint: (command) => command === "findNext" ? "⌘G" : "⇧⌘G", withShortcut: (label, hint) => `${label} (${hint})` },
    "../lib/focusClaims": { findFocus: (id) => `find:${id}`, claimFocusTag: (windowId, destination, claim) => effects.push(["claim", windowId, destination, claim()]) },
    "../lib/theme": { useTheme: () => theme, hex: (value) => value },
    "../lib/webviews": { webviews: new Map([["a", page]]) },
    "../store/browser": { useBrowser },
    "../store/hooks": { useFind: () => f.find },
    "./primitives": { IconButton: "IconButton", useHover: () => ({ hovered: false, hoverProps: {} }) },
    "./site/selection": { replaceInField: async (...args) => { effects.push(["replace", ...args]); return f.replacement; } },
  };
  const exports = {};
  const { outputText } = ts.transpileModule(source, { fileName: "FindBar.tsx", compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } });
  new Function("require", "exports", "Date", outputText)((name) => modules[name] ?? {}, exports, { now: () => f.now });
  f.render = () => { index = 0; refIndex = 0; const panel = exports.FindBar({ tabId: "a" }); return panel && panel.type(panel.props); };
  f.native = () => {
    const visit = (node) => {
      if (!node || typeof node !== "object") return [];
      return [node, ...[node.props?.children].flat().flatMap(visit)];
    };
    const nodes = visit(f.render());
    assert.deepEqual(nodes.filter((node) => ["Text", "TextInput", "Pressable", "Symbol", "IconButton"].includes(node.type)), []);
    const native = nodes.find((node) => node.type === "NativeFindBarView");
    assert.ok(native, "find controls must be native even without toolbar capability");
    return native;
  };
  f.send = (event) => f.native().props.onFindEvent({ nativeEvent: event });
  return f;
}

test("find renders native controls without toolbar capability and keeps native state", () => {
  const f = fixture();
  const state = JSON.parse(f.native().props.state);
  assert.equal(state.query, "needle");
  assert.equal(state.count, 3);
  assert.equal(state.active, 2);
  assert.equal(state.focusRequest, 12);
  assert.equal(state.previousTooltip, "Previous (⇧⌘G)");
  assert.equal(state.nextTooltip, "Next (⌘G)");
  assert.equal(state.dark, true);
  assert.deepEqual(f.effects, []);
  f.find.count = 0;
  assert.equal(JSON.parse(f.native().props.state).count, 0);
  f.find.count = null;
  assert.equal(JSON.parse(f.native().props.state).count, null);
});

test("closed find and tabs without pages mount no controls", () => {
  const f = fixture();
  f.find.open = false;
  assert.equal(f.render(), null);
  f.find.open = true;
  f.tabs.a.url = "";
  assert.equal(f.render(), null);
});

test("native query and step events preserve find direction and next semantics", () => {
  const f = fixture();
  f.send({ kind: "query", text: "changed" });
  f.send({ kind: "step", backwards: true });
  f.send({ kind: "step", backwards: false });
  f.send({ kind: "query", text: "" });
  assert.deepEqual(f.effects, [["setFind", "a", { query: "changed" }], ["find", "changed", true, false], ["find", "changed", false, true], ["find", "changed", true, true], ["setFind", "a", { query: "" }], ["setFind", "a", { count: null, active: 0 }], ["find", "", true, false]]);
});

test("native focus claims its window and close returns focus to the page", () => {
  const f = fixture();
  f.send({ kind: "focused" });
  f.send({ kind: "close" });
  assert.deepEqual(f.effects, [["claim", "w", "find:a", 42], ["find", "needle", true, false], ["setFind", "a", { open: false, count: null, active: 0 }], ["stopFinding", false], ["focus"]]);
});

test("native replacement events retain replacement text and refresh results", async () => {
  const f = fixture();
  f.find.replace = true;
  f.send({ kind: "replacement", text: "replacement" });
  f.send({ kind: "replace", all: true });
  await Promise.resolve();
  assert.deepEqual(f.effects, [["replace", "a", "needle", "replacement", true], ["find", "needle", true, false]]);
  const state = JSON.parse(f.native().props.state);
  assert.equal(state.replace, true);
  assert.equal(state.note, "2 replaced");
  assert.equal(state.noteError, false);
});

test("find opened without a focus request autofocuses once and keeps later requests", () => {
  const f = fixture();
  delete f.find.focusRequest;
  const initial = JSON.parse(f.native().props.state).focusRequest;
  assert.equal(initial, 1000);
  f.now = 2000;
  f.find.count = 4;
  assert.equal(JSON.parse(f.native().props.state).focusRequest, initial);
  f.send({ kind: "query", text: "changed" });
  f.send({ kind: "step", backwards: false });
  assert.equal(JSON.parse(f.native().props.state).focusRequest, initial);
  f.find.focusRequest = 3000;
  assert.equal(JSON.parse(f.native().props.state).focusRequest, 3000);
});
