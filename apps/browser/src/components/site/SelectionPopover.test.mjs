import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./SelectionPopover.tsx", import.meta.url).href;
const f = globalThis.selectionPopoverTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `
    export const windowShellActive = () => globalThis.selectionPopoverTest.inShell;
    export const SolaraHostedView = "HostedView";
    export const onHostedEvent = (kind, windowId, fn) => {
      const f = globalThis.selectionPopoverTest;
      f.subscriptions.push([kind, windowId]); f.listener = fn;
      return () => { f.listener = null; };
    };`,
  "@solara/shell": `export const Surface = "Surface", Symbol = "Symbol", VisualEffect = "VisualEffect";`,
  react: `
    export const memo = (fn) => fn;
    export const useRef = (value) => ({ current: value });
    export const useState = (initial) => {
      const f = globalThis.selectionPopoverTest, index = f.index++;
      if (!(index in f.states)) f.states[index] = typeof initial === "function" ? initial() : initial;
      return [f.states[index], (value) => { f.states[index] = value; }];
    };
    export const useEffect = (fn) => globalThis.selectionPopoverTest.effects.push(fn);`,
  "react-native": `export const View = "View", StyleSheet = { absoluteFill: { position: "absolute" } }, Animated = {}, Easing = {}, Pressable = "Pressable", Text = "Text";`,
  "../../lib/theme": `export const useTheme = () => globalThis.selectionPopoverTest.theme; export const hex = (v) => v;`,
  "../../store/browser": `export const useBrowser = (fn) => fn(globalThis.selectionPopoverTest.store);`,
  "../../store/settings": `export const defaultSearchEngine = () => ({ name: "Local" });`,
  "../../store/hooks": `export const useWindowId = () => "little";`,
  "../primitives": `export const useHover = () => ({ hovered: false, hoverProps: {} });`,
  "../layout/nativePaneOverlays": `
    export const usePageFrame = () => ({ frame: [6, 44, 620, 400], ref: {}, onLayout() {} });
    export const useNativePaneOverlay = (...args) => globalThis.selectionPopoverTest.overlays.push(args);
    export const useNativePaneHandler = (...args) => globalThis.selectionPopoverTest.handlers.push(args);`,
  "./selection": `
    export const usePageSelection = (fn) => fn(globalThis.selectionPopoverTest.selections);
    export const setPageSelection = (...args) => globalThis.selectionPopoverTest.actions.push(["clear", ...args]);
    export const searchSelection = (...args) => globalThis.selectionPopoverTest.actions.push(["search", ...args]);`,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context);
  },
});
const { SelectionPopover } = await import("./SelectionPopover.tsx");
after(() => { hooks.deregister(); delete globalThis.selectionPopoverTest; });
const selection = { text: "a selected word", rect: { x: 20, y: 80, width: 40, height: 12 } };
const render = (props = {}) => {
  f.index = 0;
  return SelectionPopover({ tabId: "a", zoom: 2, ...props });
};
beforeEach(() => Object.assign(f, {
  inShell: false, index: 0, states: [], effects: [], actions: [], subscriptions: [], overlays: [], handlers: [],
  selections: { a: selection }, store: { settings: { showSelectionSearch: true } },
  theme: { dark: false, icon: "icon", textPrimary: "ink" }, listener: null,
}));

test("Little Solara hosts the native bar with zoomed selection geometry and its search label", () => {
  f.states = [false, selection];
  const host = render();
  assert.equal(host.props.kind, "selectionBar");
  assert.equal(host.props.windowId, "little");
  assert.deepEqual(JSON.parse(host.props.state), {
    tabId: "a", selection: { key: "20,80", top: 160, bottom: 184, center: 80, dark: false, icon: "icon", textPrimary: "ink", tooltip: "Search Local for “a selected word”", label: "Search Local" },
  });
  assert.equal(f.overlays[0][0], false);
});

test("the native search action keeps tab identity and modifier keys", () => {
  f.states = [false, selection];
  render();
  const cleanups = f.effects.map((effect) => effect()).filter((value) => typeof value === "function");
  assert.deepEqual(f.subscriptions, [["selectionBar", "little"]]);
  f.listener("search", { tabId: "other", metaKey: true });
  assert.deepEqual(f.actions, []);
  f.listener("search", { tabId: "a", metaKey: true, shiftKey: false, altKey: true });
  assert.deepEqual(f.actions, [["search", "a", selection.text, { metaKey: true, shiftKey: false, altKey: true }]]);
  cleanups.forEach((cleanup) => cleanup());
  assert.equal(f.listener, null);
  assert.deepEqual(f.actions.at(-1), ["clear", "a", null]);
});

test("the existing browser overlay receives the same geometry without a second native host", () => {
  f.inShell = true;
  f.states = [true, selection];
  const host = render();
  assert.equal(host.type, "View");
  assert.equal(f.overlays[0][0], true);
  assert.equal(f.overlays[0][4].top, 160);
  assert.deepEqual(f.overlays[0][4].frame, [6, 44, 620, 400]);
});

test("selection presentation retains the 150 millisecond delay and clears when selection disappears", (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  render();
  const cleanup = f.effects[0]();
  assert.equal(f.states[1], null);
  context.mock.timers.tick(149);
  assert.equal(f.states[1], null);
  context.mock.timers.tick(1);
  assert.deepEqual(f.states[1], selection);
  cleanup();
  f.selections = {};
  f.effects = [];
  render();
  f.effects[0]();
  assert.equal(f.states[1], null);
  assert.equal(render(), null);
});
