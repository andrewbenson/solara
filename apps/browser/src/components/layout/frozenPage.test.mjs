import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./frozenPage.tsx", import.meta.url).href;
const f = globalThis.frozenPageHostTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `
    export const SolaraHostedView = "HostedView";
    export const publishSettingsTopic = async () => {};
    export const windowNativeLayoutGeneration = () => 1;
    export const onHostedEvent = (kind, windowId, listener) => {
      const f = globalThis.frozenPageHostTest;
      f.subscription = [kind, windowId]; f.listener = listener;
      return () => { f.listener = null; };
    };`,
  react: `
    export const useRef = (value) => {
      const f = globalThis.frozenPageHostTest, index = f.index++;
      return f.refs[index] ??= { current: value };
    };
    export const useLayoutEffect = (fn) => { const f = globalThis.frozenPageHostTest; if (!f.mounted) { f.cleanups.push(fn()); f.mounted = true; } };
    export const useEffect = () => {};
    export const useMemo = (fn) => fn();`,
  "react-native": `export const StyleSheet = { absoluteFill: { position: "absolute" } }, Image = "Image", Pressable = "Pressable", View = "View";`,
  "../../lib/theme": `export const useTheme = () => ({ dark: globalThis.frozenPageHostTest.dark });`,
  "../../store/browser": `
    const f = globalThis.frozenPageHostTest;
    export const useBrowser = (fn) => fn(f.store);
    useBrowser.getState = () => f.store;`,
  "../../store/pinShare": `export const holderOf = (state, copyId) => state.tabs[state.tabs[copyId]?.pageIn];`,
  "./pinHandoff": `
    const f = globalThis.frozenPageHostTest;
    export const useFrozenPages = (fn) => fn(f.frozen);
    useFrozenPages.getState = () => f.frozen;
    export const startPinHandoff = () => {};
    export const notePainted = (windowId) => f.actions.push(["painted", windowId]);`,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context);
  },
});
const { FrozenPage } = await import("./frozenPage.tsx");
after(() => { hooks.deregister(); delete globalThis.frozenPageHostTest; });
const render = (props = {}) => {
  f.index = 0;
  const host = FrozenPage({ windowId: "w", tabId: "copy", top: 42, ...props });
  if (host?.props.state) f.state = JSON.parse(host.props.state);
  return host;
};
const event = (name, state = f.state) => f.listener(name, { token: state.token, copyId: state.copyId });
beforeEach(() => Object.assign(f, {
  refs: [], index: 0, mounted: false, cleanups: [], dark: false, actions: [], listener: null,
  store: { tabs: { copy: { windowId: "w", pageIn: "holder" } }, activate: (id) => f.actions.push(["activate", id]) },
  frozen: { frames: { copy: "data:image/jpeg;base64,AA==" }, bridges: {} },
}));

test("frozen snapshots are hosted natively with the original page inset and appearance", () => {
  const host = render();
  assert.equal(host.props.kind, "frozenPage");
  assert.equal(host.props.windowId, "w");
  assert.deepEqual(host.props.style, [{ position: "absolute" }, { top: 42 }]);
  assert.deepEqual({ ...f.state, token: 0 }, { token: 0, tabId: "copy", copyId: "copy", uri: f.frozen.frames.copy, dark: false });
  assert.deepEqual(f.subscription, ["frozenPage", "w"]);
  assert.equal(typeof f.listener, "function");
  event("painted");
  event("press");
  assert.deepEqual(f.actions, [["painted", "w"], ["activate", "copy"]]);
  f.dark = true;
  assert.equal(JSON.parse(render().props.state).dark, true);
});

test("a bridge acknowledges its current image and never activates the page behind it", () => {
  f.store.tabs.copy.pageIn = null;
  f.frozen.bridges.w = { copyId: "target", uri: "data:image/jpeg;base64,AQ==" };
  render();
  assert.equal(f.state.copyId, "target");
  event("painted");
  event("press");
  assert.deepEqual(f.actions, [["painted", "w"]]);
});

test("late image events cannot acknowledge a replaced bridge even when its bitmap is identical", () => {
  f.store.tabs.copy.pageIn = null;
  f.frozen.bridges.w = { copyId: "target", uri: "data:image/jpeg;base64,AQ==" };
  render();
  const old = f.state;
  f.frozen.bridges.w = { ...f.frozen.bridges.w };
  event("painted", old);
  assert.deepEqual(f.actions, []);
  render();
  assert.notEqual(f.state.token, old.token);
  event("painted", old);
  assert.deepEqual(f.actions, []);
  event("painted");
  assert.deepEqual(f.actions, [["painted", "w"]]);
});

test("a new bitmap and tab state reject stale painted and press events before rerender", () => {
  render();
  const old = f.state;
  f.frozen.frames.copy = "data:image/jpeg;base64,AQ==";
  event("painted", old);
  assert.deepEqual(f.actions, []);
  render();
  event("painted", old);
  assert.deepEqual(f.actions, []);
  f.store.tabs.copy.pageIn = null;
  event("press");
  assert.deepEqual(f.actions, []);
  assert.equal(render(), null);
});

test("a frozen copy without a cached bitmap still hosts the native wash and press action", () => {
  f.frozen.frames = {};
  render();
  assert.equal(f.state.uri, null);
  event("press");
  assert.deepEqual(f.actions, [["activate", "copy"]]);
});

test("unmount disarms already queued callbacks and removes the subscription", () => {
  render();
  const listener = f.listener;
  const state = f.state;
  f.cleanups.forEach((cleanup) => cleanup?.());
  assert.equal(f.listener, null);
  listener("painted", { token: state.token, copyId: state.copyId });
  listener("press", { token: state.token, copyId: state.copyId });
  assert.deepEqual(f.actions, []);
});

test("the native layout publishes a headless frozen presentation without an RN host", () => {
  const guest = render({ headless: true });
  assert.notEqual(guest.type, "HostedView");
  assert.equal(guest.props.tabId, "copy");
  const presentation = JSON.parse(guest.props.state);
  assert.equal(presentation.copyId, "copy");
  assert.equal(presentation.uri, f.frozen.frames.copy);
});

test("a source bridge covers only its holder pane", () => {
  f.store.tabs.copy.pageIn = null;
  f.store.tabs.holder = { id: "holder", windowId: "w" };
  f.store.tabs.target = { pageIn: "holder" };
  f.frozen.bridges.w = { copyId: "target", uri: "data:image/jpeg;base64,AQ==" };
  assert.equal(render({ headless: true }).props.state, null);
  const guest = render({ headless: true, tabId: "holder" });
  assert.equal(JSON.parse(guest.props.state).copyId, "target");
});

test("a sibling frozen bitmap never acknowledges another pane's source bridge", () => {
  f.store.tabs.holder = { id: "holder", windowId: "w" };
  f.store.tabs.target = { pageIn: "holder" };
  f.frozen.bridges.w = { copyId: "target", uri: "data:image/jpeg;base64,AQ==" };
  render({ headless: true });
  assert.equal(f.state.copyId, "copy");
  assert.equal(f.state.uri, f.frozen.frames.copy);
  event("painted");
  assert.deepEqual(f.actions, []);
});

test("the native holder pane acknowledges its current source bridge", () => {
  f.store.tabs.holder = { id: "holder", windowId: "w" };
  f.store.tabs.target = { pageIn: "holder" };
  f.frozen.bridges.w = { copyId: "target", uri: "data:image/jpeg;base64,AQ==" };
  render({ headless: true, tabId: "holder" });
  event("painted");
  event("press");
  assert.deepEqual(f.actions, [["painted", "w"]]);
});
