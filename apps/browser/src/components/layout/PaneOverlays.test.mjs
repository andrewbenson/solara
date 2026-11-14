import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const componentURL = new URL("./PaneOverlays.tsx", import.meta.url).href;
const f = globalThis.sadTabHostTest = {};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@solara/settings": `export const windowShellActive = () => globalThis.sadTabHostTest.shell; export const SolaraHostedView = "HostedView";`,
  "@solara/shell": `export const Surface = "Surface", Symbol = "Symbol";`,
  react: `export const memo = fn => fn; export const useState = fn => [typeof fn === "function" ? fn() : fn];`,
  "react-native": `export const StyleSheet = {absoluteFill:{position:"absolute"}}, Text = "Text", View = "View";`,
  "../../lib/theme": `export const useTheme = () => globalThis.sadTabHostTest.theme; export const hex = v => v;`,
  "../../lib/webviews": `export const webviews = new Map();`,
  "./controls": `export const PromptButton = "PromptButton";`,
  "./pageState": `export const patchPage = () => {}; export const usePage = (id, select) => select(globalThis.sadTabHostTest.page);`,
  "./nativePaneOverlays": `export const usePageFrame = () => ({frame:[6,38,628,500],ref:{},onLayout(){}}); export const useNativeSadTab = (...args) => globalThis.sadTabHostTest.overlays.push(args);`,
  "../../store/hooks": `export const useWindowId = () => "little";`,
};
const hooks = registerHooks({ resolve(specifier, context, next) { return context.parentURL === componentURL && specifier in sources ? fake(sources[specifier]) : next(specifier, context); } });
const { SadTab } = await import("./PaneOverlays.tsx");
after(() => { hooks.deregister(); delete globalThis.sadTabHostTest; });
beforeEach(() => Object.assign(f, { shell: false, overlays: [], page: { crashed: { reason: "test" }, unresponsive: false }, theme: { dark: true, textPrimary: "ink", textSecondary: "dim", panel: "panel", panelBorder: "border", panelShadowOpacity: 0.3, goButton: "button", goButtonText: "label" } }));

test("Little Solara mounts the existing native sad-tab view with its page identity and theme", () => {
  const host = SadTab({ tabId: "a" });
  assert.equal(host.type, "HostedView");
  assert.equal(host.props.kind, "sadTab");
  assert.equal(host.props.windowId, "little");
  assert.deepEqual(JSON.parse(host.props.state), { tabId: "a", mode: "crashed", ...f.theme });
  assert.equal(f.overlays[0][0], false);
});

test("normal browser windows retain their native overlay route and transparent measurement wrapper", () => {
  f.shell = true;
  const host = SadTab({ tabId: "a" });
  assert.equal(host.type, "View");
  assert.equal(host.props.pointerEvents, "none");
  assert.equal(f.overlays[0][0], true);
  assert.equal(f.overlays[0][3], "crashed");
});

test("peek overlays use inline native hosting even when their browser has a native shell", () => {
  f.shell = true;
  assert.equal(SadTab({ tabId: "a", nativeAllowed: false }).props.kind, "sadTab");
  assert.equal(f.overlays[0][0], false);
});

test("a responsive page mounts no overlay and an unresponsive page maps to the native card", () => {
  f.page = { crashed: null, unresponsive: false };
  assert.equal(SadTab({ tabId: "a" }), null);
  f.page.unresponsive = true;
  assert.equal(JSON.parse(SadTab({ tabId: "a" }).props.state).mode, "unresponsive");
});
