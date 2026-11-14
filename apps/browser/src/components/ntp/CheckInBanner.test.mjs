import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./CheckInBanner.tsx", import.meta.url).href;
const f = globalThis.checkInHostTest = {};
const fake = source => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView"; export const onHostedEvent = (kind, windowId, fn) => { const f = globalThis.checkInHostTest; f.subscriptions.push([kind, windowId]); f.listener = fn; return () => { f.listener = null; }; };`,
  react: `export const useEffect = fn => globalThis.checkInHostTest.effects.push(fn); export const useRef = value => globalThis.checkInHostTest.ref ??= ({ current: value }); export const useState = value => [value, () => {}];`,
  "react-native": `export const Image = { resolveAssetSource: () => ({ uri: "file:///fixture/icon.png" }) }, StyleSheet = { absoluteFill: { position: "absolute" } }, Animated = {}, Easing = {}, Pressable = "Pressable", Text = "Text", View = "View";`,
  "@solara/shell": `export const Surface = "Surface", Symbol = "Symbol", VisualEffect = "VisualEffect";`,
  "../../lib/defaultBrowserCheckIn": `export const CHECK_IN_COPY = { title: "How are you liking Solara?", action: "Leave us feedback" }; export const useDefaultBrowserCheckIn = () => ({ visible: globalThis.checkInHostTest.visible, leaveFeedback: () => globalThis.checkInHostTest.actions.push("feedback"), dismiss: () => globalThis.checkInHostTest.actions.push("dismiss") });`,
  "../../lib/theme": `export const useTheme = () => ({ dark: true }); export const hex = value => value;`,
  "../../store/browser": `export const useBrowser = fn => fn(globalThis.checkInHostTest.store); useBrowser.getState = () => globalThis.checkInHostTest.store;`,
  "../primitives": `export const useHover = () => ({ hovered: false, hoverProps: {} });`,
  "../../lib/appIcon": `export const APP_ICON = 1;`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const { CheckInBanner } = await import("./CheckInBanner.tsx");
after(() => { hooks.deregister(); delete globalThis.checkInHostTest; });
const render = () => CheckInBanner({ windowId: "w" });
const mount = () => { const host = render(); f.cleanups = f.effects.map(fn => fn()).filter(fn => typeof fn === "function"); return host; };
beforeEach(() => {
  f.cleanups?.forEach(fn => fn());
  Object.assign(f, { ref: null, effects: [], cleanups: [], subscriptions: [], actions: [], listener: null, visible: true, store: { windows: { w: { profileId: "p", activeTabIds: {p: "tab"} } }, tabs: {tab: {url: ""}}, ui: {focusedWindowId: "w"} } });
});

test("the due check-in mounts only the native banner with theme, copy, image and profile", () => {
  const host = mount();
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "checkInBanner");
  assert.equal(host.props.windowId, "w");
  const state = JSON.parse(host.props.state);
  assert.equal(typeof state.token, "string");
  assert.deepEqual(state, { token: state.token, visible: true, focusContext: JSON.stringify(["w", "p", "tab", "", "w"]), dark: true, title: "How are you liking Solara?", action: "Leave us feedback", profileId: "p", icon: "file:///fixture/icon.png" });
  assert.deepEqual(f.subscriptions, [["checkInBanner", "w"]]);
});

test("native completion preserves feedback and dismissal actions", () => {
  mount();
  f.listener("action", { action: "feedback", profileId: "p", token: f.ref.current.token });
  f.listener("action", { action: "dismiss", profileId: "p", token: f.ref.current.token });
  f.listener("action", { action: "unknown", profileId: "p", token: f.ref.current.token });
  assert.deepEqual(f.actions, ["feedback", "dismiss"]);
});

test("stale, private, missing, hidden and unmounted banner actions are ignored", () => {
  mount();
  f.listener("action", { action: "dismiss", profileId: "old", token: f.ref.current.token });
  f.store.windows.w.profileId = "replacement";
  f.listener("action", { action: "feedback", profileId: "p", token: f.ref.current.token });
  f.store.windows.w.incognito = true;
  f.listener("action", { action: "feedback", profileId: "replacement", token: f.ref.current.token });
  assert.equal(render(), null);
  delete f.store.windows.w;
  f.listener("action", { action: "dismiss", profileId: "replacement", token: f.ref.current.token });
  assert.equal(render(), null);
  assert.deepEqual(f.actions, []);
  const queued = f.listener;
  f.cleanups.forEach(fn => fn());
  f.store.windows.w = { profileId: "p" };
  queued("action", { action: "dismiss", profileId: "p", token: f.ref.current.token });
  assert.deepEqual(f.actions, []);
  assert.equal(f.listener, null);
});

test("a check-in that is not due sends hidden state and accepts no completion", () => {
  f.visible = false;
  const host = mount();
  assert.equal(JSON.parse(host.props.state).visible, false);
  f.listener("action", { action: "feedback", profileId: "p", token: f.ref.current.token });
  assert.deepEqual(f.actions, []);
});


test("retained callbacks cannot use a replacement profile or a prior visibility receipt", () => {
  mount();
  const queued = f.listener;
  const token = f.ref.current.token;
  f.store.windows.w.profileId = "replacement";
  queued("action", { action: "dismiss", profileId: "replacement", token });
  f.store.windows.w.profileId = "p";
  f.visible = false;
  render();
  f.visible = true;
  render();
  queued("action", { action: "dismiss", profileId: "p", token });
  assert.deepEqual(f.actions, []);
});

test("focus restoration context follows the selected page and focused window", () => {
  const initial = JSON.parse(render().props.state).focusContext;
  f.store.windows.w.activeTabIds.p = "other";
  f.store.tabs.other = {url: ""};
  const otherPage = JSON.parse(render().props.state).focusContext;
  assert.notEqual(otherPage, initial);
  f.store.tabs.other.url = "about:blank";
  const navigated = JSON.parse(render().props.state).focusContext;
  assert.notEqual(navigated, otherPage);
  f.store.ui.focusedWindowId = "elsewhere";
  assert.notEqual(JSON.parse(render().props.state).focusContext, navigated);
});
