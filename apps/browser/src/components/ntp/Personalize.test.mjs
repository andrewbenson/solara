import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./Personalize.tsx", import.meta.url).href;
const f = globalThis.personalizeHostTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const SolaraHostedView = "HostedView"; export const onHostedEvent = (kind, windowId, fn) => { const f = globalThis.personalizeHostTest; f.subscriptions.push([kind, windowId]); f.listener = fn; return () => { f.listener = null; }; };`,
  react: `export const useEffect = fn => globalThis.personalizeHostTest.effects.push(fn); export const useRef = value => ({ current: value });`,
  "react-native": `export const StyleSheet = { absoluteFill: { position: "absolute" } }, View = "View", Pressable = "Pressable", Text = "Text", Animated = {};`,
  "@solara/shell": `export const Surface = "Surface", Symbol = "Symbol";`,
  "../primitives": `export const useHover = () => ({ hovered: false, hoverProps: {} });`,
  "../onboarding/personalize": `export const PERSONALIZE_COPY = {}, TabLayoutPicker = "TabLayoutPicker", ThemeColorPicker = "ThemeColorPicker";`,
  zustand: `export const create = initial => { let state = initial(); const use = select => select(state); use.getState = () => state; use.setState = next => { state = { ...state, ...next }; }; return use; };`,
  "../../lib/theme": `export const useTheme = () => globalThis.personalizeHostTest.theme; export const hex = v => v; export const PROFILE_COLORS = { plum: {}, blue: {}, neutral: {} };`,
  "../../store/browser": `export const useBrowser = fn => fn(globalThis.personalizeHostTest.store); useBrowser.getState = () => globalThis.personalizeHostTest.store;`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const { PersonalizeButton } = await import("./Personalize.tsx");
after(() => { hooks.deregister(); delete globalThis.personalizeHostTest; });
const render = () => PersonalizeButton({ windowId: "w" });
const mount = () => { const host = render(); f.cleanups = f.effects.map(fn => fn()).filter(fn => typeof fn === "function"); return host; };
beforeEach(() => {
  f.cleanups?.forEach(fn => fn());
  Object.assign(f, {
    effects: [], actions: [], subscriptions: [], listener: null, cleanups: [],
    theme: { dark: true, panel: "panel", panelBorder: "border", panelShadowOpacity: 0.5, textPrimary: "title", textSecondary: "subtitle", textTertiary: "dim", icon: "icon", toolbarHover: "hover", toolbarPressed: "pressed" },
    store: { windows: { w: { profileId: "p" } }, profiles: { p: { color: "plum" } }, settings: { tabLayout: "top" }, updateProfile: (...args) => f.actions.push(["profile", ...args]), toggleTabLayout: (...args) => f.actions.push(["layout", ...args]) },
  });
});

test("Personalize only mounts the native host with current window/profile/theme state", () => {
  const host = mount();
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "personalize");
  assert.equal(host.props.windowId, "w");
  assert.deepEqual(host.props.style, { position: "absolute" });
  assert.deepEqual(JSON.parse(host.props.state), { open: false, dark: true, tokens: { panel: "panel", panelBorder: "border", panelShadowOpacity: "0.5", textPrimary: "title", textSecondary: "subtitle", textTertiary: "dim", icon: "icon", toolbarHover: "hover", toolbarPressed: "pressed" }, color: "plum", layout: "top", canPickColor: true, profileId: "p" });
  assert.deepEqual(f.subscriptions, [["personalize", "w"]]);
});

test("native selections retain store actions, selected layout is a no-op and the panel stays open", () => {
  mount();
  f.listener("open", { open: true });
  f.listener("color", { color: "blue", profileId: "p" });
  f.listener("layout", { layout: "top", profileId: "p" });
  f.listener("layout", { layout: "sidebar", profileId: "p" });
  assert.deepEqual(f.actions, [["profile", "p", { color: "blue" }], ["layout", "w"]]);
  f.store.windows.w.tabLayout = "sidebar";
  assert.equal(JSON.parse(render().props.state).layout, "sidebar");
  assert.equal(JSON.parse(render().props.state).open, true);
});

test("closed, invalid, private, missing and stale profile events cannot change settings", () => {
  mount();
  f.listener("color", { color: "blue", profileId: "p" });
  f.listener("open", { open: true });
  f.listener("color", { color: "invalid", profileId: "p" });
  f.listener("color", { color: "toString", profileId: "p" });
  f.listener("layout", { layout: "invalid", profileId: "p" });
  f.store.windows.w.profileId = "other";
  f.store.profiles.other = { color: "neutral" };
  f.listener("color", { color: "blue", profileId: "p" });
  f.listener("layout", { layout: "sidebar", profileId: "p" });
  f.store.windows.w.incognito = true;
  f.listener("color", { color: "blue", profileId: "other" });
  f.listener("layout", { layout: "sidebar", profileId: "other" });
  delete f.store.windows.w;
  f.listener("open", { open: true });
  f.listener("layout", { layout: "sidebar", profileId: "other" });
  assert.deepEqual(f.actions, []);
  assert.equal(render(), null);
});

test("unmount clears only its open panel and unsubscribes its actions", () => {
  mount();
  f.listener("open", { open: true });
  assert.equal(JSON.parse(render().props.state).open, true);
  f.cleanups.forEach(fn => fn());
  assert.equal(f.listener, null);
  assert.equal(JSON.parse(render().props.state).open, false);
});


test("private windows mount no Personalize and a missing profile exposes no color picker", () => {
  f.store.windows.w.incognito = true;
  assert.equal(render(), null);
  f.store.windows.w.incognito = false;
  delete f.store.profiles.p;
  const state = JSON.parse(render().props.state);
  assert.equal(state.color, null);
  assert.equal(state.canPickColor, false);
});
