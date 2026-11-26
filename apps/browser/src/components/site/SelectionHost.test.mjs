import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./SelectionHost.tsx", import.meta.url).href;
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
const { SelectionHost } = await import("./SelectionHost.tsx");
after(() => { hooks.deregister(); delete globalThis.selectionPopoverTest; });
beforeEach(() => Object.assign(f, {
  inShell: false, index: 0, states: [], effects: [], actions: [], subscriptions: [], overlays: [], handlers: [],
  theme: { dark: false, icon: "icon", textPrimary: "ink" }, listener: null,
}));

test("Little Solara mounts a native selection lifetime with tab identity and theme", () => {
  const host = SelectionHost({ tabId: "a" });
  assert.equal(host.props.kind, "selectionBar");
  assert.equal(host.props.windowId, "little");
  assert.deepEqual(JSON.parse(host.props.state), { tabId: "a", dark: false, icon: "icon", textPrimary: "ink" });
  assert.deepEqual(f.subscriptions, []);
});

test("the browser overlay receives the page frame and native identity", () => {
  f.inShell = true;
  const host = SelectionHost({ tabId: "a" });
  assert.equal(host.type, "View");
  assert.deepEqual(f.overlays[0], [true, "little", "a", "selection", {
    tabId: "a", dark: false, icon: "icon", textPrimary: "ink", frame: [6, 44, 620, 400],
  }]);
  assert.deepEqual(f.handlers, []);
});
